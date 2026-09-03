#!/usr/bin/env python3
"""
Tkinter GUI for the DS_system_02ms UDP host.

Manual mode keeps the same one-CAPTURE-at-a-time transaction rule as ds_host.py.
Auto mode can bind the receive socket before AUTO_START, reassembles concurrent
frame IDs independently, and records per-frame UDP integrity before accepting a
waveform as experiment data.
"""

from __future__ import annotations

import csv
import os
import queue
import socket
import struct
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Sequence, TextIO, Tuple

import tkinter as tk
from tkinter import filedialog, messagebox, scrolledtext, ttk

from ds_host import (
    ADC_SAMPLE_COUNT,
    DEFAULT_BIND_IP,
    DEFAULT_BOARD_IP,
    DEFAULT_BOARD_PORT,
    DEFAULT_PC_PORT,
    CaptureFrame,
    LS32_MAGIC,
    LS32_RECORD_BYTES,
    SUMMARY_COLUMNS,
    TIMELINE_COLUMNS,
    WAVE_HEADER_BYTES,
    WV32_MAGIC,
    is_summary_row,
    now_stamp,
    parse_summary_row,
    parse_text_datagram,
)


SOFTWARE_DIR = Path(__file__).resolve().parent
DEFAULT_OUTPUT_ROOT = SOFTWARE_DIR / "captures"
DEFAULT_RECV_BUFFER = 64 * 1024 * 1024
DEFAULT_TIMEOUT_S = 25.0
DEFAULT_SUMMARY_GRACE_S = 0.8
AUTO_MIN_RPM = 1
AUTO_MAX_RPM = 4000
AUTO_MIN_POINTS = 16
AUTO_MAX_POINTS = ADC_SAMPLE_COUNT
AUTO_FRAME_STALE_S = 2.0

STREAM_INTEGRITY_COLUMNS = [
    "frame_id",
    "complete",
    "wave_saved",
    "wave_file",
    "wave_byte_offset",
    "wave_bytes",
    "finalize_reason",
    "summary_received",
    "wave_received_chunks",
    "wave_total_chunks",
    "wave_received_samples",
    "wave_total_samples",
    "missing_wave_count",
    "missing_wave_chunks",
    "duplicate_wave_chunks",
    "bad_wave_packets",
    "unassigned_bad_datagrams",
    "elapsed_s",
]

CAL_STATE_NAMES = {
    "0": "IDLE",
    "1": "DISCARD",
    "2": "COLLECT",
    "3": "COMPUTE",
    "4": "VERIFY",
    "5": "READY",
    "6": "FAILED",
}

SUMMARY_LABELS = {
    "frame_id": "帧号",
    "adc_a_raw_pp": "ADC A 原始峰峰值",
    "adc_b_raw_pp": "ADC B 原始峰峰值",
    "adc_a_filt_pp": "ADC A 滤波峰峰值",
    "adc_b_filt_pp": "ADC B 滤波峰峰值",
    "adc_a_mVpp": "ADC A mVpp",
    "adc_b_mVpp": "ADC B mVpp",
    "l1_um": "激光 1 um",
    "l2_um": "激光 2 um",
    "l3_um": "激光 3 um",
    "l4_um": "激光 4 um",
    "l5_um": "激光 5 um",
    "temp_x10": "温度 x10",
    "status": "板端状态",
    "missed_total": "板端 missed_total",
    "cal_state": "校准状态",
    "cal_valid": "校准有效",
    "gain_a_ppm": "A 增益 ppm",
    "gain_b_ppm": "B 增益 ppm",
    "adc_a_corr_uVpp": "A 校正 uVpp",
    "adc_b_corr_uVpp": "B 校正 uVpp",
    "me_2x_uV": "ME 2x uV",
    "me_norm_ppm": "ME norm ppm",
    "cal_zero_residual_uV": "零点残差 uV",
    "ls_count": "激光记录数",
    "ls_overflow": "激光记录溢出",
}


def fmt_count(received: Optional[int], total: Optional[int]) -> str:
    if total is None:
        return f"{received or 0}/?"
    return f"{received or 0}/{total}"


def fmt_bool(value: str) -> str:
    if value == "1":
        return "是"
    if value == "0":
        return "否"
    return value or "-"


def summary_value(summary: Dict[str, str], key: str) -> str:
    value = summary.get(key, "")
    if key == "cal_state":
        return f"{value} ({CAL_STATE_NAMES.get(value, 'UNKNOWN')})" if value else "-"
    if key == "cal_valid":
        return fmt_bool(value)
    return value if value else "-"


def unique_output_dir(root: Path, prefix: str) -> Path:
    base = root / f"{prefix}_{now_stamp()}"
    if not base.exists():
        return base
    for suffix in range(1, 1000):
        candidate = root / f"{base.name}_{suffix:02d}"
        if not candidate.exists():
            return candidate
    raise RuntimeError(f"无法为 {base} 分配唯一输出目录")


def parse_hash_kv_line(line: str) -> Tuple[str, Dict[str, str]]:
    parts = [part.strip() for part in line.strip().split(",") if part.strip()]
    if not parts or not parts[0].startswith("#"):
        return "", {}
    tag = parts[0][1:]
    values: Dict[str, str] = {}
    for part in parts[1:]:
        if "=" not in part:
            continue
        key, value = part.split("=", 1)
        values[key.strip()] = value.strip()
    return tag, values


def frame_snapshot(frame: CaptureFrame) -> Dict[str, Any]:
    wave_received = len(frame.wave_received)
    sensor_received = len(frame.sensor_received)
    wave_samples = sum(frame.wave_chunk_sample_counts.values())
    sensor_records = sum(frame.sensor_chunk_record_counts.values())
    return {
        "frame_id": frame.frame_id,
        "elapsed_s": time.time() - frame.start_time,
        "summary_received": frame.summary_received,
        "wave_received": wave_received,
        "wave_total": frame.wave_total_chunks,
        "wave_samples": wave_samples,
        "wave_sample_total": frame.wave_total_samples,
        "sensor_received": sensor_received,
        "sensor_total": frame.sensor_total_chunks,
        "sensor_records": sensor_records,
        "sensor_record_total": frame.sensor_total_records,
        "stats": frame.stats.__dict__.copy(),
    }


def iter_sensor_records(frame: CaptureFrame) -> List[Tuple[int, ...]]:
    if frame.sensor_records_bytes is None:
        return []
    records: List[Tuple[int, ...]] = []
    data = frame.sensor_records_bytes
    for offset in range(0, len(data), LS32_RECORD_BYTES):
        record = data[offset : offset + LS32_RECORD_BYTES]
        if len(record) < LS32_RECORD_BYTES:
            break
        records.append(struct.unpack("<IIIIiiiiii", record))
    return records


