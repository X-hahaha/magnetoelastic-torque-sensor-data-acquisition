"""Offline regression tests; no board traffic, flashing or experiment files."""
import csv
import json
import queue
import socket
import struct
import tempfile
import threading
import unittest
from collections import deque
from pathlib import Path
from unittest.mock import patch

from ds_host import ADC_SAMPLE_COUNT, CaptureFrame, SUMMARY_COLUMNS, WAVE_HEADER_BYTES
from ds_host_gui import AutoStreamRecorder, CaptureResult, DSHostGui, UdpWorker, format_calibration_progress, preview_sample_indices
from ds_monitor import run_monitor
from ds_torque import ModelCalibration, TorqueModel, TorqueProcessor, validate_settings

CONFIG = dict(rpm=1000, threshold_um=32000, points=16)


def summary(fid, me=1000, **kwargs):
    return dict({key: "0" for key in SUMMARY_COLUMNS}, frame_id=str(fid),
                cal_state="5", cal_valid="1", gain_a_ppm="1000000",
                gain_b_ppm="1000000", me_2x_uV=str(me), adc_a_filt_pp="1000", adc_b_filt_pp="1000", **kwargs)


def line(values):
    return ",".join(values[key] for key in SUMMARY_COLUMNS)


def wave(fid, chunk=0, chunks=1, start=0, count=16, samples=16):
    header = bytearray(WAVE_HEADER_BYTES)
    header[:4] = b"WV32"
    header[4:6] = bytes([1, WAVE_HEADER_BYTES])
    struct.pack_into("<IIIIII", header, 8, fid, chunk, chunks, start, count, samples)
    return bytes(header) + struct.pack("<hh", 12, -13) * count


def sensor(fid, samples=3125, chunk=0, chunks=1, start=0, count=1, records=1):
    header = bytearray(40)
    header[:7] = b"LS32\x01\x28\x28"
    struct.pack_into("<IIIIIII", header, 8, fid, chunk, chunks, start, count, records, samples)
    return bytes(header) + bytes(count * 40)


def capture_packets(samples, with_sensor=True):
    """A complete wire-format capture, ready for offline receiver replay."""
    chunks = (samples + 349) // 350
    packets = [wave(1, i, chunks, i * 350, min(350, samples - i * 350), samples)
               for i in range(chunks)]
    if with_sensor:
        packets.append(sensor(1, samples))
    values = summary(1)
    values["ls_count"] = "1" if with_sensor else "0"
    packets.append(line(values).encode())
    return packets


