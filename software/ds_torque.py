"""Torque reference calibration and filtering, independent of Tk and UDP."""
from __future__ import annotations

import json
import math
import statistics
import uuid
from collections import deque
from dataclasses import asdict, dataclass
from pathlib import Path

from ds_host import format_pc_timestamp

SLOPE = 0.4424
TORQUE_COLUMNS = [
    "frame_id", "pc_timestamp", "sample_monotonic_s", "me_2x_uV",
    "mean_me_2x_uV", "torque_nm", "window_frames", "window_count",
    "window_span_s", "model_id", "quality",
    "model_calibration_id", "used_for_model",
]


def validate_settings(t0: str, duration: str, window: str) -> tuple[float, float, int]:
    reference, seconds, count = float(t0), float(duration), int(window)
    if not math.isfinite(reference):
        raise ValueError("T0 必须是有限数值")
    if not math.isfinite(seconds) or not 1 <= seconds <= 3600:
        raise ValueError("标定时间必须在 1～3600 秒之间")
    if not 1 <= count <= 1000:
        raise ValueError("平均帧数必须在 1～1000 之间")
    return reference, seconds, count


def gain_key(summary: dict) -> tuple[int, int]:
    if str(summary.get("cal_valid")) != "1" or str(summary.get("cal_state")) != "5":
        raise ValueError("channel_calibration_invalid")
    gains = int(summary["gain_a_ppm"]), int(summary["gain_b_ppm"])
    if min(gains) <= 0:
        raise ValueError("invalid_gains")
    return gains


def sample_value(summary: dict) -> float:
    status = str(summary.get("status", "0"))
    if int(status, 16 if status.lower().startswith("0x") else 10) & (3 << 24):
        raise ValueError("adc_overrange")
    for key in ("adc_a_filt_pp", "adc_b_filt_pp"):
        if not 1 <= int(summary[key]) <= 65534:
            raise ValueError("adc_amplitude_invalid")
    value = float(summary["me_2x_uV"])
    if not math.isfinite(value):
        raise ValueError("invalid_me")
    return value


@dataclass(frozen=True)
class TorqueModel:
    model_id: str
    created_pc_timestamp: str
    v0_uv: float
    t0_nm: float
    gains: tuple[int, int]
    trigger: dict
    statistics: dict
    slope_nm_per_uv: float = SLOPE
    reference_source: str = "load_equipment_setpoint_not_independently_measured"

    def torque(self, value: float) -> float:
        return self.slope_nm_per_uv * (value - self.v0_uv) + self.t0_nm

    def save(self, path: Path) -> None:
        # Exclusive creation: a model/snapshot is immutable, never overwritten.
        with path.open("x", encoding="utf-8") as handle:
            json.dump(asdict(self), handle, ensure_ascii=False, indent=2, allow_nan=False)


class TorqueProcessor:
    """Single source for the displayed, plotted and recorded measurement."""

    def __init__(self, model: TorqueModel | None, window: int, trigger: dict):
        if not 1 <= window <= 1000:
            raise ValueError("invalid window")
        self.model = model
        self.window = window
        self.trigger = trigger.copy()
        self.values: deque[tuple[float, float]] = deque(maxlen=window)
        self.last_id: int | None = None
        self.last_time: float | None = None

    def reset(self) -> None:
        self.values.clear()

    def process(self, summary: dict, complete: bool, points: int | None,
                stamp: float, pc_timestamp: str) -> dict:
        row = dict.fromkeys(TORQUE_COLUMNS, "")
        row.update(frame_id=summary.get("frame_id", ""), pc_timestamp=pc_timestamp,
                   sample_monotonic_s=stamp, window_frames=self.window,
                   window_count=0, model_id=self.model.model_id if self.model else "", used_for_model=0)
        try:
            fid = int(summary["frame_id"])
            if self.last_id is not None:
                delta = (fid - self.last_id) & 0xffffffff
                if delta == 0 or delta >= 0x80000000:
                    raise ValueError("out_of_order")
                if delta != 1:
                    self.reset()
            self.last_id = fid
            if self.last_time is not None and stamp - self.last_time > 5:
                self.reset()
            self.last_time = stamp
            if not complete:
                raise ValueError("incomplete_frame")
            gains = gain_key(summary)
            value = sample_value(summary)
            row["me_2x_uV"] = value
            if points != self.trigger["points"]:
                raise ValueError("sample_count_mismatch")
            if self.model is None:
                raise ValueError("no_model")
            if gains != self.model.gains:
                self.model = None
                raise ValueError("gains_changed_model_invalidated")
            if self.trigger != self.model.trigger:
                raise ValueError("trigger_settings_mismatch")
            self.values.append((stamp, value))
            count = len(self.values)
            mean = statistics.fmean(v for _, v in self.values)
            # Include one estimated frame interval in the effective N-frame span.
            span = ((stamp - self.values[0][0]) * count / (count - 1)) if count > 1 else 0
            row.update(mean_me_2x_uV=mean, window_count=count, window_span_s=span)
            if count < self.window:
                row["quality"] = "warming_up"
            elif span > 5:
                row["quality"] = "window_exceeds_5s"
            else:
                row.update(torque_nm=self.model.torque(mean), quality="valid")
        except (KeyError, TypeError, ValueError) as exc:
            self.reset()
            row["quality"] = str(exc)
            if row["quality"] in ("channel_calibration_invalid", "invalid_gains"):
                self.model = None
        return row


