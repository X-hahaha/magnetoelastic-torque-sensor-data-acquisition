#!/usr/bin/env python3
"""
Host-side UDP receiver/controller for the DS_system_02ms firmware.

Board protocol:
  PC local UDP port 50010 -> board UDP port 5000: ASCII commands.
  Board -> PC local UDP port 50010:
    WV32 packets: raw waveform, each sample is little-endian uint16 A + uint16 B.
    LS32 packets: laser/temperature timeline records.
    CSV/text packets: summary and status lines.

The board does not retransmit UDP packets. This program records packet loss in
metadata and never starts a second capture until the previous transaction has
ended.
"""

from __future__ import annotations

import argparse
import csv
import datetime as _dt
import json
import os
import socket
import struct
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple


DEFAULT_BOARD_IP = "192.168.1.10"
DEFAULT_BIND_IP = "0.0.0.0"
DEFAULT_BOARD_PORT = 5000
DEFAULT_PC_PORT = 50010

ADC_SAMPLE_COUNT = 4_687_500
WAVE_HEADER_BYTES = 40
LS32_HEADER_BYTES = 40
LS32_RECORD_BYTES = 40

WV32_MAGIC = b"WV32"
LS32_MAGIC = b"LS32"

SUMMARY_COLUMNS = [
    "frame_id",
    "adc_a_raw_pp",
    "adc_b_raw_pp",
    "adc_a_filt_pp",
    "adc_b_filt_pp",
    "adc_a_mVpp",
    "adc_b_mVpp",
    "l1_um",
    "l2_um",
    "l3_um",
    "l4_um",
    "l5_um",
    "temp_x10",
    "status",
    "missed_total",
    "cal_state",
    "cal_valid",
    "gain_a_ppm",
    "gain_b_ppm",
    "adc_a_corr_uVpp",
    "adc_b_corr_uVpp",
    "me_2x_uV",
    "me_norm_ppm",
    "cal_zero_residual_uV",
    "ls_count",
    "ls_overflow",
]

TIMELINE_COLUMNS = [
    "timestamp_us",
    "adc_sample_index",
    "update_mask",
    "sensor_status",
    "l1_um",
    "l2_um",
    "l3_um",
    "l4_um",
    "l5_um",
    "temp_x10",
]


def now_stamp() -> str:
    return _dt.datetime.now().strftime("%Y%m%d_%H%M%S")


def u32_at(buf: bytes, offset: int) -> int:
    return struct.unpack_from("<I", buf, offset)[0]


def parse_text_datagram(data: bytes) -> Optional[str]:
    try:
        text = data.decode("ascii", errors="strict")
    except UnicodeDecodeError:
        return None
    text = text.strip("\r\n\0 ")
    return text if text else None


def is_summary_row(text: str) -> bool:
    if not text or text.startswith("#"):
        return False
    first = text[0]
    return first.isdigit()


def parse_summary_row(text: str) -> Dict[str, str]:
    values = next(csv.reader([text]))
    result: Dict[str, str] = {}
    for idx, value in enumerate(values):
        key = SUMMARY_COLUMNS[idx] if idx < len(SUMMARY_COLUMNS) else f"extra_{idx}"
        result[key] = value
    return result


@dataclass
class PacketStats:
    wave_packets: int = 0
    wave_duplicates: int = 0
    wave_bad_packets: int = 0
    sensor_packets: int = 0
    sensor_duplicates: int = 0
    sensor_bad_packets: int = 0
    text_packets: int = 0
    unknown_packets: int = 0