class CaptureReceiverTests(unittest.TestCase):
    def replay(self, packets, allow_timeouts=False):
        class ReplaySocket:
            def __init__(self):
                self.pending = deque(packets)
                self.now = 0.0
                self.timeouts = 0

            def sendto(self, *args):
                pass

            def recvfrom(self, *args):
                if self.pending:
                    self.now += .000001
                    return self.pending.popleft(), ("127.0.0.1", 5000)
                if not allow_timeouts:
                    raise AssertionError("complete capture must not wait for a socket timeout")
                self.now += .1
                self.timeouts += 1
                raise socket.timeout()

        sock = ReplaySocket()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            worker = UdpWorker(queue.Queue(), "127.0.0.1", 5000, "127.0.0.1", 50010,
                               root, 1 << 24, 60, .8)
            with patch("ds_host_gui.time.monotonic", lambda: sock.now):
                result = worker._receive_capture(sock, root, drain_before=False)
            metadata = json.loads(next(root.glob("*_metadata.json")).read_text(encoding="utf-8"))
            with next(root.glob("*_sensor_timeline.csv")).open(newline="", encoding="utf-8") as f:
                sensor_rows = list(csv.DictReader(f))
        return result, sock, metadata, sensor_rows

    def test_short_frame_sensor_is_saved_without_grace_wait(self):
        result, sock, metadata, rows = self.replay(capture_packets(3125))
        self.assertEqual(result.status, "OK")
        self.assertEqual(sock.timeouts, 0)
        self.assertEqual(result.frame.stats.sensor_bad_packets, 0)
        self.assertEqual(metadata["sensor_timeline"]["total_samples"], 3125)
        self.assertEqual(len(rows), 1)

    def test_zero_sensor_records_finish_without_grace_wait(self):
        result, sock, _, rows = self.replay(capture_packets(3125, with_sensor=False))
        self.assertEqual(result.status, "OK")
        self.assertEqual((sock.timeouts, len(rows)), (0, 0))

    def test_reordered_summary_and_sensor_before_wave(self):
        packets = capture_packets(3125)
        result, sock, _, _ = self.replay([packets[-1], packets[-2]] + packets[:-2][::-1])
        self.assertEqual(result.status, "OK")
        self.assertEqual(sock.timeouts, 0)

    def test_duplicate_is_not_a_missing_chunk_replacement(self):
        packets = capture_packets(3125)
        packets[1] = packets[0]
        result, sock, _, _ = self.replay(packets, allow_timeouts=True)
        self.assertEqual(result.status, "CHECK")
        self.assertEqual(result.frame.missing_wave_chunks(), [1])
        self.assertGreaterEqual(sock.timeouts, 8)

    def test_missing_sensor_stream_is_check_not_ok(self):
        packets = capture_packets(3125)
        del packets[-2]
        result, sock, _, _ = self.replay(packets, allow_timeouts=True)
        self.assertEqual(result.status, "CHECK")
        self.assertFalse(result.frame.all_expected_chunks_received())
        self.assertGreaterEqual(sock.timeouts, 8)

    def test_sensor_and_wave_geometry_must_match_in_both_orders(self):
        for sensor_first in (False, True):
            with self.subTest(sensor_first=sensor_first):
                frame = CaptureFrame(Path("."))
                if sensor_first:
                    frame.accept_sensor(sensor(1, 3125))
                    frame.accept_wave(wave(1, samples=ADC_SAMPLE_COUNT))
                    self.assertEqual(frame.stats.wave_bad_packets, 1)
                    self.assertIsNone(frame.wave_total_samples)
                else:
                    frame.accept_wave(wave(1, samples=3125))
                    frame.accept_sensor(sensor(1, ADC_SAMPLE_COUNT))
                    self.assertEqual(frame.stats.sensor_bad_packets, 1)
                    self.assertIsNone(frame.sensor_total_samples)

    def test_sensor_packets_must_keep_same_sample_count(self):
        frame = CaptureFrame(Path("."))
        frame.accept_sensor(sensor(1, 3125, chunks=2, records=2))
        frame.accept_sensor(sensor(1, ADC_SAMPLE_COUNT, chunk=1, chunks=2, start=1, records=2))
        self.assertEqual(frame.stats.sensor_bad_packets, 1)
        self.assertEqual(frame.sensor_received, {0})

    def test_long_frame_does_not_scan_missing_list_per_packet(self):
        # Counts calls instead of asserting machine-dependent wall-clock speed.
        original = CaptureFrame.missing_wave_chunks
        with patch.object(CaptureFrame, "missing_wave_chunks", autospec=True, side_effect=original) as scans:
            result, sock, _, _ = self.replay(capture_packets(ADC_SAMPLE_COUNT))
        self.assertEqual(result.status, "OK")
        self.assertEqual(len(result.frame.wave_received), 13393)
        self.assertEqual(sock.timeouts, 0)
        self.assertLessEqual(scans.call_count, 2)  # metadata + final diagnostic only


def model():
    return TorqueModel("test", "2026-09-15T00:00:00+08:00", 1000, 100,
                       (1000000, 1000000), CONFIG.copy(), {})