class ModelCalibration:
    """Use raw valid frame means; never average overlapping filtered outputs."""

    def __init__(self, t0: float, duration: float, window: int, trigger: dict, now: float):
        validate_settings(str(t0), str(duration), str(window))
        self.t0, self.duration, self.window = t0, duration, window
        self.trigger = trigger.copy()
        self.created = now
        self.samples: list[tuple[float, float]] = []
        self.frame_ids: list[int] = []
        self.gains: tuple[int, int] | None = None
        self.last_id: int | None = None
        self.rejected = 0

    def add(self, summary: dict, complete: bool, points: int | None, stamp: float) -> None:
        if not complete:
            self.rejected += 1
            return
        gains = gain_key(summary)
        if self.gains is not None and gains != self.gains:
            raise ValueError("标定期间通道增益发生变化，请重新校准")
        if points != self.trigger["points"]:
            raise ValueError("标定期间采集点数不匹配")
        fid = int(summary["frame_id"])
        try:
            value = sample_value(summary)
        except (KeyError, TypeError, ValueError):
            self.rejected += 1
            return
        if self.last_id is not None and not 0 < ((fid - self.last_id) & 0xffffffff) < 0x80000000:
            self.rejected += 1
            return
        if self.samples and stamp - self.samples[0][0] > self.duration:
            return
        self.gains, self.last_id = gains, fid
        self.samples.append((stamp, value))
        self.frame_ids.append(fid)

    def poll(self, now: float) -> bool:
        if not self.samples:
            if now - self.created > 20:
                raise ValueError("20 秒未收到有效触发帧，请检查 L2 条件和通道校准")
            return False
        if now - self.samples[-1][0] > 5:
            raise ValueError("标定期间有效数据中断超过 5 秒，请检查触发条件")
        return now - self.samples[0][0] >= self.duration

    def finish(self) -> TorqueModel:
        if len(self.samples) < max(2, self.window):
            raise ValueError("有效帧不足一个平均窗口，请延长标定时间或调整触发参数")
        stamps, values = zip(*self.samples)
        if stamps[-1] - stamps[0] < self.duration * .8:
            raise ValueError("有效样本覆盖时间不足标定时长的 80%")
        filtered = []
        spans = []
        window: deque[float] = deque(maxlen=self.window)
        total = 0.0
        for index, v in enumerate(values):
            if index and (self.frame_ids[index] - self.frame_ids[index-1]) & 0xffffffff != 1:
                window.clear()
                total = 0.0
            if len(window) == self.window:
                total -= window[0]
            window.append(v)
            total += v
            if len(window) == self.window:
                filtered.append(total / self.window)
                spans.append((stamps[index] - stamps[index-self.window+1]) * self.window / (self.window-1)
                             if self.window > 1 else 0)
        pp = (max(filtered) - min(filtered)) * SLOPE if filtered else None
        span = (stamps[-1] - stamps[0]) / (len(values) - 1) * self.window
        half = len(values) // 2
        stats = dict(valid_frames=len(values), rejected_frames=self.rejected,
                     first_frame_id=self.frame_ids[0], last_frame_id=self.frame_ids[-1],
                     first_sample_monotonic_s=stamps[0], last_sample_monotonic_s=stamps[-1],
                     requested_duration_s=self.duration, sample_span_s=stamps[-1] - stamps[0],
                     raw_std_uv=statistics.stdev(values), raw_peak_to_peak_uv=max(values)-min(values),
                     half_drift_uv=statistics.fmean(values[half:])-statistics.fmean(values[:half]),
                     evaluation_window_frames=self.window, filtered_peak_to_peak_nm=pp,
                     filtered_frames=len(filtered), maximum_window_s=max(spans) if spans else None,
                     estimated_window_s=span,
                     stability_check_passed=bool(len(filtered) >= max(2, .8*(len(values)-self.window+1))
                                                 and pp <= 200 and span <= 5 and max(spans) <= 5),
                     note="标定区间统计，不代表后续精度或阶跃响应验收")
        return TorqueModel(uuid.uuid4().hex, format_pc_timestamp(), statistics.fmean(values),
                           self.t0, self.gains or (0, 0), self.trigger, stats)
