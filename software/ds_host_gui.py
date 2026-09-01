#!/usr/bin/env python3
"""
Tkinter GUI for the DS_system_02ms UDP host.

The GUI keeps the same transaction rule as ds_host.py: one CAPTURE command is
allowed at a time, and the next capture is disabled until the current frame has
been received and written to disk.
"""

from __future__ import annotations

import os
import queue
import socket
import struct
import threading
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

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
    WV32_MAGIC,
    now_stamp,
    parse_text_datagram,
)


SOFTWARE_DIR = Path(__file__).resolve().parent
DEFAULT_OUTPUT_ROOT = SOFTWARE_DIR / "captures"
DEFAULT_RECV_BUFFER = 64 * 1024 * 1024
DEFAULT_TIMEOUT_S = 25.0
DEFAULT_SUMMARY_GRACE_S = 0.8

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

    def run_command(self, command: str, wait_s: float = 1.0) -> None:
        sock: Optional[socket.socket] = None
        try:
            sock = self.open_socket()
            self.send_command(sock, command)
            lines = self.drain_text(sock, wait_s)
            self.emit("command_done", command=command, lines=lines)
        except Exception as exc:
            self.emit("error", title="命令失败", message=str(exc))
        finally:
            if sock is not None:
                sock.close()

    def run_capture(self) -> None:
        sock: Optional[socket.socket] = None
        frame: Optional[CaptureFrame] = None
        try:
            capture_dir = self.output_root / f"capture_{now_stamp()}"
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

        self.info_vars: Dict[str, tk.StringVar] = {
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
        panel = ttk.LabelFrame(parent, text="采集信息", padding=10)
        panel.grid(row=0, column=0, sticky="ew", pady=(0, 8))
        panel.columnconfigure(1, weight=1)

        rows = [
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

    def _build_latest_panel(self, parent: ttk.Frame) -> None:
        panel = ttk.LabelFrame(parent, text="本帧摘要", padding=10)
        panel.grid(row=2, column=0, sticky="ew")
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

    def _start_command(self, command: str, wait_s: float) -> None:
        worker = self._make_worker()
        if worker is None:
            return
        self._start_thread(lambda: worker.run_command(command, wait_s), f"执行 {command}")

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
        self._reset_capture_views()
        self._start_thread(worker.run_capture, "采集中")

    def _reset_capture_views(self) -> None:
        self.current_frame = None
        self.wave_points = []
        self.wave_min = 0
        self.wave_max = 65535
        self.wave_progress_var.set(0)
        self.sensor_progress_var.set(0)
        for var in self.info_vars.values():
            var.set("-")
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
        elif kind == "error":
            self._append_log(f"#HOST,error,{event.get('message', '')}")
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

    def _refresh_wave_preview(self) -> None:
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
        canvas.create_text(
            right,
            height - 16,
            anchor=tk.E,
            text=f"{ADC_SAMPLE_COUNT:,} samples/channel, int16",
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
