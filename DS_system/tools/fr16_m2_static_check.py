#!/usr/bin/env python3
"""Static and behavioral reference checks for the M2 refactor.

This script does not replace Vivado synthesis or board validation. It checks the
committed source geometry, key configuration invariants, a reference FR16 record,
and basic Verilog token balance.
"""
from __future__ import annotations

import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FRAME_BYTES = 8192
HEADER_BYTES = 256
SAMPLE_COUNT = 1562
WAVE_BYTES = SAMPLE_COUNT * 4
SUMMARY_BYTES = 128
SUMMARY_OFFSET = HEADER_BYTES + WAVE_BYTES
FOOTER_BYTES = 40
FOOTER_OFFSET = FRAME_BYTES - FOOTER_BYTES
PAYLOAD_BYTES = HEADER_BYTES + WAVE_BYTES + SUMMARY_BYTES + FOOTER_BYTES
FRAME_WORDS = FRAME_BYTES // 4


def require(cond: bool, message: str) -> None:
    if not cond:
        raise AssertionError(message)


def s16(v: int) -> int:
    return ((v + 0x8000) & 0xFFFF) - 0x8000


def pp(values: list[int]) -> int:
    return max(values) - min(values)


def build_reference_record() -> tuple[bytearray, int, int]:
    a = [s16(((i * 97) % 65536) - 32768) for i in range(SAMPLE_COUNT)]
    b = [s16(((i * 193 + 1234) % 65536) - 32768) for i in range(SAMPLE_COUNT)]
    a_pp = pp(a)
    b_pp = pp(b)

    rec = bytearray(FRAME_BYTES)
    header = [0] * (HEADER_BYTES // 4)
    header[0] = 0x36315246
    header[1] = (HEADER_BYTES << 16) | 1
    header[2] = FRAME_BYTES
    header[3] = FRAME_BYTES
    header[4] = 42
    header[5] = 200
    header[6] = SAMPLE_COUNT
    header[7] = 15_625_000
    header[8] = 0x2
    header[10] = HEADER_BYTES
    header[11] = WAVE_BYTES
    header[12] = SUMMARY_OFFSET
    header[13] = SUMMARY_BYTES
    header[14] = FOOTER_OFFSET
    header[15] = FOOTER_BYTES
    header[16] = PAYLOAD_BYTES
    struct.pack_into(f"<{len(header)}I", rec, 0, *header)

    for i, (av, bv) in enumerate(zip(a, b)):
        pair = (bv & 0xFFFF) << 16 | (av & 0xFFFF)
        struct.pack_into("<I", rec, HEADER_BYTES + i * 4, pair)

    summary = [0] * (SUMMARY_BYTES // 4)
    summary[0] = a_pp
    summary[1] = b_pp
    struct.pack_into(f"<{len(summary)}I", rec, SUMMARY_OFFSET, *summary)

    footer = [0x454E4F44, 42, FRAME_WORDS, FRAME_BYTES, PAYLOAD_BYTES,
              SAMPLE_COUNT, 0, 0, 0x2, 0]
    struct.pack_into("<10I", rec, FOOTER_OFFSET, *footer)
    return rec, a_pp, b_pp


def validate_reference_record(rec: bytearray, expected_a: int, expected_b: int) -> None:
    words = struct.unpack_from(f"<{FRAME_WORDS}I", rec, 0)
    require(words[0] == 0x36315246, "header magic")
    require(words[1] == 0x01000001, "header version/size")
    require(words[10] == HEADER_BYTES, "wave offset")
    require(words[11] == WAVE_BYTES, "wave bytes")
    require(words[12] == SUMMARY_OFFSET, "summary offset")
    require(words[14] == FOOTER_OFFSET, "footer offset")

    a: list[int] = []
    b: list[int] = []
    for i in range(SAMPLE_COUNT):
        pair = words[(HEADER_BYTES // 4) + i]
        a.append(s16(pair & 0xFFFF))
        b.append(s16(pair >> 16))
    require(pp(a) == expected_a, "A waveform pp")
    require(pp(b) == expected_b, "B waveform pp")
    require(words[SUMMARY_OFFSET // 4] == expected_a, "A summary pp")
    require(words[SUMMARY_OFFSET // 4 + 1] == expected_b, "B summary pp")
    require(words[FOOTER_OFFSET // 4] == 0x454E4F44, "footer magic")
    require(words[FOOTER_OFFSET // 4 + 2] == FRAME_WORDS, "footer words")


def strip_verilog(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"//.*", "", text)
    text = re.sub(r'"(?:\\.|[^"\\])*"', '""', text)
    return text


def check_verilog_balance(path: Path) -> None:
    text = strip_verilog(path.read_text(encoding="utf-8"))
    for left, right in [("(", ")"), ("[", "]"), ("{", "}")]:
        require(text.count(left) == text.count(right), f"{path.name}: {left}{right} balance")
    tokens = re.findall(r"\b(?:module|endmodule|begin|end|case|casez|casex|endcase|function|endfunction)\b", text)
    require(tokens.count("module") == tokens.count("endmodule"), f"{path.name}: module balance")
    require(tokens.count("begin") == tokens.count("end"), f"{path.name}: begin/end balance")
    require(tokens.count("case") + tokens.count("casez") + tokens.count("casex") == tokens.count("endcase"),
            f"{path.name}: case balance")
    require(tokens.count("function") == tokens.count("endfunction"), f"{path.name}: function balance")


def check_sources() -> None:
    hdl = ROOT / "DS_system.srcs/sources_1/imports/fr16_m2/fr16_adc_frame_axis.v"
    top = ROOT / "DS_system.srcs/sources_1/imports/pl_reset_update/pl_capture_logic.v"
    daq = ROOT / "DS_system.srcs/sources_1/imports/adc_pp_modified/daq_capture_core.v"
    echo = ROOT / "DS_system.sdk/DS_System_PS/src/echo.c"
    main_c = ROOT / "DS_system.sdk/DS_System_PS/src/main.c"
    platform_zynq = ROOT / "DS_system.sdk/DS_System_PS/src/platform_zynq.c"
    xadapter = ROOT / "DS_system.sdk/DS_System_PS_bsp/ps7_cortexa9_0/libsrc/lwip202_v1_2/src/contrib/ports/xilinx/netif/xadapter.c"
    bd = ROOT / "DS_system.srcs/sources_1/bd/ps_system/ps_system.bd"
    xpr = ROOT / "DS_system.xpr"

    for path in [hdl, top, daq, echo, main_c, platform_zynq, xadapter, bd, xpr]:
        require(path.exists(), f"missing {path.relative_to(ROOT)}")

    hdl_text = hdl.read_text(encoding="utf-8")
    top_text = top.read_text(encoding="utf-8")
    daq_text = daq.read_text(encoding="utf-8")
    echo_text = echo.read_text(encoding="utf-8")
    main_text = main_c.read_text(encoding="utf-8")
    platform_text = platform_zynq.read_text(encoding="utf-8")
    xadapter_text = xadapter.read_text(encoding="utf-8")
    bd_text = bd.read_text(encoding="utf-8", errors="ignore")
    xpr_text = xpr.read_text(encoding="utf-8", errors="ignore")

    for token in ["parameter integer FRAME_STRIDE_BYTES = 8192",
                  "parameter integer SAMPLE_COUNT       = 1562",
                  "REAL_ADC_FLAG_U32", "ST_WAVE_REQ", "ST_WAVE_SEND", "ST_FOOTER"]:
        require(token in hdl_text, f"M2 HDL invariant: {token}")
    require("fr16_adc_frame_axis" in top_text, "top instantiates M2 packer")
    require("rd_bank_sys" in daq_text and "rd_data_pair_raw" in daq_text,
            "DAQ exposes fixed-bank raw pair read")
    for token in ["FR16_REAL_ADC_FLAG", "FR16_CHECK", "FR16_DUMP",
                  "fr16_compute_wave_pp", "FR16 M2"]:
        require(token in echo_text, f"PS M2 invariant: {token}")
    for forbidden in ["M1_SINGLE_GO", "DMA_SINGLE_PEEK", 'strcmp(cmd, "M1_GO")']:
        require(forbidden not in echo_text, f"mode-changing command removed: {forbidden}")
    for token in ["application_pre_network_init", "M2_LINK_STABLE_MS       2000U",
                  "m2_startup_capture_poll", "capture remains held for stable Ethernet link"]:
        require(token in echo_text, f"startup/link invariant: {token}")
    require("application_pre_network_init();" in main_text,
            "main asserts PL reset before network initialization")
    require("EthLinkTmrFlag" in main_text and "transfer_data();" in main_text,
            "main services deferred link check and DMA polling")
    require("EthLinkTmrFlag = 1" in platform_text,
            "timer ISR defers link management")
    require("eth_link_detect(echo_netif);" not in platform_text,
            "timer ISR does not call link recovery directly")
    recovery = xadapter_text[xadapter_text.find("case ETH_LINK_NEGOTIATING"):]
    require("XEmacPs_GetOperatingSpeed" in recovery,
            "runtime reconnect retains configured MAC speed")
    require("phy_setup_emacps(xemacp" not in recovery,
            "runtime reconnect does not restart blocking autonegotiation")
    require("c_sg_include_stscntrl_strm" in bd_text,
            "BD contains SG status/control property")
    # Vivado 2018.3 .bd files are JSON in this project; also accept XML-style
    # property serialization for portability.
    sg_disabled = (
        re.search(r'"c_sg_include_stscntrl_strm"\s*:\s*\{\s*"value"\s*:\s*"0"', bd_text, re.S)
        or re.search(r"c_sg_include_stscntrl_strm.{0,200}Val=\"0\"", bd_text, re.S)
    )
    require(sg_disabled is not None, "SG status/control stream remains disabled")
    stsapp_disabled = re.search(
        r'"c_sg_use_stsapp_length"\s*:\s*\{\s*"value"\s*:\s*"0"',
        bd_text, re.S)
    require(stsapp_disabled is not None, "SG status app length remains disabled")
    require("fr16_m2/fr16_adc_frame_axis.v" in xpr_text, "XPR includes M2 source")

    for path in [hdl, top, daq]:
        check_verilog_balance(path)


def main() -> int:
    require(SUMMARY_OFFSET == 6504, "summary offset must be 6504")
    require(FOOTER_OFFSET == 8152, "footer offset must be 8152")
    require(PAYLOAD_BYTES == 6672, "payload bytes must be 6672")
    rec, a_pp, b_pp = build_reference_record()
    validate_reference_record(rec, a_pp, b_pp)
    check_sources()

    # Packer latency when TREADY remains asserted: 64 header cycles, 2 cycles per
    # BRAM sample, 32 summary, 380 padding, 10 footer = 3610 cycles at 50 MHz.
    cycles = 64 + 2 * SAMPLE_COUNT + 32 + 380 + 10
    pack_us = cycles / 50.0
    start_margin_us = 100.0 - pack_us
    completion_slack_us = 200.0 - pack_us
    require(start_margin_us > 0.0, "packer must finish before the next 200 us trigger")

    print("PASS: M2 source invariants and reference FR16 record")
    print(f"geometry: wave={WAVE_BYTES} summary_offset={SUMMARY_OFFSET} footer_offset={FOOTER_OFFSET}")
    print(f"reference_pp: A={a_pp} B={b_pp}")
    print(f"no-backpressure packer: {cycles} cycles = {pack_us:.2f} us, next-trigger margin={start_margin_us:.2f} us, completion slack={completion_slack_us:.2f} us")
    print("NOTE: Vivado synthesis/implementation and hardware soak test are still required.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