def make_wave_preview(
    frame: CaptureFrame, max_points: int
) -> Tuple[List[Tuple[int, int, int]], int, int]:
    if frame.wave_bytes is None:
        return [], 0, 0

    data = frame.wave_bytes
    total_samples = len(data) // 4
    if total_samples <= 0:
        return [], 0, 0

    step = max(1, total_samples // max(1, max_points))
    points: List[Tuple[int, int, int]] = []
    min_v = 32767
    max_v = -32768

    for sample_idx in range(0, total_samples, step):
        off = sample_idx * 4
        if off + 4 > len(data):
            break
        a_val, b_val = struct.unpack_from("<hh", data, off)
        points.append((sample_idx, a_val, b_val))
        if a_val < min_v:
            min_v = a_val
        if b_val < min_v:
            min_v = b_val
        if a_val > max_v:
            max_v = a_val
        if b_val > max_v:
            max_v = b_val

    return points, min_v, max_v


@dataclass(frozen=True)
class AutoConfig:
    rpm: int
    threshold_um: int
    points: int

    def command(self, prefix: str) -> str:
        return f"{prefix},{self.rpm},{self.threshold_um},{self.points}"


def parse_auto_config(rpm_text: str, threshold_text: str, points_text: str) -> AutoConfig:
    try:
        rpm = int(rpm_text.strip())
        threshold_um = int(threshold_text.strip())
        points = int(points_text.strip())
    except ValueError as exc:
        raise ValueError("转速、阈值和点数必须是整数") from exc

    if not AUTO_MIN_RPM <= rpm <= AUTO_MAX_RPM:
        raise ValueError(f"转速必须在 {AUTO_MIN_RPM} 到 {AUTO_MAX_RPM} rpm 之间")
    if not -(2**31) <= threshold_um < 2**31:
        raise ValueError("阈值必须在有符号 32 位整数范围内")
    if not AUTO_MIN_POINTS <= points <= AUTO_MAX_POINTS:
        raise ValueError(
            f"点数必须在 {AUTO_MIN_POINTS} 到 {AUTO_MAX_POINTS:,} 之间"
        )
    return AutoConfig(rpm=rpm, threshold_um=threshold_um, points=points)


@dataclass(frozen=True)
class WavePacket:
    frame_id: int
    chunk_index: int
    total_chunks: int
    start_sample: int
    sample_count: int
    total_samples: int
    payload: bytes


def parse_wave_packet(data: bytes) -> WavePacket:
    if len(data) < WAVE_HEADER_BYTES or data[:4] != WV32_MAGIC:
        raise ValueError("WV32 header is missing")
    if data[4] != 1 or data[5] != WAVE_HEADER_BYTES:
        raise ValueError("WV32 version/header length mismatch")

    frame_id, chunk_index, total_chunks, start_sample, sample_count, total_samples = (
        struct.unpack_from("<IIIIII", data, 8)
    )
    payload = data[WAVE_HEADER_BYTES:]
    if total_chunks == 0 or chunk_index >= total_chunks:
        raise ValueError("WV32 chunk index is outside the advertised range")
    if not AUTO_MIN_POINTS <= total_samples <= AUTO_MAX_POINTS:
        raise ValueError("WV32 total sample count is outside the firmware range")
    if sample_count == 0 or start_sample + sample_count > total_samples:
        raise ValueError("WV32 sample range is invalid")
    if len(payload) != sample_count * 4:
        raise ValueError("WV32 payload length mismatch")
    return WavePacket(
        frame_id=frame_id,
        chunk_index=chunk_index,
        total_chunks=total_chunks,
        start_sample=start_sample,
        sample_count=sample_count,
        total_samples=total_samples,
        payload=payload,
    )


@dataclass
class AutoFrameAssembly:
    frame: CaptureFrame
    first_seen_monotonic: float
    last_seen_monotonic: float
    summary_seen_monotonic: Optional[float] = None
    wave_ranges: Dict[int, Tuple[int, int]] = field(default_factory=dict)

    @property
    def received_samples(self) -> int:
        return sum(count for _start, count in self.wave_ranges.values())

    def waveform_complete(self) -> bool:
        frame = self.frame
        if (
            frame.wave_total_chunks is None
            or frame.wave_total_samples is None
            or len(frame.wave_received) != frame.wave_total_chunks
            or len(self.wave_ranges) != frame.wave_total_chunks
        ):
            return False

        cursor = 0
        for start, count in sorted(self.wave_ranges.values()):
            if start != cursor:
                return False
            cursor += count
        return cursor == frame.wave_total_samples

    def complete(self) -> bool:
        return self.frame.summary_received and self.waveform_complete()


class AutoStreamRecorder:
    """Reassemble, validate and persist auto-mode frames.

    summary.csv retains the established experiment format. All complete
    waveforms in one recording session are appended to one interleaved
    little-endian binary file. integrity.csv records each frame's byte range and
    explains why incomplete frames were omitted from the binary stream.
    """

    def __init__(
        self,
        output_dir: Path,
        emit: Callable[..., None],
        summary_grace_s: float,
    ) -> None:
        self.output_dir = output_dir
        self.emit = emit
        self.summary_grace_s = summary_grace_s
        self.stale_s = max(AUTO_FRAME_STALE_S, summary_grace_s * 2.0)
        self.frames: Dict[int, AutoFrameAssembly] = {}
        self.finalized_ids: set[int] = set()
        self.finalized_count = 0
        self.complete_count = 0
        self.incomplete_count = 0
        self.bad_datagrams = 0

        output_dir.mkdir(parents=True, exist_ok=True)
        self.summary_file: TextIO = (output_dir / "summary.csv").open(
            "w", newline="", encoding="utf-8"
        )
        self.integrity_file: TextIO = (output_dir / "integrity.csv").open(
            "w", newline="", encoding="utf-8"
        )
        self.wave_path = output_dir / "wave_interleaved_a_b_u16le.bin"
        self.wave_file = self.wave_path.open("wb")
        self.summary_writer = csv.writer(self.summary_file)
        self.integrity_writer = csv.writer(self.integrity_file)
        self.summary_writer.writerow(SUMMARY_COLUMNS)
        self.integrity_writer.writerow(STREAM_INTEGRITY_COLUMNS)

    def _assembly(self, frame_id: int, now: float) -> Optional[AutoFrameAssembly]:
        if frame_id in self.finalized_ids:
            self.emit("log", message=f"#HOST,late_packet,frame={frame_id}")
            return None
        assembly = self.frames.get(frame_id)
        if assembly is None:
            assembly = AutoFrameAssembly(
                frame=CaptureFrame(output_dir=self.output_dir),
                first_seen_monotonic=now,
                last_seen_monotonic=now,
            )
            self.frames[frame_id] = assembly
        else:
            assembly.last_seen_monotonic = now
        return assembly

    def accept_wave(self, data: bytes) -> None:
        try:
            packet = parse_wave_packet(data)
        except (ValueError, struct.error) as exc:
            self.bad_datagrams += 1
            self.emit("log", message=f"#HOST,bad_wv32,reason={exc}")
            return

        now = time.monotonic()
        assembly = self._assembly(packet.frame_id, now)
        if assembly is None:
            return
        before = len(assembly.frame.wave_received)
        assembly.frame.accept_wave(data)
        if len(assembly.frame.wave_received) == before:
            return

        assembly.wave_ranges[packet.chunk_index] = (
            packet.start_sample,
            packet.sample_count,
        )
        self.emit(
            "stream_wave",
            frame_id=packet.frame_id,
            start_sample=packet.start_sample,
            total_samples=packet.total_samples,
            payload=packet.payload,
            received_chunks=len(assembly.frame.wave_received),
            total_chunks=assembly.frame.wave_total_chunks,
            received_samples=assembly.received_samples,
        )
        if assembly.complete():
            self._finalize(packet.frame_id, "complete")

    def accept_summary(self, line: str) -> bool:
        if not is_summary_row(line):
            return False
        parsed = parse_summary_row(line)
        try:
            frame_id = int(parsed.get("frame_id", ""), 10)
        except ValueError:
            return False

        now = time.monotonic()
        assembly = self._assembly(frame_id, now)
        if assembly is None:
            return True
        assembly.frame.accept_text(line)
        assembly.summary_seen_monotonic = now
        if assembly.complete():
            self._finalize(frame_id, "complete")
        return True

    def sweep(self) -> None:
        now = time.monotonic()
        for frame_id, assembly in list(self.frames.items()):
            if assembly.complete():
                self._finalize(frame_id, "complete")
            elif (
                assembly.summary_seen_monotonic is not None
                and now - assembly.summary_seen_monotonic >= self.summary_grace_s
            ):
                self._finalize(frame_id, "summary_grace_expired")
            elif now - assembly.last_seen_monotonic >= self.stale_s:
                self._finalize(frame_id, "packet_timeout")

    def _finalize(self, frame_id: int, reason: str) -> None:
        assembly = self.frames.pop(frame_id, None)
        if assembly is None:
            return
        frame = assembly.frame
        frame.end_time = time.time()
        complete = assembly.complete()
        missing = frame.missing_wave_chunks()
        wave_saved = complete and frame.wave_bytes is not None
        wave_byte_offset: Optional[int] = None
        wave_byte_count = 0

        if frame.summary_received:
            self.summary_writer.writerow(
                [frame.summary.get(name, "") for name in SUMMARY_COLUMNS]
            )
            self.summary_file.flush()
        if wave_saved:
            wave_byte_offset, wave_byte_count = self._append_wave_binary(
                frame.wave_bytes or bytearray()
            )

        self.integrity_writer.writerow(
            [
                frame_id,
                int(complete),
                int(wave_saved),
                self.wave_path.name if wave_saved else "",
                wave_byte_offset if wave_byte_offset is not None else "",
                wave_byte_count if wave_saved else "",
                reason,
                int(frame.summary_received),
                len(frame.wave_received),
                frame.wave_total_chunks if frame.wave_total_chunks is not None else "",
                assembly.received_samples,
                frame.wave_total_samples if frame.wave_total_samples is not None else "",
                len(missing) if frame.wave_total_chunks is not None else "",
                ";".join(str(index) for index in missing),
                frame.stats.wave_duplicates,
                frame.stats.wave_bad_packets,
                self.bad_datagrams,
                f"{frame.end_time - frame.start_time:.6f}",
            ]
        )
        self.integrity_file.flush()

        self.finalized_ids.add(frame_id)
        self.finalized_count += 1
        if complete:
            self.complete_count += 1
        else:
            self.incomplete_count += 1
        self.emit(
            "stream_frame_done",
            frame_id=frame_id,
            summary=frame.summary,
            complete=complete,
            reason=reason,
            received_chunks=len(frame.wave_received),
            total_chunks=frame.wave_total_chunks,
            received_samples=assembly.received_samples,
            total_samples=frame.wave_total_samples,
            missing_chunks=len(missing) if frame.wave_total_chunks is not None else None,
            finalized=self.finalized_count,
            complete_frames=self.complete_count,
            incomplete_frames=self.incomplete_count,
            bad_datagrams=self.bad_datagrams,
        )

    def _append_wave_binary(self, wave_bytes: bytearray) -> Tuple[int, int]:
        offset = self.wave_file.tell()
        self.wave_file.write(wave_bytes)
        self.wave_file.flush()
        return offset, len(wave_bytes)

    def close(self, reason: str = "stream_stopped") -> None:
        for frame_id in list(self.frames):
            self._finalize(frame_id, reason)
        for handle in (self.summary_file, self.integrity_file, self.wave_file):
            handle.close()


class UdpWorker:
    def __init__(
        self,
        events: "queue.Queue[Dict[str, Any]]",
        board_ip: str,
        board_port: int,
        bind_ip: str,
        pc_port: int,
        output_root: Path,
        recv_buffer: int,
        timeout_s: float,
        summary_grace_s: float,
        split_channels: bool,
    ) -> None:
        self.events = events
        self.board_addr = (board_ip, board_port)
        self.bind_addr = (bind_ip, pc_port)
        self.output_root = output_root
        self.recv_buffer = recv_buffer
        self.timeout_s = timeout_s
        self.summary_grace_s = summary_grace_s
        self.split_channels = split_channels

    def emit(self, kind: str, **payload: Any) -> None:
        payload["kind"] = kind
        self.events.put(payload)

    def open_socket(self) -> socket.socket:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, self.recv_buffer)
        sock.bind(self.bind_addr)
        sock.settimeout(0.1)
        return sock

    def send_command(self, sock: socket.socket, command: str) -> None:
        payload = command.strip().encode("ascii")
        sock.sendto(payload, self.board_addr)
        self.emit("log", message=f"> {command.strip()}")

    def drain_text(self, sock: socket.socket, duration_s: float) -> List[str]:
        lines: List[str] = []
        deadline = time.time() + duration_s
        while time.time() < deadline:
            try:
                data, _addr = sock.recvfrom(65535)
            except socket.timeout:
                continue
            text = parse_text_datagram(data)
            if text is None:
                self.emit("log", message=f"#HOST,drained_binary_packet,len={len(data)}")
                continue
            for line in text.splitlines():
                clean = line.strip()
                if clean:
                    lines.append(clean)
                    self.emit("log", message=clean)
        return lines

    def run_command(
        self,
        command: str,
        wait_s: float = 1.0,
        stop_on_first_reply: bool = False,
    ) -> None:
        sock: Optional[socket.socket] = None
        try:
            sock = self.open_socket()
            self.send_command(sock, command)
            if stop_on_first_reply:
                lines: List[str] = []
                deadline = time.monotonic() + wait_s
                while time.monotonic() < deadline:
                    try:
                        data, _addr = sock.recvfrom(65535)
                    except socket.timeout:
                        continue
                    text = parse_text_datagram(data)
                    if text is None:
                        # Do not keep consuming auto-mode waveform packets while
                        # this short transaction is waiting for its ACK.
                        self.emit(
                            "log",
                            message=f"#HOST,command_received_binary,len={len(data)}",
                        )
                        break
                    lines = [line.strip() for line in text.splitlines() if line.strip()]
                    for line in lines:
                        self.emit("log", message=line)
                    break
            else:
                lines = self.drain_text(sock, wait_s)
            self.emit("command_done", command=command, lines=lines)
        except Exception as exc:
            self.emit("error", title="命令失败", message=str(exc))
        finally:
            if sock is not None:
                sock.close()

    def run_capture(self) -> None:
        self._run_capture_impl()

    def run_auto_stream(
        self,
        stop_event: threading.Event,
        out_dir: Path,
        startup_command: Optional[str] = None,
    ) -> None:
        """Receive and persist auto frames until stop_event is set.

        If startup_command is supplied, the receive socket is bound before
        AUTO_START is sent, so the first automatically triggered frame cannot
        be lost between two short-lived GUI workers.
        """
        sock: Optional[socket.socket] = None
        recorder: Optional[AutoStreamRecorder] = None
        failure: Optional[Exception] = None
        startup_pending = startup_command is not None
        startup_deadline = time.monotonic() + 2.0 if startup_pending else None
        try:
            sock = self.open_socket()
            recorder = AutoStreamRecorder(out_dir, self.emit, self.summary_grace_s)
            self.emit("log", message=f"#HOST,auto_stream_start,dir={out_dir}")
            if startup_command is not None:
                self.send_command(sock, startup_command)

            while not stop_event.is_set():
                try:
                    data, _addr = sock.recvfrom(65535)
                except socket.timeout:
                    recorder.sweep()
                    if (
                        startup_pending
                        and startup_deadline is not None
                        and time.monotonic() >= startup_deadline
                    ):
                        raise RuntimeError("启动自动模式超时：未收到板端回复")
                    continue
                except OSError:
                    if stop_event.is_set():
                        break
                    raise

                if data.startswith(WV32_MAGIC):
                    startup_pending = False
                    recorder.accept_wave(data)
                elif data.startswith(LS32_MAGIC):
                    continue  # auto mode does not send LS32
                else:
                    text = parse_text_datagram(data)
                    if text is None:
                        continue
                    for line in text.splitlines():
                        clean = line.strip()
                        if not clean or clean.startswith("#CAPTURE"):
                            continue  # suppress per-frame trigger spam
                        if recorder.accept_summary(clean):
                            startup_pending = False
                            continue
                        self.emit("log", message=clean)
                        if startup_pending:
                            if clean.startswith(("#ERR", "#BUSY")):
                                raise RuntimeError(f"启动自动模式失败：{clean}")
                            if clean.startswith("#AUTO,STARTED"):
                                startup_pending = False
                recorder.sweep()

        except Exception as exc:
            failure = exc
        finally:
            if recorder is not None:
                try:
                    recorder.close("stream_stopped" if failure is None else "stream_error")
                except Exception as exc:
                    if failure is None:
                        failure = exc
            if sock is not None:
                sock.close()
            if failure is not None:
                self.emit("error", title="连续记录失败", message=str(failure))
            else:
                self.emit(
                    "stream_done",
                    frames=recorder.finalized_count if recorder is not None else 0,
                    complete_frames=recorder.complete_count if recorder is not None else 0,
                    incomplete_frames=recorder.incomplete_count if recorder is not None else 0,
                    bad_datagrams=recorder.bad_datagrams if recorder is not None else 0,
                    output_dir=out_dir,
                )

    def _run_capture_impl(self) -> None:
        sock: Optional[socket.socket] = None
        frame: Optional[CaptureFrame] = None
        try:
            capture_dir = unique_output_dir(self.output_root, "capture")
            frame = CaptureFrame(output_dir=capture_dir)
            sock = self.open_socket()

            self.emit("log", message="#HOST,drain_before_capture")
            self.drain_text(sock, 0.1)
            self.send_command(sock, "CAPTURE")

            deadline = time.time() + self.timeout_s
            summary_deadline: Optional[float] = None
            last_progress = 0.0

            while time.time() < deadline:
                try:
                    data, _addr = sock.recvfrom(65535)
                except socket.timeout:
                    now = time.time()
                    if summary_deadline is not None and now >= summary_deadline:
                        break
                    if now - last_progress >= 0.25:
                        self.emit("progress", snapshot=frame_snapshot(frame))
                        last_progress = now
                    continue

                if data.startswith(WV32_MAGIC):
                    frame.accept_wave(data)
                elif data.startswith(LS32_MAGIC):
                    frame.accept_sensor(data)
                else:
                    text = parse_text_datagram(data)
                    if text is None:
                        frame.stats.unknown_packets += 1
                        self.emit("log", message=f"#HOST,unknown_packet,len={len(data)}")
                    else:
                        had_summary = frame.summary_received
                        frame.accept_text(text)
                        for line in text.splitlines():
                            clean = line.strip()
                            if clean:
                                self.emit("log", message=clean)
                                if clean.startswith(("#ERR", "#BUSY")) and not frame.has_payload():
                                    frame.end_time = time.time()
                                    out_dir = frame.write_outputs(
                                        split_channels=self.split_channels
                                    )
                                    self.emit(
                                        "capture_done",
                                        frame=frame,
                                        output_dir=out_dir,
                                        status="CHECK",
                                        message=clean,
                                    )
                                    return
                        if frame.summary_received and not had_summary:
                            summary_deadline = time.time() + self.summary_grace_s

                now = time.time()
                if now - last_progress >= 0.15:
                    self.emit("progress", snapshot=frame_snapshot(frame))
                    last_progress = now

                if frame.summary_received and frame.all_expected_chunks_received():
                    break
                if summary_deadline is not None and time.time() >= summary_deadline:
                    break

            if not frame.complete_enough():
                frame.end_time = time.time()
                frame.messages.append("#HOST,timeout_waiting_for_summary")
                self.emit("log", message="#HOST,timeout_waiting_for_summary")

            out_dir = frame.write_outputs(split_channels=self.split_channels)
            wave_missing = len(frame.missing_wave_chunks())
            sensor_missing = len(frame.missing_sensor_chunks())
            status = (
                "OK"
                if frame.summary_received and wave_missing == 0 and sensor_missing == 0
                else "CHECK"
            )
            self.emit(
                "capture_done",
                frame=frame,
                output_dir=out_dir,
                status=status,
                message=(
                    f"{status}: frame={frame.frame_id} "
                    f"WV32={fmt_count(len(frame.wave_received), frame.wave_total_chunks)} "
                    f"LS32={fmt_count(len(frame.sensor_received), frame.sensor_total_chunks)} "
                    f"wave_missing={wave_missing} sensor_missing={sensor_missing}"
                ),
            )
        except Exception as exc:
            self.emit("error", title="采集失败", message=str(exc))
        finally:
            if sock is not None:
                sock.close()


