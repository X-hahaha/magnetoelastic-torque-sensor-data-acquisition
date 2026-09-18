"""Recording sessions and single-socket L2 monitoring orchestration."""
from __future__ import annotations

import csv
import json
import queue
import socket
import time
from dataclasses import asdict
from pathlib import Path

from ds_host import SUMMARY_COLUMNS, SUMMARY_OUTPUT_COLUMNS, WV32_MAGIC, LS32_MAGIC, format_pc_timestamp, parse_text_datagram
from ds_torque import TORQUE_COLUMNS, ModelCalibration, TorqueProcessor


class RecordingSession:
    def __init__(self, path: Path, metadata: dict, integrity_columns: list[str]):
        path.mkdir(parents=True, exist_ok=False)
        self.path, self.handles = path, []
        try:
            with (path / "session.json").open("x", encoding="utf-8") as handle:
                json.dump(metadata, handle, ensure_ascii=False, indent=2, allow_nan=False)
            self.summary = self._csv("summary.csv", SUMMARY_OUTPUT_COLUMNS)
            self.integrity = self._csv("integrity.csv", integrity_columns)
            self.torque = self._csv("torque.csv", TORQUE_COLUMNS)
            self.wave = (path / "wave_interleaved_a_b_u16le.bin").open("xb")
            self.handles.append(self.wave)
        except Exception:
            self.close()
            raise

    def _csv(self, name: str, columns: list[str]):
        handle = (self.path / name).open("x", newline="", encoding="utf-8")
        self.handles.append(handle)
        writer = csv.DictWriter(handle, fieldnames=columns)
        writer.writeheader()
        return writer

    def save(self, assembly, reason: str, bad_datagrams: int, torque: dict) -> None:
        frame = assembly.frame
        complete = assembly.complete()
        saved = complete and frame.wave_bytes is not None
        stamp = format_pc_timestamp(frame.summary_received_time or frame.end_time)
        if frame.summary_received:
            self.summary.writerow({**{k: frame.summary.get(k, "") for k in SUMMARY_COLUMNS}, "pc_timestamp": stamp})
        offset = self.wave.tell() if saved else ""
        if saved:
            self.wave.write(frame.wave_bytes)
        missing = frame.missing_wave_chunks()
        self.integrity.writerow(dict(
            frame_id=frame.frame_id, complete=int(complete), wave_saved=int(saved),
            wave_file=Path(self.wave.name).name if saved else "", wave_byte_offset=offset,
            wave_bytes=len(frame.wave_bytes) if saved else "", finalize_reason=reason,
            summary_received=int(frame.summary_received), wave_received_chunks=len(frame.wave_received),
            wave_total_chunks=frame.wave_total_chunks, wave_received_samples=assembly.received_samples,
            wave_total_samples=frame.wave_total_samples, missing_wave_count=len(missing),
            missing_wave_chunks=";".join(map(str, missing)), duplicate_wave_chunks=frame.stats.wave_duplicates,
            bad_wave_packets=frame.stats.wave_bad_packets, unassigned_bad_datagrams=bad_datagrams,
            elapsed_s=frame.end_time-frame.start_time, pc_timestamp=stamp))
        self.torque.writerow(torque)
        for handle in self.handles:
            handle.flush()

    def close(self):
        for handle in self.handles:
            handle.close()