class TorqueTests(unittest.TestCase):
    def test_reference_is_raw_mean_and_setpoint(self):
        trainer = ModelCalibration(100, 1, 3, CONFIG, 0)
        for fid in range(11):
            trainer.add(summary(fid, fid * 10), True, 16, fid / 10)
        self.assertTrue(trainer.poll(1))
        calibrated = trainer.finish()
        self.assertEqual(calibrated.v0_uv, 50)
        self.assertEqual(calibrated.torque(50), 100)
        self.assertIn("setpoint", calibrated.reference_source)
        self.assertEqual(calibrated.statistics["valid_frames"], 11)

    def test_filter_and_quality(self):
        processor = TorqueProcessor(model(), 3, CONFIG)
        results = [processor.process(summary(i, 1000 + i), True, 16, i * .055, "pc") for i in range(3)]
        self.assertEqual(results[1]["torque_nm"], "")
        self.assertEqual(results[2]["quality"], "valid")
        self.assertAlmostEqual(results[2]["torque_nm"], 100.4424)
        self.assertAlmostEqual(results[2]["window_span_s"], .165)
        row = processor.process(summary(4), True, 16, .22, "pc")
        self.assertEqual(row["window_count"], 1)  # lost frame resets window
        row = processor.process(summary(5), False, 16, .275, "pc")
        self.assertEqual(row["quality"], "incomplete_frame")
        row = processor.process(summary(6), True, 16, .33, "pc")
        self.assertEqual(row["window_count"], 1)

    def test_no_implicit_historical_model(self):
        row = TorqueProcessor(None, 1, CONFIG).process(summary(1), True, 16, 0, "pc")
        self.assertEqual(row["quality"], "no_model")
        self.assertEqual(row["torque_nm"], "")

    def test_gains_invalidate_model(self):
        processor = TorqueProcessor(model(), 1, CONFIG)
        s = summary(1)
        s["gain_a_ppm"] = "999999"
        row = processor.process(s, True, 16, 0, "pc")
        self.assertEqual(row["quality"], "gains_changed_model_invalidated")
        self.assertIsNone(processor.model)

    def test_setting_mismatch_and_long_window(self):
        processor = TorqueProcessor(model(), 2, CONFIG)
        self.assertEqual(processor.process(summary(1), True, 3125, 0, "pc")["quality"], "sample_count_mismatch")
        processor.process(summary(2), True, 16, 1, "pc")
        row = processor.process(summary(3), True, 16, 5, "pc")
        self.assertEqual(row["quality"], "window_exceeds_5s")
        self.assertEqual(row["torque_nm"], "")

    def test_training_timeouts_and_changed_gains(self):
        trainer = ModelCalibration(100, 60, 15, CONFIG, 0)
        with self.assertRaises(ValueError):
            trainer.poll(21)
        trainer.add(summary(1), True, 16, 1)
        with self.assertRaises(ValueError):
            trainer.poll(7)
        s = summary(2)
        s["gain_b_ppm"] = "999999"
        with self.assertRaises(ValueError):
            trainer.add(s, True, 16, 2)

    def test_validation_and_progress(self):
        for args in (("nan", "60", "15"), ("100", "0", "15"), ("100", "60", "0"), ("100", "60", "1.5")):
            with self.assertRaises(ValueError):
                validate_settings(*args)
        self.assertIn("104/200", format_calibration_progress(dict(state="4", progress="0", attempt="1")))
        self.assertIn("272/400", format_calibration_progress(dict(state="4", progress="0", attempt="1",
                                                                  discard_frames="16", collect_frames="256", verify_frames="128")))
        indices = preview_sample_indices(3125, 3000)
        self.assertEqual((len(indices), indices[0], indices[-1]), (3000, 0, 3124))

    def test_overrange_and_invalid_channel_are_not_torque(self):
        processor = TorqueProcessor(model(), 1, CONFIG)
        s = summary(1)
        s["status"] = "0x01000000"
        self.assertEqual(processor.process(s, True, 16, 0, "pc")["quality"], "adc_overrange")
        s = summary(2)
        s["cal_valid"] = "0"
        self.assertEqual(processor.process(s, True, 16, 1, "pc")["quality"], "channel_calibration_invalid")
        self.assertIsNone(processor.model)

    def test_model_snapshot_is_immutable(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "model.json"
            model().save(path)
            with self.assertRaises(FileExistsError):
                model().save(path)

    def test_200nm_check_is_peak_to_peak_not_plus_minus(self):
        trainer = ModelCalibration(100, 1, 1, CONFIG, 0)
        for i in range(11):
            trainer.add(summary(i, 1000 + (600 if i % 2 else 0)), True, 16, i / 10)
        self.assertGreater(trainer.finish().statistics["filtered_peak_to_peak_nm"], 200)
        self.assertFalse(trainer.finish().statistics["stability_check_passed"])


class ChannelCalibrationTests(unittest.TestCase):
    def test_one_click_executes_200_short_captures(self):
        with tempfile.TemporaryDirectory() as tmp:
            events = queue.Queue()
            worker = UdpWorker(events, "127.0.0.1", 1, "127.0.0.1", 2, Path(tmp), 65536, 1, .1)
            count = [0]
            commands = []
            class FakeSocket:
                def close(self):
                    pass
            worker.open_socket = FakeSocket
            worker.drain_text = lambda *args: []
            def status(sock, command, timeout_s):
                commands.append(command)
                stage = "1" if count[0] < 8 else "2" if count[0] < 104 else "4" if count[0] < 200 else "5"
                return dict(state=stage, valid="1" if stage == "5" else "0", attempt="1",
                            points="3125", cal_protocol="2", discard_frames="8", collect_frames="96", verify_frames="96")
            def capture(sock, output_dir, drain_before):
                count[0] += 1
                frame = CaptureFrame(output_dir=output_dir)
                frame.frame_id, frame.wave_total_samples = count[0], 3125
                return CaptureResult(frame, output_dir, "OK", "test", None)
            worker._request_calibration_status, worker._receive_capture = status, capture
            worker.run_calibration()
            results = list(events.queue)
            self.assertEqual(count[0], 200)
            self.assertEqual(commands[0], "CAL_START_SHORT")
            self.assertEqual(commands.count("CAL_STATUS"), 200)
            self.assertEqual(results[-1]["kind"], "calibration_done")
            self.assertTrue(results[-1]["success"])

    def test_old_firmware_never_falls_back_to_long_calibration(self):
        with tempfile.TemporaryDirectory() as tmp:
            events = queue.Queue()
            worker = UdpWorker(events, "127.0.0.1", 1, "127.0.0.1", 2, Path(tmp), 65536, 1, .1)
            class FakeSocket:
                def close(self):
                    pass
            worker.open_socket = FakeSocket
            worker.drain_text = lambda *args: []
            worker._request_calibration_status = lambda *args, **kw: dict(state="1", valid="0")
            worker._receive_capture = lambda *args, **kw: self.fail("old firmware must not capture")
            worker.run_calibration()
            self.assertEqual(list(events.queue)[-1]["kind"], "error")


class RecordingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.events = []
        self.stream = AutoStreamRecorder(self.root, lambda kind, **args: self.events.append(dict(kind=kind, **args)), .1)
        processor = TorqueProcessor(model(), 1, CONFIG)
        self.stream.on_frame = lambda a: processor.process(a.frame.summary, a.complete(), a.frame.wave_total_samples,
                                                         a.summary_seen_monotonic or 0, "pc")

    def tearDown(self):
        self.stream.close()
        self.temp.cleanup()

    def frame(self, fid):
        self.stream.accept_wave(wave(fid))
        self.stream.accept_summary(line(summary(fid)))

    def rows(self, path):
        with path.open(newline="", encoding="utf-8") as handle:
            return list(csv.DictReader(handle))

    def test_monitoring_without_disk_and_repeated_sessions(self):
        self.frame(1)
        self.assertEqual(list(self.root.iterdir()), [])
        self.stream.start_recording(self.root / "first", {"kind": "experiment"})
        self.frame(2)
        self.stream.stop_recording()
        self.frame(3)
        self.stream.start_recording(self.root / "second", {"kind": "experiment"})
        self.frame(4)
        self.stream.stop_recording()
        for folder, fid in (("first", "2"), ("second", "4")):
            rows = self.rows(self.root / folder / "torque.csv")
            self.assertEqual([r["frame_id"] for r in rows], [fid])
            self.assertEqual(rows[0]["torque_nm"], "100.0")
            self.assertEqual((self.root / folder / "wave_interleaved_a_b_u16le.bin").stat().st_size, 64)
        self.assertEqual(self.stream.finalized_count, 4)

    def test_stop_drains_inflight_but_excludes_new_frames(self):
        self.stream.start_recording(self.root / "record", {"kind": "experiment"})
        self.stream.accept_wave(wave(1))
        self.stream.stop_recording()
        self.assertIsNotNone(self.stream.session)
        self.frame(2)
        self.stream.accept_summary(line(summary(1)))
        self.assertIsNone(self.stream.session)
        self.assertEqual([r["frame_id"] for r in self.rows(self.root / "record" / "summary.csv")], ["1"])

    def test_start_excludes_preexisting_inflight_and_incomplete_wave(self):
        self.stream.accept_wave(wave(1))
        self.stream.start_recording(self.root / "record", {"kind": "experiment"})
        self.stream.accept_summary(line(summary(1)))
        self.stream.accept_wave(wave(2, chunks=2, count=8))
        self.stream.accept_summary(line(summary(2)))
        self.stream.close()
        rows = self.rows(self.root / "record" / "integrity.csv")
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["frame_id"], "2")
        self.assertEqual(rows[0]["wave_saved"], "0")
        self.assertEqual((self.root / "record" / "wave_interleaved_a_b_u16le.bin").stat().st_size, 0)

    def test_duplicates_never_duplicate_measurement_or_wave(self):
        self.stream.start_recording(self.root / "record", {"kind": "experiment"})
        self.frame(1)
        self.frame(1)
        self.stream.stop_recording()
        self.assertEqual(len(self.rows(self.root / "record" / "torque.csv")), 1)