class DSHostGui(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("DS System UDP 上位机")
        self.geometry("1280x820")
        self.minsize(1080, 680)

        self.events: "queue.Queue[Dict[str, Any]]" = queue.Queue()
        self.busy = False
        self.streaming = False
        self.stream_stop_event: Optional[threading.Event] = None
        self.stream_started_monotonic: Optional[float] = None
        # Live auto-mode wave view: payloads are placed at their sample offset
        # as WV32 packets arrive and redrawn throttled (~20 fps).
        self.stream_wave_buf: Optional[bytearray] = None
        self.stream_wave_fid: Optional[int] = None
        self.stream_wave_dirty = False
        self.current_frame: Optional[CaptureFrame] = None
        self.wave_points: List[Tuple[int, int, int]] = []
        self.wave_min = 0
        self.wave_max = 65535

        self.board_ip_var = tk.StringVar(value=DEFAULT_BOARD_IP)
        self.board_port_var = tk.StringVar(value=str(DEFAULT_BOARD_PORT))
        self.bind_ip_var = tk.StringVar(value=DEFAULT_BIND_IP)
        self.pc_port_var = tk.StringVar(value=str(DEFAULT_PC_PORT))
        self.output_root_var = tk.StringVar(value=str(DEFAULT_OUTPUT_ROOT))
        self.command_var = tk.StringVar(value="DMA_DEBUG")
        self.split_channels_var = tk.BooleanVar(value=False)
        self.preview_points_var = tk.StringVar(value="1600")
        self.worker_state_var = tk.StringVar(value="空闲")

        # Auto acquisition mode controls (defaults match firmware presets).
        self.auto_rpm_var = tk.StringVar(value="1000")
        self.auto_thr_var = tk.StringVar(value="32000")
        self.auto_points_var = tk.StringVar(value="3125")
        self.auto_vars: Dict[str, tk.StringVar] = {
            "active": tk.StringVar(value="-"),
            "rpm": tk.StringVar(value="-"),
            "t_speed_ms": tk.StringVar(value="-"),
            "thr_um": tk.StringVar(value="-"),
            "points": tk.StringVar(value="-"),
            "t_idle_ms": tk.StringVar(value="-"),
            "last_l2_um": tk.StringVar(value="-"),
            "triggers": tk.StringVar(value="-"),
        }

        self.info_vars: Dict[str, tk.StringVar] = {
            "mode": tk.StringVar(value="-"),
            "frame_id": tk.StringVar(value="-"),
            "elapsed": tk.StringVar(value="-"),
            "wave_chunks": tk.StringVar(value="0/?"),
            "wave_samples": tk.StringVar(value="0/?"),
            "sensor_chunks": tk.StringVar(value="0/?"),
            "sensor_records": tk.StringVar(value="0/?"),
            "summary": tk.StringVar(value="未收到"),
            "missing": tk.StringVar(value="-"),
            "out_dir": tk.StringVar(value="-"),
            "packets": tk.StringVar(value="-"),
        }
        self.cal_vars: Dict[str, tk.StringVar] = {
            "cal_state": tk.StringVar(value="-"),
            "cal_valid": tk.StringVar(value="-"),
            "attempt": tk.StringVar(value="-"),
            "progress": tk.StringVar(value="-"),
            "gain_a_ppm": tk.StringVar(value="-"),
            "gain_b_ppm": tk.StringVar(value="-"),
            "cal_zero_residual_uV": tk.StringVar(value="-"),
            "verify_std_uV": tk.StringVar(value="-"),
            "verify_drift_uV": tk.StringVar(value="-"),
            "me_norm_ppm": tk.StringVar(value="-"),
        }
        self.summary_vars: Dict[str, tk.StringVar] = {
            "adc_a_mVpp": tk.StringVar(value="-"),
            "adc_b_mVpp": tk.StringVar(value="-"),
            "l1_um": tk.StringVar(value="-"),
            "l2_um": tk.StringVar(value="-"),
            "l3_um": tk.StringVar(value="-"),
            "l4_um": tk.StringVar(value="-"),
            "l5_um": tk.StringVar(value="-"),
            "temp_x10": tk.StringVar(value="-"),
            "status": tk.StringVar(value="-"),
            "ls_count": tk.StringVar(value="-"),
            "ls_overflow": tk.StringVar(value="-"),
        }

        self.wave_progress_var = tk.DoubleVar(value=0.0)
        self.sensor_progress_var = tk.DoubleVar(value=0.0)

        self.buttons: List[ttk.Button] = []
        self._build_style()
        self._build_ui()
        self.protocol("WM_DELETE_WINDOW", self._on_close)
        self.after(80, self._poll_events)

    def _build_style(self) -> None:
        style = ttk.Style(self)
        if "clam" in style.theme_names():
            style.theme_use("clam")
        style.configure("Title.TLabel", font=("Microsoft YaHei UI", 11, "bold"))
        style.configure("Status.TLabel", foreground="#374151")
        style.configure("Value.TLabel", foreground="#111827")
        style.configure("Primary.TButton", font=("Microsoft YaHei UI", 10, "bold"))

    def _build_ui(self) -> None:
        self.columnconfigure(0, weight=1)
        self.rowconfigure(1, weight=5)
        self.rowconfigure(2, weight=3)

        self._build_toolbar()
        self._build_main_area()
        self._build_notebook()

    def _build_toolbar(self) -> None:
        bar = ttk.Frame(self, padding=(10, 8, 10, 6))
        bar.grid(row=0, column=0, sticky="ew")
        for col in (1, 3, 5, 7, 9):
            bar.columnconfigure(col, weight=0)
        bar.columnconfigure(11, weight=1)

        ttk.Label(bar, text="板端 IP").grid(row=0, column=0, sticky="w", padx=(0, 4))
        ttk.Entry(bar, textvariable=self.board_ip_var, width=15).grid(
            row=0, column=1, sticky="w", padx=(0, 10)
        )
        ttk.Label(bar, text="板端端口").grid(row=0, column=2, sticky="w", padx=(0, 4))
        ttk.Entry(bar, textvariable=self.board_port_var, width=7).grid(
            row=0, column=3, sticky="w", padx=(0, 10)
        )
        ttk.Label(bar, text="本地绑定").grid(row=0, column=4, sticky="w", padx=(0, 4))
        ttk.Entry(bar, textvariable=self.bind_ip_var, width=13).grid(
            row=0, column=5, sticky="w", padx=(0, 10)
        )
        ttk.Label(bar, text="PC 端口").grid(row=0, column=6, sticky="w", padx=(0, 4))
        ttk.Entry(bar, textvariable=self.pc_port_var, width=7).grid(
            row=0, column=7, sticky="w", padx=(0, 10)
        )

        ttk.Label(bar, text="输出目录").grid(row=0, column=8, sticky="w", padx=(0, 4))
        ttk.Entry(bar, textvariable=self.output_root_var, width=34).grid(
            row=0, column=9, sticky="ew", padx=(0, 4)
        )
        ttk.Button(bar, text="浏览", command=self._browse_output).grid(
            row=0, column=10, sticky="w", padx=(0, 8)
        )

        state_label = ttk.Label(bar, textvariable=self.worker_state_var, style="Status.TLabel")
        state_label.grid(row=0, column=11, sticky="e")

        row2 = ttk.Frame(bar)
        row2.grid(row=1, column=0, columnspan=12, sticky="ew", pady=(8, 0))
        row2.columnconfigure(8, weight=1)

        for text, command, wait_s in (
            ("Ping", "PING", 1.0),
            ("DMA 状态", "DMA_STATUS", 1.2),
            ("校准状态", "CAL_STATUS", 1.2),
            ("开始校准", "CAL_START", 1.5),
        ):
            btn = ttk.Button(row2, text=text, command=lambda c=command, w=wait_s: self._start_command(c, w))
            btn.pack(side=tk.LEFT, padx=(0, 6))
            self.buttons.append(btn)

        capture_btn = ttk.Button(
            row2,
            text="采集一帧",
            style="Primary.TButton",
            command=self._start_capture,
        )
        capture_btn.pack(side=tk.LEFT, padx=(8, 10))
        self.buttons.append(capture_btn)

        ttk.Checkbutton(
            row2,
            text="拆分保存 A/B",
            variable=self.split_channels_var,
        ).pack(side=tk.LEFT, padx=(0, 12))

        ttk.Label(row2, text="自定义命令").pack(side=tk.LEFT, padx=(0, 4))
        ttk.Entry(row2, textvariable=self.command_var, width=20).pack(side=tk.LEFT, padx=(0, 4))
        custom_btn = ttk.Button(row2, text="发送", command=self._start_custom_command)
        custom_btn.pack(side=tk.LEFT)
        self.buttons.append(custom_btn)

        ttk.Button(row2, text="打开输出目录", command=self._open_output_dir).pack(
            side=tk.RIGHT, padx=(6, 0)
        )
        ttk.Button(row2, text="清空日志", command=self._clear_log).pack(side=tk.RIGHT)

        row3 = ttk.Frame(bar)
        row3.grid(row=2, column=0, columnspan=12, sticky="ew", pady=(6, 0))

        ttk.Label(row3, text="自动模式", style="Title.TLabel").pack(side=tk.LEFT, padx=(0, 8))
        ttk.Label(row3, text="转速 rpm").pack(side=tk.LEFT, padx=(0, 4))
        ttk.Entry(row3, textvariable=self.auto_rpm_var, width=7).pack(side=tk.LEFT, padx=(0, 8))
        ttk.Label(row3, text="阈值 um").pack(side=tk.LEFT, padx=(0, 4))
        ttk.Entry(row3, textvariable=self.auto_thr_var, width=8).pack(side=tk.LEFT, padx=(0, 8))
        ttk.Label(row3, text="点数").pack(side=tk.LEFT, padx=(0, 4))
        ttk.Entry(row3, textvariable=self.auto_points_var, width=8).pack(side=tk.LEFT, padx=(0, 8))

        for text, command in (
            ("启动自动", self._start_auto),
            ("应用参数", self._apply_auto_config),
            ("停止自动", lambda: self._start_command("AUTO_STOP", 1.2, True)),
            ("自动状态", lambda: self._start_command("AUTO_STATUS", 1.2, True)),
        ):
            btn = ttk.Button(row3, text=text, command=command)
            btn.pack(side=tk.LEFT, padx=(0, 6))
            self.buttons.append(btn)

        start_and_stream_btn = ttk.Button(
            row3,
            text="启动并记录",
            style="Primary.TButton",
            command=lambda: self._start_auto_stream(start_auto=True),
        )
        start_and_stream_btn.pack(side=tk.LEFT, padx=(10, 6))
        self.buttons.append(start_and_stream_btn)

        stream_start_btn = ttk.Button(
            row3,
            text="仅开始记录",
            command=lambda: self._start_auto_stream(start_auto=False),
        )
        stream_start_btn.pack(side=tk.LEFT, padx=(0, 6))
        self.buttons.append(stream_start_btn)
        # Stop button is managed manually: it must stay clickable while the
        # stream worker keeps the rest of the UI busy.
        self.stream_stop_btn = ttk.Button(
            row3, text="停止记录", command=self._stop_auto_stream, state=tk.DISABLED
        )
        self.stream_stop_btn.pack(side=tk.LEFT, padx=(0, 6))

    def _build_main_area(self) -> None:
        main = ttk.PanedWindow(self, orient=tk.HORIZONTAL)
        main.grid(row=1, column=0, sticky="nsew", padx=10, pady=(0, 8))

        left_outer = ttk.Frame(main, padding=(0, 0, 8, 0))
        right = ttk.Frame(main)
        main.add(left_outer, weight=0)
        main.add(right, weight=4)

        left_outer.rowconfigure(0, weight=1)
        left_outer.columnconfigure(0, weight=1)
        left_canvas = tk.Canvas(left_outer, width=345, highlightthickness=0)
        left_scroll = ttk.Scrollbar(left_outer, orient=tk.VERTICAL, command=left_canvas.yview)
        left_canvas.grid(row=0, column=0, sticky="nsew")
        left_scroll.grid(row=0, column=1, sticky="ns")
        left_canvas.configure(yscrollcommand=left_scroll.set)

        left = ttk.Frame(left_canvas)
        left_window = left_canvas.create_window((0, 0), window=left, anchor=tk.NW)

        def sync_scroll_region(_event: tk.Event) -> None:
            left_canvas.configure(scrollregion=left_canvas.bbox("all"))

        def sync_canvas_width(event: tk.Event) -> None:
            left_canvas.itemconfigure(left_window, width=event.width)

        def bind_mousewheel(_event: tk.Event) -> None:
            left_canvas.bind_all("<MouseWheel>", on_mousewheel)

        def unbind_mousewheel(_event: tk.Event) -> None:
            left_canvas.unbind_all("<MouseWheel>")

        def on_mousewheel(event: tk.Event) -> None:
            left_canvas.yview_scroll(int(-event.delta / 120), "units")

        left.bind("<Configure>", sync_scroll_region)
        left_canvas.bind("<Configure>", sync_canvas_width)
        left_canvas.bind("<Enter>", bind_mousewheel)
        left_canvas.bind("<Leave>", unbind_mousewheel)

        left.columnconfigure(0, weight=1)
        self._build_capture_panel(left)
        self._build_cal_panel(left)
        self._build_auto_panel(left)
        self._build_latest_panel(left)

        right.columnconfigure(0, weight=1)
        right.rowconfigure(1, weight=1)
        wave_top = ttk.Frame(right)
        wave_top.grid(row=0, column=0, sticky="ew", pady=(0, 6))
        wave_top.columnconfigure(1, weight=1)
        ttk.Label(wave_top, text="波形预览", style="Title.TLabel").grid(
            row=0, column=0, sticky="w"
        )
        ttk.Label(wave_top, text="抽样点数").grid(row=0, column=2, sticky="e", padx=(0, 4))
        preview = ttk.Combobox(
            wave_top,
            textvariable=self.preview_points_var,
            values=("800", "1600", "3000", "6000"),
            width=8,
            state="readonly",
        )
        preview.grid(row=0, column=3, sticky="e")
        preview.bind("<<ComboboxSelected>>", lambda _event: self._refresh_wave_preview())

        self.wave_canvas = tk.Canvas(
            right,
            background="#ffffff",
            highlightthickness=1,
            highlightbackground="#d1d5db",
        )
        self.wave_canvas.grid(row=1, column=0, sticky="nsew")
        self.wave_canvas.bind("<Configure>", lambda _event: self._redraw_wave())

    def _build_capture_panel(self, parent: ttk.Frame) -> None:
        panel = ttk.LabelFrame(parent, text="采集信息（手动 / 自动）", padding=10)
        panel.grid(row=0, column=0, sticky="ew", pady=(0, 8))
        panel.columnconfigure(1, weight=1)

        rows = [
            ("模式", "mode"),
            ("帧号", "frame_id"),
            ("耗时", "elapsed"),
            ("波形包", "wave_chunks"),
            ("波形样点", "wave_samples"),
            ("激光包", "sensor_chunks"),
            ("激光记录", "sensor_records"),
            ("Summary", "summary"),
            ("缺包", "missing"),
            ("收包统计", "packets"),
            ("输出", "out_dir"),
        ]
        for row, (label, key) in enumerate(rows):
            ttk.Label(panel, text=label).grid(row=row, column=0, sticky="w", pady=2)
            ttk.Label(panel, textvariable=self.info_vars[key], style="Value.TLabel").grid(
                row=row, column=1, sticky="ew", pady=2
            )

        ttk.Label(panel, text="波形进度").grid(row=len(rows), column=0, sticky="w", pady=(8, 2))
        ttk.Progressbar(panel, variable=self.wave_progress_var, maximum=100).grid(
            row=len(rows), column=1, sticky="ew", pady=(8, 2)
        )
        ttk.Label(panel, text="激光进度").grid(row=len(rows) + 1, column=0, sticky="w", pady=2)
        ttk.Progressbar(panel, variable=self.sensor_progress_var, maximum=100).grid(
            row=len(rows) + 1, column=1, sticky="ew", pady=2
        )

    def _build_cal_panel(self, parent: ttk.Frame) -> None:
        panel = ttk.LabelFrame(parent, text="校准信息", padding=10)
        panel.grid(row=1, column=0, sticky="ew", pady=(0, 8))
        panel.columnconfigure(1, weight=1)

        rows = [
            ("状态", "cal_state"),
            ("有效", "cal_valid"),
            ("尝试", "attempt"),
            ("进度", "progress"),
            ("A 增益", "gain_a_ppm"),
            ("B 增益", "gain_b_ppm"),
            ("零点残差", "cal_zero_residual_uV"),
            ("验证 std", "verify_std_uV"),
            ("验证 drift", "verify_drift_uV"),
            ("ME norm", "me_norm_ppm"),
        ]
        for row, (label, key) in enumerate(rows):
            ttk.Label(panel, text=label).grid(row=row, column=0, sticky="w", pady=2)
            ttk.Label(panel, textvariable=self.cal_vars[key], style="Value.TLabel").grid(
                row=row, column=1, sticky="ew", pady=2
            )

    def _build_auto_panel(self, parent: ttk.Frame) -> None:
        panel = ttk.LabelFrame(parent, text="自动模式", padding=10)
        panel.grid(row=2, column=0, sticky="ew", pady=(0, 8))
        panel.columnconfigure(1, weight=1)

        rows = [
            ("激活", "active"),
            ("转速 rpm", "rpm"),
            ("t_speed ms", "t_speed_ms"),
            ("阈值 um", "thr_um"),
            ("点数", "points"),
            ("t_idle ms", "t_idle_ms"),
            ("最近 L2 um", "last_l2_um"),
            ("触发次数", "triggers"),
        ]
        for row, (label, key) in enumerate(rows):
            ttk.Label(panel, text=label).grid(row=row, column=0, sticky="w", pady=2)
            ttk.Label(panel, textvariable=self.auto_vars[key], style="Value.TLabel").grid(
                row=row, column=1, sticky="ew", pady=2
            )

    def _build_latest_panel(self, parent: ttk.Frame) -> None:
        panel = ttk.LabelFrame(parent, text="本帧摘要", padding=10)
        panel.grid(row=3, column=0, sticky="ew")
        panel.columnconfigure(1, weight=1)

        rows = [
            ("ADC A mVpp", "adc_a_mVpp"),
            ("ADC B mVpp", "adc_b_mVpp"),
            ("激光 1", "l1_um"),
            ("激光 2", "l2_um"),
            ("激光 3", "l3_um"),
            ("激光 4", "l4_um"),
            ("激光 5", "l5_um"),
            ("温度 x10", "temp_x10"),
            ("板端状态", "status"),
            ("LS count", "ls_count"),
            ("LS overflow", "ls_overflow"),
        ]
        for row, (label, key) in enumerate(rows):
            ttk.Label(panel, text=label).grid(row=row, column=0, sticky="w", pady=2)
            ttk.Label(panel, textvariable=self.summary_vars[key], style="Value.TLabel").grid(
                row=row, column=1, sticky="ew", pady=2
            )

    def _build_notebook(self) -> None:
        notebook = ttk.Notebook(self)
        notebook.grid(row=2, column=0, sticky="nsew", padx=10, pady=(0, 10))

        log_frame = ttk.Frame(notebook, padding=6)
        summary_frame = ttk.Frame(notebook, padding=6)
        sensor_frame = ttk.Frame(notebook, padding=6)
        notebook.add(log_frame, text="网口 Log")
        notebook.add(summary_frame, text="Summary")
        notebook.add(sensor_frame, text="激光/温度时间线")

        log_frame.rowconfigure(0, weight=1)
        log_frame.columnconfigure(0, weight=1)
        self.log_text = scrolledtext.ScrolledText(
            log_frame,
            height=8,
            wrap=tk.WORD,
            state=tk.DISABLED,
            font=("Consolas", 10),
        )
        self.log_text.grid(row=0, column=0, sticky="nsew")

        summary_frame.rowconfigure(0, weight=1)
        summary_frame.columnconfigure(0, weight=1)
        self.summary_tree = ttk.Treeview(
            summary_frame,
            columns=("field", "value"),
            show="headings",
            height=8,
        )
        self.summary_tree.heading("field", text="字段")
        self.summary_tree.heading("value", text="值")
        self.summary_tree.column("field", width=220, anchor=tk.W)
        self.summary_tree.column("value", width=420, anchor=tk.W)
        self.summary_tree.grid(row=0, column=0, sticky="nsew")
        summary_scroll = ttk.Scrollbar(
            summary_frame, orient=tk.VERTICAL, command=self.summary_tree.yview
        )
        summary_scroll.grid(row=0, column=1, sticky="ns")
        self.summary_tree.configure(yscrollcommand=summary_scroll.set)

        sensor_frame.rowconfigure(0, weight=1)
        sensor_frame.columnconfigure(0, weight=1)
        self.sensor_tree = ttk.Treeview(
            sensor_frame,
            columns=TIMELINE_COLUMNS,
            show="headings",
            height=8,
        )
        for name in TIMELINE_COLUMNS:
            self.sensor_tree.heading(name, text=name)
            width = 130 if name in ("timestamp_us", "adc_sample_index") else 100
            self.sensor_tree.column(name, width=width, anchor=tk.E, stretch=False)
        self.sensor_tree.grid(row=0, column=0, sticky="nsew")
        sensor_y = ttk.Scrollbar(sensor_frame, orient=tk.VERTICAL, command=self.sensor_tree.yview)
        sensor_y.grid(row=0, column=1, sticky="ns")
        sensor_x = ttk.Scrollbar(sensor_frame, orient=tk.HORIZONTAL, command=self.sensor_tree.xview)
        sensor_x.grid(row=1, column=0, sticky="ew")
        self.sensor_tree.configure(yscrollcommand=sensor_y.set, xscrollcommand=sensor_x.set)

    def _browse_output(self) -> None:
        selected = filedialog.askdirectory(
            initialdir=self.output_root_var.get() or str(DEFAULT_OUTPUT_ROOT)
        )
        if selected:
            self.output_root_var.set(selected)

    def _open_output_dir(self) -> None:
        path = Path(self.output_root_var.get()).expanduser()
        try:
            path.mkdir(parents=True, exist_ok=True)
            os.startfile(str(path))
        except Exception as exc:
            messagebox.showerror("无法打开目录", str(exc))

    def _clear_log(self) -> None:
        self.log_text.configure(state=tk.NORMAL)
        self.log_text.delete("1.0", tk.END)
        self.log_text.configure(state=tk.DISABLED)

    def _on_close(self) -> None:
        if self.streaming and self.stream_stop_event is not None:
            self.stream_stop_event.set()
            self.worker_state_var.set("正在安全结束记录…")
            self.after(100, self._finish_close)
            return
        self.destroy()

    def _finish_close(self) -> None:
        if self.streaming:
            self.after(100, self._finish_close)
        else:
            self.destroy()

    def _append_log(self, message: str) -> None:
        stamp = time.strftime("%H:%M:%S")
        self.log_text.configure(state=tk.NORMAL)
        self.log_text.insert(tk.END, f"[{stamp}] {message}\n")
        self.log_text.see(tk.END)
        self.log_text.configure(state=tk.DISABLED)

    def _parse_config(self) -> Optional[Dict[str, Any]]:
        try:
            board_port = int(self.board_port_var.get().strip())
            pc_port = int(self.pc_port_var.get().strip())
            if not (0 < board_port <= 65535 and 0 < pc_port <= 65535):
                raise ValueError("端口必须在 1 到 65535 之间")
            output_root = Path(self.output_root_var.get()).expanduser()
        except Exception as exc:
            messagebox.showerror("配置错误", str(exc))
            return None

        return {
            "board_ip": self.board_ip_var.get().strip(),
            "board_port": board_port,
            "bind_ip": self.bind_ip_var.get().strip() or DEFAULT_BIND_IP,
            "pc_port": pc_port,
            "output_root": output_root,
            "recv_buffer": DEFAULT_RECV_BUFFER,
            "timeout_s": DEFAULT_TIMEOUT_S,
            "summary_grace_s": DEFAULT_SUMMARY_GRACE_S,
            "split_channels": self.split_channels_var.get(),
        }

    def _make_worker(self) -> Optional[UdpWorker]:
        cfg = self._parse_config()
        if cfg is None:
            return None
        return UdpWorker(self.events, **cfg)

    def _set_busy(self, busy: bool, state: str) -> None:
        self.busy = busy
        self.worker_state_var.set(state)
        button_state = tk.DISABLED if busy else tk.NORMAL
        for button in self.buttons:
            button.configure(state=button_state)

    def _start_thread(self, target: Any, state: str) -> None:
        if self.busy:
            messagebox.showinfo("正在工作", "当前命令或采集还没有完成。")
            return
        self._set_busy(True, state)
        thread = threading.Thread(target=target, daemon=True)
        thread.start()

    def _start_command(
        self,
        command: str,
        wait_s: float,
        stop_on_first_reply: bool = False,
    ) -> None:
        worker = self._make_worker()
        if worker is None:
            return
        self._start_thread(
            lambda: worker.run_command(command, wait_s, stop_on_first_reply),
            f"执行 {command}",
        )

    def _start_custom_command(self) -> None:
        command = self.command_var.get().strip()
        if not command:
            messagebox.showinfo("命令为空", "请输入要发送给板端的 ASCII 命令。")
            return
        self._start_command(command, 1.2)

    def _start_capture(self) -> None:
        worker = self._make_worker()
        if worker is None:
            return
        self._reset_capture_views("手动单帧")
        self._start_thread(worker.run_capture, "采集中")

    def _read_auto_config(self) -> Optional[AutoConfig]:
        try:
            return parse_auto_config(
                self.auto_rpm_var.get(),
                self.auto_thr_var.get(),
                self.auto_points_var.get(),
            )
        except ValueError as exc:
            messagebox.showerror("参数错误", f"自动模式参数无效: {exc}")
            return None

    def _start_auto(self) -> None:
        config = self._read_auto_config()
        if config is not None:
            self._start_command(config.command("AUTO_START"), 1.5, True)

    def _apply_auto_config(self) -> None:
        config = self._read_auto_config()
        if config is not None:
            self._start_command(config.command("AUTO_CFG"), 1.2, True)

    def _start_auto_stream(self, start_auto: bool = False) -> None:
        if self.busy or self.streaming:
            return
        worker = self._make_worker()
        if worker is None:
            return
        startup_command: Optional[str] = None
        if start_auto:
            config = self._read_auto_config()
            if config is None:
                return
            startup_command = config.command("AUTO_START")
        out_dir = unique_output_dir(
            Path(self.output_root_var.get()).expanduser(),
            "auto_log",
        )
        self._reset_capture_views("自动连续")
        self.info_vars["out_dir"].set(str(out_dir))
        self.info_vars["sensor_chunks"].set("自动模式不回传")
        self.info_vars["sensor_records"].set("自动模式不回传")
        self.stream_started_monotonic = time.monotonic()
        stop_event = threading.Event()
        self.stream_stop_event = stop_event
        self.streaming = True
        self._set_busy(True, "连续记录中 0 帧")
        self.stream_stop_btn.configure(state=tk.NORMAL)
        thread = threading.Thread(
            target=lambda: worker.run_auto_stream(
                stop_event,
                out_dir,
                startup_command=startup_command,
            ),
            daemon=True,
        )
        thread.start()

    def _stop_auto_stream(self) -> None:
        if self.stream_stop_event is not None:
            self.stream_stop_event.set()
            self.stream_stop_btn.configure(state=tk.DISABLED)
            self.worker_state_var.set("正在停止记录…")

    def _reset_capture_views(self, mode: str = "-") -> None:
        self.current_frame = None
        self.stream_wave_buf = None
        self.stream_wave_fid = None
        self.stream_wave_dirty = False
        self.wave_points = []
        self.wave_min = 0
        self.wave_max = 65535
        self.wave_progress_var.set(0)
        self.sensor_progress_var.set(0)
        for var in self.info_vars.values():
            var.set("-")
        self.info_vars["mode"].set(mode)
        self.info_vars["wave_chunks"].set("0/?")
        self.info_vars["wave_samples"].set("0/?")
        self.info_vars["sensor_chunks"].set("0/?")
        self.info_vars["sensor_records"].set("0/?")
        self.info_vars["summary"].set("未收到")
        for item in self.summary_tree.get_children():
            self.summary_tree.delete(item)
        for item in self.sensor_tree.get_children():
            self.sensor_tree.delete(item)
        self._redraw_wave()

    def _poll_events(self) -> None:
        try:
            while True:
                event = self.events.get_nowait()
                self._handle_event(event)
        except queue.Empty:
            pass
        self.after(80, self._poll_events)

    def _handle_event(self, event: Dict[str, Any]) -> None:
        kind = event.get("kind")
        if kind == "log":
            message = str(event.get("message", ""))
            self._append_log(message)
            self._ingest_status_line(message)
        elif kind == "progress":
            self._update_progress(event["snapshot"])
        elif kind == "command_done":
            lines: Sequence[str] = event.get("lines", ())
            if not lines:
                self._append_log("#HOST,no_text_reply")
            self._set_busy(False, "空闲")
        elif kind == "capture_done":
            message = str(event.get("message", "capture done"))
            self._append_log(message)
            self._show_frame(event["frame"], Path(event["output_dir"]))
            self._set_busy(False, f"完成 {event.get('status', '')}".strip())
        elif kind == "stream_wave":
            self._ingest_stream_wave(event)
        elif kind == "stream_frame_done":
            summary = event.get("summary", {})
            self._populate_summary(summary)
            self._refresh_summary_labels(summary)
            frame_id = event.get("frame_id")
            complete = bool(event.get("complete"))
            missing = event.get("missing_chunks")
            self.info_vars["frame_id"].set(str(frame_id))
            if self.stream_started_monotonic is not None:
                self.info_vars["elapsed"].set(
                    f"{time.monotonic() - self.stream_started_monotonic:.2f} s（本次记录）"
                )
            self.info_vars["summary"].set("已收到" if summary else "未收到")
            self.info_vars["wave_chunks"].set(
                fmt_count(event.get("received_chunks"), event.get("total_chunks"))
            )
            self.info_vars["wave_samples"].set(
                fmt_count(event.get("received_samples"), event.get("total_samples"))
            )
            self.info_vars["missing"].set(
                f"WV32 {missing if missing is not None else '?'}；"
                f"{'完整，已追加到会话波形文件' if complete else '不完整，未写入波形文件'}"
            )
            complete_frames = event.get("complete_frames", 0)
            incomplete_frames = event.get("incomplete_frames", 0)
            self.info_vars["packets"].set(
                f"WV32 {event.get('received_chunks', 0)}, "
                f"BAD {event.get('bad_datagrams', 0)}"
            )
            self.worker_state_var.set(
                f"连续记录：完整 {complete_frames}，不完整 {incomplete_frames}"
            )
            if not complete:
                self._append_log(
                    f"#HOST,incomplete_frame,frame={frame_id},"
                    f"reason={event.get('reason', '')},missing={missing}"
                )
        elif kind == "stream_done":
            self.streaming = False
            self.stream_stop_event = None
            self.stream_started_monotonic = None
            self.stream_stop_btn.configure(state=tk.DISABLED)
            self._append_log(
                f"#HOST,auto_stream_done,frames={event.get('frames', 0)},"
                f"complete={event.get('complete_frames', 0)},"
                f"incomplete={event.get('incomplete_frames', 0)},"
                f"bad={event.get('bad_datagrams', 0)},"
                f"dir={event.get('output_dir', '')}"
            )
            self._set_busy(False, "空闲")
        elif kind == "error":
            self._append_log(f"#HOST,error,{event.get('message', '')}")
            if self.streaming:
                self.streaming = False
                self.stream_stop_event = None
                self.stream_started_monotonic = None
                self.stream_stop_btn.configure(state=tk.DISABLED)
            self._set_busy(False, "空闲")
            messagebox.showerror(str(event.get("title", "错误")), str(event.get("message", "")))

    def _update_progress(self, snapshot: Dict[str, Any]) -> None:
        frame_id = snapshot.get("frame_id")
        self.info_vars["frame_id"].set(str(frame_id) if frame_id is not None else "-")
        self.info_vars["elapsed"].set(f"{snapshot.get('elapsed_s', 0.0):.2f} s")

        wave_received = snapshot.get("wave_received", 0)
        wave_total = snapshot.get("wave_total")
        wave_samples = snapshot.get("wave_samples", 0)
        wave_sample_total = snapshot.get("wave_sample_total")
        sensor_received = snapshot.get("sensor_received", 0)
        sensor_total = snapshot.get("sensor_total")
        sensor_records = snapshot.get("sensor_records", 0)
        sensor_record_total = snapshot.get("sensor_record_total")

        self.info_vars["wave_chunks"].set(fmt_count(wave_received, wave_total))
        self.info_vars["wave_samples"].set(fmt_count(wave_samples, wave_sample_total))
        self.info_vars["sensor_chunks"].set(fmt_count(sensor_received, sensor_total))
        self.info_vars["sensor_records"].set(fmt_count(sensor_records, sensor_record_total))
        self.info_vars["summary"].set("已收到" if snapshot.get("summary_received") else "未收到")

        if wave_total:
            self.wave_progress_var.set(min(100.0, 100.0 * wave_received / wave_total))
        if sensor_total:
            self.sensor_progress_var.set(min(100.0, 100.0 * sensor_received / sensor_total))

        stats = snapshot.get("stats", {})
        self.info_vars["packets"].set(
            "WV32 {wave_packets}, LS32 {sensor_packets}, TXT {text_packets}, BAD {bad}, UNK {unknown}".format(
                wave_packets=stats.get("wave_packets", 0),
                sensor_packets=stats.get("sensor_packets", 0),
                text_packets=stats.get("text_packets", 0),
                bad=stats.get("wave_bad_packets", 0) + stats.get("sensor_bad_packets", 0),
                unknown=stats.get("unknown_packets", 0),
            )
        )

    def _show_frame(self, frame: CaptureFrame, out_dir: Path) -> None:
        self.current_frame = frame
        self._update_progress(frame_snapshot(frame))
        self.info_vars["out_dir"].set(str(out_dir))
        self.info_vars["missing"].set(
            f"WV32 {len(frame.missing_wave_chunks())}, LS32 {len(frame.missing_sensor_chunks())}"
        )
        self._populate_summary(frame.summary)
        self._populate_sensor_table(frame)
        self._refresh_summary_labels(frame.summary)
        self._refresh_wave_preview()

    def _populate_summary(self, summary: Dict[str, str]) -> None:
        for item in self.summary_tree.get_children():
            self.summary_tree.delete(item)
        keys = list(SUMMARY_COLUMNS)
        for key in summary:
            if key not in keys:
                keys.append(key)
        for key in keys:
            label = SUMMARY_LABELS.get(key, key)
            self.summary_tree.insert("", tk.END, values=(label, summary_value(summary, key)))

    def _populate_sensor_table(self, frame: CaptureFrame) -> None:
        for item in self.sensor_tree.get_children():
            self.sensor_tree.delete(item)
        for record in iter_sensor_records(frame):
            self.sensor_tree.insert("", tk.END, values=record)

    def _refresh_summary_labels(self, summary: Dict[str, str]) -> None:
        for key, var in self.summary_vars.items():
            var.set(summary_value(summary, key))
        for key, var in self.cal_vars.items():
            if key in summary:
                var.set(summary_value(summary, key))

    def _ingest_status_line(self, line: str) -> None:
        tag, values = parse_hash_kv_line(line)
        if tag == "AUTO":
            self._ingest_auto_line(line, values)
            return
        if tag != "CAL":
            return

        state = values.get("state", "")
        state_name = values.get("state_name") or CAL_STATE_NAMES.get(state, "UNKNOWN")
        if state:
            self.cal_vars["cal_state"].set(f"{state} ({state_name})")
        if "valid" in values:
            self.cal_vars["cal_valid"].set(fmt_bool(values["valid"]))
        if "attempt" in values:
            self.cal_vars["attempt"].set(values["attempt"])
        if "progress" in values or "target" in values:
            self.cal_vars["progress"].set(
                fmt_count(
                    int(values.get("progress", "0") or "0"),
                    int(values["target"]) if values.get("target") else None,
                )
            )
        for key in ("gain_a_ppm", "gain_b_ppm", "verify_std_uV", "verify_drift_uV"):
            if key in values:
                self.cal_vars[key].set(values[key])
        if "verify_mean_uV" in values:
            self.cal_vars["cal_zero_residual_uV"].set(values["verify_mean_uV"])

    def _ingest_auto_line(self, line: str, values: Dict[str, str]) -> None:
        """Refresh the auto-mode panel from #AUTO,... lines (STARTED/STOPPED/
        CFG_OK/AUTO_STATUS replies all share the #AUTO tag)."""
        if "STARTED" in line:
            self.auto_vars["active"].set("是")
        if "STOPPED" in line:
            self.auto_vars["active"].set("否")
        for key in ("rpm", "t_speed_ms", "thr_um", "points", "t_idle_ms",
                    "last_l2_um", "triggers"):
            if key in values:
                self.auto_vars[key].set(values[key])
        if "active" in values:
            self.auto_vars["active"].set(fmt_bool(values["active"]))

    def _ingest_stream_wave(self, event: Dict[str, Any]) -> None:
        fid = event.get("frame_id")
        total = int(event.get("total_samples", 0) or 0)
        start = int(event.get("start_sample", 0) or 0)
        payload = event.get("payload", b"")
        if total <= 0 or not payload:
            return
        if (self.stream_wave_fid != fid or self.stream_wave_buf is None
                or len(self.stream_wave_buf) != total * 4):
            self.stream_wave_fid = fid
            self.stream_wave_buf = bytearray(total * 4)
        end = start * 4 + len(payload)
        if end > len(self.stream_wave_buf):
            return
        self.stream_wave_buf[start * 4 : end] = payload
        received_chunks = event.get("received_chunks", 0)
        total_chunks = event.get("total_chunks")
        received_samples = event.get("received_samples", 0)
        self.info_vars["frame_id"].set(str(fid))
        if self.stream_started_monotonic is not None:
            self.info_vars["elapsed"].set(
                f"{time.monotonic() - self.stream_started_monotonic:.2f} s（本次记录）"
            )
        self.info_vars["wave_chunks"].set(fmt_count(received_chunks, total_chunks))
        self.info_vars["wave_samples"].set(fmt_count(received_samples, total))
        if total_chunks:
            self.wave_progress_var.set(
                min(100.0, 100.0 * int(received_chunks or 0) / int(total_chunks))
            )
        if not self.stream_wave_dirty:
            self.stream_wave_dirty = True
            self.after(50, self._redraw_stream_wave)

    def _redraw_stream_wave(self) -> None:
        self.stream_wave_dirty = False
        if self.stream_wave_buf is None:
            return
        data = self.stream_wave_buf
        total_samples = len(data) // 4
        if total_samples <= 0:
            return
        try:
            max_points = int(self.preview_points_var.get())
        except ValueError:
            max_points = 1600
        step = max(1, total_samples // max(1, max_points))
        points: List[Tuple[int, int, int]] = []
        min_v = 32767
        max_v = -32768
        for idx in range(0, total_samples, step):
            a_val, b_val = struct.unpack_from("<hh", data, idx * 4)
            points.append((idx, a_val, b_val))
            min_v = min(min_v, a_val, b_val)
            max_v = max(max_v, a_val, b_val)
        self.wave_points = points
        self.wave_min = min_v
        self.wave_max = max_v
        self._redraw_wave()

    def _refresh_wave_preview(self) -> None:
        if self.streaming and self.stream_wave_buf is not None:
            self._redraw_stream_wave()
            return
        if self.current_frame is None:
            self.wave_points = []
            self._redraw_wave()
            return
        try:
            max_points = int(self.preview_points_var.get())
        except ValueError:
            max_points = 1600
        self.wave_points, self.wave_min, self.wave_max = make_wave_preview(
            self.current_frame, max_points
        )
        self._redraw_wave()

    def _redraw_wave(self) -> None:
        canvas = self.wave_canvas
        canvas.delete("all")
        width = max(canvas.winfo_width(), 200)
        height = max(canvas.winfo_height(), 160)
        margin_l = 54
        margin_r = 20
        margin_t = 24
        margin_b = 36
        plot_w = max(1, width - margin_l - margin_r)
        plot_h = max(1, height - margin_t - margin_b)

        left = margin_l
        right = margin_l + plot_w
        top = margin_t
        bottom = margin_t + plot_h

        canvas.create_rectangle(left, top, right, bottom, outline="#d1d5db", fill="#ffffff")
        for i in range(1, 5):
            y = top + plot_h * i / 5
            canvas.create_line(left, y, right, y, fill="#eef2f7")
        for i in range(1, 6):
            x = left + plot_w * i / 6
            canvas.create_line(x, top, x, bottom, fill="#f3f4f6")

        canvas.create_text(left, 10, anchor=tk.W, text="ADC A", fill="#2563eb", font=("Segoe UI", 9, "bold"))
        canvas.create_text(left + 62, 10, anchor=tk.W, text="ADC B", fill="#dc2626", font=("Segoe UI", 9, "bold"))

        if not self.wave_points:
            canvas.create_text(
                width / 2,
                height / 2,
                text="采集完成后显示本帧波形预览",
                fill="#6b7280",
                font=("Microsoft YaHei UI", 12),
            )
            return

        min_v = self.wave_min
        max_v = self.wave_max
        if max_v <= min_v:
            max_v = min_v + 1
        total_samples = max(1, self.wave_points[-1][0])

        canvas.create_text(
            8,
            top,
            anchor=tk.W,
            text=str(max_v),
            fill="#6b7280",
            font=("Consolas", 8),
        )
        canvas.create_text(
            8,
            bottom,
            anchor=tk.W,
            text=str(min_v),
            fill="#6b7280",
            font=("Consolas", 8),
        )
        sample_total = ADC_SAMPLE_COUNT
        if self.streaming and self.stream_wave_buf is not None:
            sample_total = len(self.stream_wave_buf) // 4
        elif self.current_frame is not None and self.current_frame.wave_total_samples:
            sample_total = self.current_frame.wave_total_samples
        canvas.create_text(
            right,
            height - 16,
            anchor=tk.E,
            text=f"{sample_total:,} samples/channel, int16",
            fill="#6b7280",
            font=("Consolas", 8),
        )

        coords_a: List[float] = []
        coords_b: List[float] = []
        scale_y = plot_h / (max_v - min_v)
        for sample_idx, a_val, b_val in self.wave_points:
            x = left + plot_w * sample_idx / total_samples
            coords_a.extend((x, bottom - (a_val - min_v) * scale_y))
            coords_b.extend((x, bottom - (b_val - min_v) * scale_y))

        if len(coords_a) >= 4:
            canvas.create_line(*coords_a, fill="#2563eb", width=1.5)
            canvas.create_line(*coords_b, fill="#dc2626", width=1.3)


def main() -> int:
    app = DSHostGui()
    app.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