def run_monitor(worker, assembler_class, stop_event, commands, config: dict,
                model, window: int, initial_training: dict | None = None):
    """All model/filter/record state is owned by this receive thread."""
    sock = None
    assembler = None
    started = sent = rejected = stopped = False
    failure = None
    trainer = None
    training_path = None
    processor = TorqueProcessor(model, window, config)
    last_valid = None
    stale_reported = False
    last_progress = 0.0

    def cancel_training(message):
        nonlocal trainer
        if trainer is not None:
            trainer = None
            assembler.stop_recording()
            worker.emit("model_finished", success=False, message=message)

    def finalized(assembly):
        nonlocal last_valid, stale_reported
        frame = assembly.frame
        stamp = assembly.summary_seen_monotonic or assembly.last_seen_monotonic
        previous = processor.model
        row = processor.process(frame.summary, assembly.complete(), frame.wave_total_samples,
                                stamp, format_pc_timestamp(frame.summary_received_time or frame.end_time))
        row["frame_id"] = frame.frame_id
        if previous is not None and processor.model is None:
            worker.emit("model_invalidated", message=row["quality"])
        if row["quality"] == "valid":
            last_valid, stale_reported = stamp, False
        if trainer is not None and assembly.first_seen_monotonic >= trainer.created:
            try:
                row["model_calibration_id"] = training_path.name
                before = len(trainer.samples)
                trainer.add(frame.summary, assembly.complete(), frame.wave_total_samples, stamp)
                row["used_for_model"] = int(len(trainer.samples) > before)
            except (KeyError, ValueError, TypeError) as exc:
                cancel_training(str(exc))
        worker.emit("torque_sample", row=row)
        return row

    def start_session(action, kind):
        snapshot = dict(kind=kind, started_pc_timestamp=format_pc_timestamp(), trigger=config,
                        average_frames=window, model=asdict(processor.model) if processor.model else None,
                        reference_source="load_equipment_setpoint_not_independently_measured",
                        training={k: action[k] for k in ("t0", "duration") if k in action})
        assembler.start_recording(Path(action["path"]), snapshot)

    def handle_action(action):
        nonlocal trainer, training_path
        kind = action["kind"]
        if kind == "record_start":
            if trainer is not None:
                raise ValueError("模型标定期间不能开始实验记录")
            start_session(action, "experiment")
        elif kind == "record_stop":
            if trainer is None:
                assembler.stop_recording()
        elif kind == "model_start":
            if assembler.session is not None or trainer is not None:
                raise ValueError("请先停止记录，再开始模型标定")
            candidate = ModelCalibration(action["t0"], action["duration"], window, config, time.monotonic())
            start_session(action, "model_calibration")
            training_path = Path(action["path"])
            trainer = candidate
            worker.emit("model_started")
        elif kind == "model_cancel":
            cancel_training("用户取消，未生成新模型")

    try:
        sock = worker.open_socket()
        assembler = assembler_class(worker.output_root, worker.emit, worker.summary_grace_s)
        assembler.on_frame = finalized
        command = f"AUTO_START,{config['rpm']},{config['threshold_um']},{config['points']}"
        worker.send_command(sock, command)
        sent = True
        deadline = time.monotonic() + 2
        while not stop_event.is_set():
            if started:
                if initial_training is not None:
                    try:
                        handle_action(initial_training)
                    except Exception as exc:
                        worker.emit("action_error", action="model_start", message=str(exc))
                    initial_training = None
                while True:
                    try:
                        action = commands.get_nowait()
                    except queue.Empty:
                        break
                    try:
                        handle_action(action)
                    except Exception as exc:
                        worker.emit("action_error", action=action["kind"], message=str(exc))
            try:
                data, addr = sock.recvfrom(65535)
                if addr[0] != worker.board_addr[0]:
                    continue
            except socket.timeout:
                data = b""
            if data.startswith(WV32_MAGIC):
                assembler.accept_wave(data)
            elif data and not data.startswith(LS32_MAGIC):
                text = parse_text_datagram(data)
                for line in (text or "").splitlines():
                    line = line.strip()
                    if not line or line.startswith("#CAPTURE") or assembler.accept_summary(line):
                        continue
                    worker.emit("log", message=line)
                    if not started and line.startswith(("#ERR", "#BUSY")):
                        rejected = not line.startswith("#ERR,auto_already_active")
                        raise RuntimeError(f"开始监测失败：{line}")
                    if line.startswith("#AUTO,STARTED"):
                        started = True
                        worker.emit("monitor_started")
            assembler.sweep()
            now = time.monotonic()
            if not started and now >= deadline:
                raise RuntimeError("开始监测超时，板端状态未知，请点击停止监测后重试")
            if trainer is not None:
                try:
                    if trainer.poll(now):
                        new_model = trainer.finish()
                        new_model.save(training_path / "model.json")
                        # Save the training data first; do not label it with the new model.
                        trainer = None
                        assembler.stop_recording()
                        for fid in list(assembler.recording_ids):
                            assembler._finalize(fid, "model_calibration_boundary")
                        processor.model = new_model
                        processor.reset()
                        worker.emit("model_finished", success=True, model=new_model, path=training_path)
                    elif now - last_progress >= .25:
                        last_progress = now
                        elapsed = now - trainer.samples[0][0] if trainer.samples else 0
                        worker.emit("model_progress", elapsed=elapsed, duration=trainer.duration,
                                    count=len(trainer.samples), rejected=trainer.rejected)
                except (ValueError, OSError) as exc:
                    if trainer is None:
                        raise  # A session-close failure must not masquerade as cancellation.
                    cancel_training(str(exc))
            if last_valid is not None and now - last_valid > 5 and not stale_reported:
                processor.reset()
                stale_reported = True
                worker.emit("torque_stale")
    except Exception as exc:
        failure = exc
    finally:
        try:
            cancel_training("监测结束，模型标定未完成")
        except Exception as exc:
            failure = failure or exc
        if sock is not None and sent and not rejected:
            try:
                stopped = worker._stop_monitoring_on_socket(sock, assembler)
            except Exception as exc:
                failure = failure or exc
        if assembler is not None:
            try:
                assembler.close("monitor_stopped" if stopped else "stream_error")
            except Exception as exc:
                failure = failure or exc
        if sock is not None:
            sock.close()
        active = sent and not rejected and not stopped
        if failure is not None:
            worker.emit("error", operation="stream", title="L2监测失败", message=str(failure), monitoring_active=active)
        else:
            worker.emit("stream_done", monitoring_active=active, monitoring_stopped=stopped)