@dataclass
class CaptureFrame:
    output_dir: Path
    start_time: float = field(default_factory=time.time)
    end_time: Optional[float] = None
    frame_id: Optional[int] = None

    wave_total_chunks: Optional[int] = None
    wave_total_samples: Optional[int] = None
    wave_bytes: Optional[bytearray] = None
    wave_received: set = field(default_factory=set)
    wave_chunk_sample_counts: Dict[int, int] = field(default_factory=dict)
    wave_a_mVpp_hint: Optional[int] = None
    wave_b_mVpp_hint: Optional[int] = None

    sensor_total_chunks: Optional[int] = None
    sensor_total_records: Optional[int] = None
    sensor_records_bytes: Optional[bytearray] = None
    sensor_received: set = field(default_factory=set)
    sensor_chunk_record_counts: Dict[int, int] = field(default_factory=dict)

    summary_text: Optional[str] = None
    summary: Dict[str, str] = field(default_factory=dict)
    messages: List[str] = field(default_factory=list)
    stats: PacketStats = field(default_factory=PacketStats)

    def accept_wave(self, data: bytes) -> None:
        if len(data) < WAVE_HEADER_BYTES or data[:4] != WV32_MAGIC:
            self.stats.wave_bad_packets += 1
            return

        version = data[4]
        header_len = data[5]
        frame_id = u32_at(data, 8)
        chunk_idx = u32_at(data, 12)
        total_chunks = u32_at(data, 16)
        start_sample = u32_at(data, 20)
        count = u32_at(data, 24)
        total_samples = u32_at(data, 28)
        a_mVpp = u32_at(data, 32)
        b_mVpp = u32_at(data, 36)

        if version != 1 or header_len != WAVE_HEADER_BYTES:
            self.stats.wave_bad_packets += 1
            return
        payload = data[header_len:]
        expected_len = count * 4
        if len(payload) != expected_len:
            self.stats.wave_bad_packets += 1
            return

        self._adopt_frame_id(frame_id)
        if self.frame_id != frame_id:
            self.stats.wave_bad_packets += 1
            return

        if self.wave_total_chunks is None:
            self.wave_total_chunks = total_chunks
            self.wave_total_samples = total_samples
            self.wave_bytes = bytearray(total_samples * 4)
            self.wave_a_mVpp_hint = a_mVpp
            self.wave_b_mVpp_hint = b_mVpp
        elif self.wave_total_chunks != total_chunks or self.wave_total_samples != total_samples:
            self.stats.wave_bad_packets += 1
            return

        if chunk_idx in self.wave_received:
            self.stats.wave_duplicates += 1
            return
        if chunk_idx >= (self.wave_total_chunks or 0):
            self.stats.wave_bad_packets += 1
            return
        if start_sample + count > (self.wave_total_samples or 0):
            self.stats.wave_bad_packets += 1
            return

        assert self.wave_bytes is not None
        offset = start_sample * 4
        self.wave_bytes[offset : offset + len(payload)] = payload
        self.wave_received.add(chunk_idx)
        self.wave_chunk_sample_counts[chunk_idx] = count
        self.stats.wave_packets += 1

    def accept_sensor(self, data: bytes) -> None:
        if len(data) < LS32_HEADER_BYTES or data[:4] != LS32_MAGIC:
            self.stats.sensor_bad_packets += 1
            return

        version = data[4]
        header_len = data[5]
        record_len = data[6]
        frame_id = u32_at(data, 8)
        chunk_idx = u32_at(data, 12)
        total_chunks = u32_at(data, 16)
        start_record = u32_at(data, 20)
        count = u32_at(data, 24)
        total_records = u32_at(data, 28)
        total_samples = u32_at(data, 32)

        if version != 1 or header_len != LS32_HEADER_BYTES or record_len != LS32_RECORD_BYTES:
            self.stats.sensor_bad_packets += 1
            return
        payload = data[header_len:]
        expected_len = count * LS32_RECORD_BYTES
        if len(payload) != expected_len:
            self.stats.sensor_bad_packets += 1
            return
        if total_samples != ADC_SAMPLE_COUNT:
            self.stats.sensor_bad_packets += 1
            return

        self._adopt_frame_id(frame_id)
        if self.frame_id != frame_id:
            self.stats.sensor_bad_packets += 1
            return

        if self.sensor_total_chunks is None:
            self.sensor_total_chunks = total_chunks
            self.sensor_total_records = total_records
            self.sensor_records_bytes = bytearray(total_records * LS32_RECORD_BYTES)
        elif self.sensor_total_chunks != total_chunks or self.sensor_total_records != total_records:
            self.stats.sensor_bad_packets += 1
            return

        if chunk_idx in self.sensor_received:
            self.stats.sensor_duplicates += 1
            return
        if chunk_idx >= (self.sensor_total_chunks or 0):
            self.stats.sensor_bad_packets += 1
            return
        if start_record + count > (self.sensor_total_records or 0):
            self.stats.sensor_bad_packets += 1
            return

        assert self.sensor_records_bytes is not None
        offset = start_record * LS32_RECORD_BYTES
        self.sensor_records_bytes[offset : offset + len(payload)] = payload
        self.sensor_received.add(chunk_idx)
        self.sensor_chunk_record_counts[chunk_idx] = count
        self.stats.sensor_packets += 1

    def accept_text(self, text: str) -> None:
        self.stats.text_packets += 1
        for line in text.splitlines():
            line = line.strip()
            if not line:
                continue
            self.messages.append(line)
            if is_summary_row(line):
                parsed = parse_summary_row(line)
                try:
                    fid = int(parsed.get("frame_id", ""), 10)
                except ValueError:
                    continue
                self._adopt_frame_id(fid)
                if self.frame_id == fid:
                    self.summary_text = line
                    self.summary = parsed
                    self.end_time = time.time()

    def _adopt_frame_id(self, frame_id: int) -> None:
        if self.frame_id is None:
            self.frame_id = frame_id

    @property
    def summary_received(self) -> bool:
        return self.summary_text is not None

    def complete_enough(self) -> bool:
        return self.summary_received

    def all_expected_chunks_received(self) -> bool:
        wave_ok = (
            self.wave_total_chunks is not None
            and len(self.wave_received) >= self.wave_total_chunks
        )
        sensor_ok = (
            self.sensor_total_chunks is not None
            and len(self.sensor_received) >= self.sensor_total_chunks
        )
        return wave_ok and sensor_ok

    def has_payload(self) -> bool:
        return bool(self.wave_received or self.sensor_received or self.summary_received)

    def missing_wave_chunks(self) -> List[int]:
        if self.wave_total_chunks is None:
            return []
        return [i for i in range(self.wave_total_chunks) if i not in self.wave_received]

    def missing_sensor_chunks(self) -> List[int]:
        if self.sensor_total_chunks is None:
            return []
        return [i for i in range(self.sensor_total_chunks) if i not in self.sensor_received]

    def write_outputs(self, split_channels: bool = False) -> Path:
        frame_tag = f"frame_{self.frame_id:06d}" if self.frame_id is not None else "frame_unknown"
        self.output_dir.mkdir(parents=True, exist_ok=True)

        if self.wave_bytes is not None:
            wave_path = self.output_dir / f"{frame_tag}_wave_interleaved_a_b_u16le.bin"
            wave_path.write_bytes(self.wave_bytes)
            if split_channels:
                self._write_split_channels(frame_tag)

        self._write_sensor_csv(frame_tag)
        self._write_summary_csv(frame_tag)
        self._write_messages(frame_tag)
        self._write_metadata(frame_tag)
        return self.output_dir

    def _write_split_channels(self, frame_tag: str) -> None:
        assert self.wave_bytes is not None
        a_path = self.output_dir / f"{frame_tag}_adc_a_u16le.bin"
        b_path = self.output_dir / f"{frame_tag}_adc_b_u16le.bin"
        with a_path.open("wb") as fa, b_path.open("wb") as fb:
            data = self.wave_bytes
            for off in range(0, len(data), 4):
                fa.write(data[off : off + 2])
                fb.write(data[off + 2 : off + 4])

    def _write_sensor_csv(self, frame_tag: str) -> None:
        path = self.output_dir / f"{frame_tag}_sensor_timeline.csv"
        with path.open("w", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            writer.writerow(TIMELINE_COLUMNS)
            if self.sensor_records_bytes is None:
                return
            for offset in range(0, len(self.sensor_records_bytes), LS32_RECORD_BYTES):
                record = self.sensor_records_bytes[offset : offset + LS32_RECORD_BYTES]
                if len(record) < LS32_RECORD_BYTES:
                    break
                values = struct.unpack("<IIIIiiiiii", record)
                writer.writerow(values)

    def _write_summary_csv(self, frame_tag: str) -> None:
        path = self.output_dir / f"{frame_tag}_summary.csv"
        with path.open("w", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            writer.writerow(SUMMARY_COLUMNS)
            if self.summary:
                writer.writerow([self.summary.get(name, "") for name in SUMMARY_COLUMNS])

    def _write_messages(self, frame_tag: str) -> None:
        path = self.output_dir / f"{frame_tag}_messages.txt"
        path.write_text("\n".join(self.messages) + ("\n" if self.messages else ""), encoding="utf-8")

    def _write_metadata(self, frame_tag: str) -> None:
        metadata = {
            "frame_id": self.frame_id,
            "start_time_local": _dt.datetime.fromtimestamp(self.start_time).isoformat(),
            "end_time_local": _dt.datetime.fromtimestamp(self.end_time or time.time()).isoformat(),
            "elapsed_s": (self.end_time or time.time()) - self.start_time,
            "adc_sample_count_expected": ADC_SAMPLE_COUNT,
            "wave": {
                "total_chunks": self.wave_total_chunks,
                "received_chunks": len(self.wave_received),
                "missing_chunks": self.missing_wave_chunks(),
                "duplicate_chunks": self.stats.wave_duplicates,
                "bad_packets": self.stats.wave_bad_packets,
                "total_samples": self.wave_total_samples,
                "a_mVpp_hint": self.wave_a_mVpp_hint,
                "b_mVpp_hint": self.wave_b_mVpp_hint,
            },
            "sensor_timeline": {
                "total_chunks": self.sensor_total_chunks,
                "received_chunks": len(self.sensor_received),
                "missing_chunks": self.missing_sensor_chunks(),
                "duplicate_chunks": self.stats.sensor_duplicates,
                "bad_packets": self.stats.sensor_bad_packets,
                "total_records": self.sensor_total_records,
            },
            "summary": self.summary,
            "packet_stats": self.stats.__dict__,
        }
        path = self.output_dir / f"{frame_tag}_metadata.json"
        path.write_text(json.dumps(metadata, indent=2, ensure_ascii=False), encoding="utf-8")


class DSHost:
    def __init__(
        self,
        board_ip: str,
        board_port: int,
        bind_ip: str,
        pc_port: int,
        recv_buffer: int,
        timeout_s: float,
        summary_grace_s: float,
        quiet: bool = False,
    ) -> None:
        self.board_addr = (board_ip, board_port)
        self.timeout_s = timeout_s
        self.summary_grace_s = summary_grace_s
        self.quiet = quiet
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, recv_buffer)
        self.sock.bind((bind_ip, pc_port))
        self.sock.settimeout(0.25)

    def close(self) -> None:
        self.sock.close()

    def send_command(self, command: str) -> None:
        payload = command.strip().encode("ascii")
        self.sock.sendto(payload, self.board_addr)
        self._log(f"> {command.strip()}")

    def drain(self, duration_s: float = 0.2) -> List[str]:
        deadline = time.time() + duration_s
        lines: List[str] = []
        while time.time() < deadline:
            try:
                data, _addr = self.sock.recvfrom(2048)
            except socket.timeout:
                continue
            text = parse_text_datagram(data)
            if text is not None:
                for line in text.splitlines():
                    line = line.strip()
                    if line:
                        lines.append(line)
                        self._log(line)
        return lines

    def transact_text(self, command: str, wait_s: float) -> List[str]:
        self.send_command(command)
        return self.drain(wait_s)

    def capture(self, output_root: Path, split_channels: bool = False) -> CaptureFrame:
        capture_dir = output_root / f"capture_{now_stamp()}"
        frame = CaptureFrame(output_dir=capture_dir)

        self.drain(0.1)
        self.send_command("CAPTURE")
        return self._receive_frame(frame, split_channels)

    def capture_passive(self, output_root: Path, split_channels: bool = False) -> CaptureFrame:
        """Receive one frame without sending CAPTURE (auto mode triggers board-side)."""
        capture_dir = output_root / f"capture_{now_stamp()}"
        frame = CaptureFrame(output_dir=capture_dir)

        self.drain(0.1)
        return self._receive_frame(frame, split_channels)

    def _receive_frame(self, frame: CaptureFrame, split_channels: bool) -> CaptureFrame:
        deadline = time.time() + self.timeout_s
        summary_deadline: Optional[float] = None
        last_progress = time.time()
        while time.time() < deadline:
            try:
                data, _addr = self.sock.recvfrom(65535)
            except socket.timeout:
                if summary_deadline is not None and time.time() >= summary_deadline:
                    break
                if time.time() - last_progress > 2.0:
                    self._print_progress(frame)
                    last_progress = time.time()
                continue

            if data.startswith(WV32_MAGIC):
                frame.accept_wave(data)
                last_progress = time.time()
            elif data.startswith(LS32_MAGIC):
                frame.accept_sensor(data)
                last_progress = time.time()
            else:
                text = parse_text_datagram(data)
                if text is None:
                    frame.stats.unknown_packets += 1
                else:
                    had_summary = frame.summary_received
                    frame.accept_text(text)
                    for line in text.splitlines():
                        clean = line.strip()
                        if clean:
                            self._log(clean)
                            if clean.startswith(("#ERR", "#BUSY")) and not frame.has_payload():
                                frame.end_time = time.time()
                                frame.write_outputs(split_channels=split_channels)
                                self._print_done(frame, frame.output_dir)
                                return frame
                    if frame.summary_received and not had_summary:
                        summary_deadline = time.time() + self.summary_grace_s
                last_progress = time.time()

            if frame.summary_received and frame.all_expected_chunks_received():
                break
            if summary_deadline is not None and time.time() >= summary_deadline:
                break

        if not frame.complete_enough():
            frame.end_time = time.time()
            frame.messages.append("#HOST,timeout_waiting_for_summary")

        out_dir = frame.write_outputs(split_channels=split_channels)
        self._print_done(frame, out_dir)
        return frame

    def _print_progress(self, frame: CaptureFrame) -> None:
        if self.quiet:
            return
        wave = "?"
        if frame.wave_total_chunks is not None:
            wave = f"{len(frame.wave_received)}/{frame.wave_total_chunks}"
        sensor = "?"
        if frame.sensor_total_chunks is not None:
            sensor = f"{len(frame.sensor_received)}/{frame.sensor_total_chunks}"
        print(f"... receiving frame={frame.frame_id} WV32={wave} LS32={sensor}", flush=True)

    def _print_done(self, frame: CaptureFrame, out_dir: Path) -> None:
        if self.quiet:
            return
        wave_missing = len(frame.missing_wave_chunks())
        sensor_missing = len(frame.missing_sensor_chunks())
        status = "OK" if frame.summary_received and wave_missing == 0 and sensor_missing == 0 else "CHECK"
        print(
            f"{status}: frame={frame.frame_id} "
            f"wave={len(frame.wave_received)}/{frame.wave_total_chunks} missing={wave_missing} "
            f"sensor={len(frame.sensor_received)}/{frame.sensor_total_chunks} missing={sensor_missing} "
            f"out={out_dir}",
            flush=True,
        )

    def _log(self, message: str) -> None:
        if not self.quiet:
            print(message, flush=True)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="DS_system_02ms UDP host controller/receiver",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--board-ip", default=DEFAULT_BOARD_IP, help="board IPv4 address")
    parser.add_argument("--board-port", type=int, default=DEFAULT_BOARD_PORT, help="board command UDP port")
    parser.add_argument("--bind-ip", default=DEFAULT_BIND_IP, help="local IP to bind")
    parser.add_argument("--pc-port", type=int, default=DEFAULT_PC_PORT, help="local UDP port; board expects 50010")
    parser.add_argument("--recv-buffer", type=int, default=64 * 1024 * 1024, help="socket receive buffer bytes")
    parser.add_argument("--timeout", type=float, default=20.0, help="capture timeout seconds")
    parser.add_argument("--summary-grace", type=float, default=0.8, help="extra receive time after summary")
    parser.add_argument("--out", type=Path, default=Path("captures"), help="output root directory")
    parser.add_argument("--quiet", action="store_true", help="reduce console output")

    sub = parser.add_subparsers(dest="cmd", required=True)

    capture = sub.add_parser("capture", help="start one or more captures")
    capture.add_argument("-n", "--count", type=int, default=1, help="number of captures")
    capture.add_argument("--interval", type=float, default=0.0, help="delay between completed captures")
    capture.add_argument("--split-channels", action="store_true", help="also save A/B channel raw files")

    sub.add_parser("ping", help="send PING and wait for text response")
    sub.add_parser("status", help="send DMA_STATUS and print responses")
    sub.add_parser("cal-status", help="send CAL_STATUS and print responses")
    sub.add_parser("cal-start", help="send CAL_START and print responses")

    auto_start = sub.add_parser(
        "auto-start",
        help="start auto acquisition (requires calibration; no args = firmware presets)",
    )
    auto_start.add_argument("--rpm", type=int, default=None, help="shaft speed, e.g. 1000")
    auto_start.add_argument("--threshold", type=int, default=None,
                            help="L2 trigger threshold in um (default 32000); requires --rpm")
    auto_start.add_argument("--points", type=int, default=None,
                            help="waveform samples per channel (default 3125); requires --threshold")

    sub.add_parser("auto-stop", help="stop auto acquisition and restore manual long frame")
    sub.add_parser("auto-status", help="send AUTO_STATUS and print responses")

    auto_cfg = sub.add_parser("auto-cfg", help="update auto mode parameters (live or preset)")
    auto_cfg.add_argument("--rpm", type=int, default=None, help="shaft speed, e.g. 1000")
    auto_cfg.add_argument("--threshold", type=int, default=None,
                          help="L2 trigger threshold in um; requires --rpm")
    auto_cfg.add_argument("--points", type=int, default=None,
                          help="waveform samples per channel; requires --threshold")

    auto_recv = sub.add_parser(
        "auto-recv",
        help="passively receive auto-mode frame(s) (board triggers; no CAPTURE sent)",
    )
    auto_recv.add_argument("-n", "--count", type=int, default=1, help="number of frames")
    auto_recv.add_argument("--interval", type=float, default=0.0, help="delay between completed frames")
    auto_recv.add_argument("--split-channels", action="store_true", help="also save A/B channel raw files")

    command = sub.add_parser("command", help="send an arbitrary ASCII command")
    command.add_argument("text", help="command text, e.g. DMA_DEBUG")
    command.add_argument("--wait", type=float, default=1.0, help="seconds to receive text replies")

    listen = sub.add_parser("listen", help="listen and print incoming datagrams")
    listen.add_argument("--seconds", type=float, default=10.0, help="listen duration")

    return parser


def _auto_command(prefix: str, rpm, threshold, points) -> str:
    """Build a positional AUTO_* command string; omitted trailing fields keep
    the firmware-side presets. Middle fields cannot be skipped."""
    fields = []
    if rpm is not None:
        fields.append(str(rpm))
    if threshold is not None:
        if rpm is None:
            raise SystemExit("error: --threshold requires --rpm (positional fields)")
        fields.append(str(threshold))
    if points is not None:
        if threshold is None:
            raise SystemExit("error: --points requires --threshold (positional fields)")
        fields.append(str(points))
    return prefix if not fields else prefix + "," + ",".join(fields)


def run(args: argparse.Namespace) -> int:
    host = DSHost(
        board_ip=args.board_ip,
        board_port=args.board_port,
        bind_ip=args.bind_ip,
        pc_port=args.pc_port,
        recv_buffer=args.recv_buffer,
        timeout_s=args.timeout,
        summary_grace_s=args.summary_grace,
        quiet=args.quiet,
    )
    try:
        if args.cmd == "capture":
            root = args.out
            for idx in range(args.count):
                if args.count > 1 and not args.quiet:
                    print(f"capture {idx + 1}/{args.count}", flush=True)
                host.capture(root, split_channels=args.split_channels)
                if idx + 1 < args.count and args.interval > 0:
                    time.sleep(args.interval)
            return 0
        if args.cmd == "ping":
            host.transact_text("PING", 1.0)
            return 0
        if args.cmd == "status":
            host.transact_text("DMA_STATUS", 1.0)
            return 0
        if args.cmd == "cal-status":
            host.transact_text("CAL_STATUS", 1.0)
            return 0
        if args.cmd == "cal-start":
            host.transact_text("CAL_START", 1.0)
            return 0
        if args.cmd == "auto-start":
            host.transact_text(_auto_command("AUTO_START", args.rpm, args.threshold, args.points), 1.0)
            return 0
        if args.cmd == "auto-stop":
            host.transact_text("AUTO_STOP", 1.0)
            return 0
        if args.cmd == "auto-status":
            host.transact_text("AUTO_STATUS", 1.0)
            return 0
        if args.cmd == "auto-cfg":
            if args.rpm is None and args.threshold is None and args.points is None:
                print("auto-cfg: nothing to set (use --rpm/--threshold/--points)", file=sys.stderr)
                return 2
            host.transact_text(_auto_command("AUTO_CFG", args.rpm, args.threshold, args.points), 1.0)
            return 0
        if args.cmd == "auto-recv":
            root = args.out
            for idx in range(args.count):
                if args.count > 1 and not args.quiet:
                    print(f"frame {idx + 1}/{args.count}", flush=True)
                host.capture_passive(root, split_channels=args.split_channels)
                if idx + 1 < args.count and args.interval > 0:
                    time.sleep(args.interval)
            return 0
        if args.cmd == "command":
            host.transact_text(args.text, args.wait)
            return 0
        if args.cmd == "listen":
            host.drain(args.seconds)
            return 0
    finally:
        host.close()
    return 2


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return run(args)
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr)
        return 130
    except OSError as exc:
        print(f"socket error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