class MonitorTests(unittest.TestCase):
    def test_full_training_record_stop_restart_workflow(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            commands, events = queue.Queue(), queue.Queue()
            stop = threading.Event()
            clock = [10.0]
            worker = UdpWorker(events, "127.0.0.1", 5000, "127.0.0.1", 50010, root, 65536, 1, .1)
            received, sent = [], []

            class FakeSocket:
                closed = False
                def __init__(self):
                    self.packets = deque()
                    for fid in range(1, 41):
                        self.packets.extend([wave(fid), line(summary(fid)).encode()])
                def recvfrom(self, _size):
                    clock[0] += .03
                    if not self.packets:
                        stop.set()
                        raise socket.timeout()
                    return self.packets.popleft(), ("127.0.0.1", 5000)
                def close(self):
                    self.closed = True

            sock = FakeSocket()
            worker.open_socket = lambda: sock

            def send(_sock, command):
                sent.append(command)
                sock.packets.appendleft(b"#AUTO,STOPPED" if command == "AUTO_STOP" else b"#AUTO,STARTED")

            def emit(kind, **args):
                received.append(dict(kind=kind, **args))
                if kind == "model_finished" and args.get("success"):
                    commands.put(dict(kind="record_start", path=root / "first"))
                if kind == "stream_frame_done":
                    if args["frame_id"] == 27:
                        commands.put(dict(kind="record_stop"))
                    if args["frame_id"] == 30:
                        commands.put(dict(kind="record_start", path=root / "second"))
                    if args["frame_id"] == 40:
                        stop.set()

            worker.send_command, worker.emit = send, emit
            with patch("time.monotonic", side_effect=lambda: clock[0]):
                run_monitor(worker, AutoStreamRecorder, stop, commands, CONFIG, None, 3,
                            dict(kind="model_start", t0=100, duration=1, path=root / "training"))
            errors = [e for e in received if e["kind"] in ("error", "action_error")]
            self.assertEqual(errors, [])
            self.assertTrue(sock.closed)
            self.assertEqual(sent, ["AUTO_START,1000,32000,16", "AUTO_STOP"])
            self.assertTrue((root / "training" / "model.json").exists())
            torque_events = {str(e["row"]["frame_id"]): e["row"] for e in received if e["kind"] == "torque_sample"}
            for folder in ("first", "second"):
                with (root / folder / "torque.csv").open(newline="") as handle:
                    rows = list(csv.DictReader(handle))
                self.assertTrue(rows)
                for row in rows:
                    expected = torque_events[row["frame_id"]]
                    self.assertEqual(row["torque_nm"], str(expected["torque_nm"]))
                    self.assertEqual(row["model_id"], expected["model_id"])
                self.assertEqual(json.loads((root / folder / "session.json").read_text(encoding="utf-8"))["average_frames"], 3)
            self.assertEqual(received[-1]["kind"], "stream_done")
            self.assertFalse(received[-1]["monitoring_active"])


class GuiTests(unittest.TestCase):
    def test_widgets_and_control_states_without_board(self):
        app = DSHostGui()
        app.withdraw()
        try:
            app.update_idletasks()
            self.assertEqual(str(app.start_monitor_btn.cget("text")), "开始监测")
            app.streaming = app.monitoring = app.busy = True
            app._refresh_control_states()
            self.assertEqual(str(app.record_start_btn.cget("state")), "normal")
            self.assertTrue(all(str(w.cget("state")) == "disabled" for w in app.l2_parameter_entries))
            app._handle_event(dict(kind="recording_started", output_dir=Path("test")))
            self.assertEqual(str(app.stream_stop_btn.cget("state")), "normal")
            app._handle_event(dict(kind="recording_done", output_dir=Path("test")))
            self.assertTrue(app.streaming)
            app._handle_event(dict(kind="stream_done", monitoring_active=False))
            self.assertTrue(all(str(w.cget("state")) == "normal" for w in app.l2_parameter_entries))
            app.torque_model = model()
            app._ingest_status_line("#CAL,event=CLEARED,state=0,valid=0")
            self.assertIsNone(app.torque_model)
        finally:
            app.destroy()


if __name__ == "__main__":
    unittest.main(verbosity=2)
