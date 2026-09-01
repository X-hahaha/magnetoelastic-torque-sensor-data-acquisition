#!/usr/bin/env python3
"""Reapply the nonblocking lwIP link-recovery patch after SDK BSP regeneration.

Run from the DS_system project root:
    python tools/reapply_m2_link_fix.py

The SDK 2018.3 "Regenerate BSP Sources" action may restore Xilinx's original
xadapter.c. That original recovery path calls phy_setup_emacps() from periodic
link management and can block for seconds while FR16 DMA descriptors are not
recycled. This script is idempotent.
"""
from __future__ import annotations

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
XADAPTER = ROOT / (
    "DS_system.sdk/DS_System_PS_bsp/ps7_cortexa9_0/"
    "libsrc/lwip202_v1_2/src/contrib/ports/xilinx/netif/xadapter.c"
)

ORIGINAL = '''\t\tcase ETH_LINK_NEGOTIATING:\n\t\t\tif (phy_link_status &&\n\t\t\t\tphy_autoneg_status(xemacp, phyaddrforemac)) {\n\n\t\t\t\t/* Initiate Phy setup to get link speed */\n#if defined(XLWIP_CONFIG_INCLUDE_GEM)\n\t\t\t\tlink_speed = phy_setup_emacps(xemacp,\n\t\t\t\t\t\t\t\tphyaddrforemac);\n\t\t\t\tXEmacPs_SetOperatingSpeed(xemacp, link_speed);\n#elif defined(XLWIP_CONFIG_INCLUDE_AXI_ETHERNET)\n\t\t\t\tlink_speed = phy_setup_axiemac(xemacp);\n\t\t\t\tXAxiEthernet_SetOperatingSpeed(xemacp,\n\t\t\t\t\t\t\t       link_speed);\n#endif\n\t\t\t\tnetif_set_link_up(netif);\n\t\t\t\teth_link_status = ETH_LINK_UP;\n\t\t\t\txil_printf("Ethernet Link up\\r\\n");\n\t\t\t}\n\t\t\tbreak;\n'''

PATCHED = '''\t\tcase ETH_LINK_NEGOTIATING:\n\t\t\tif (phy_link_status &&\n\t\t\t\tphy_autoneg_status(xemacp, phyaddrforemac)) {\n\n\t\t\t\t/* Nonblocking recovery for the bare-metal FR16 application.\n\t\t\t\t * The initial low_level_init() has already negotiated and set\n\t\t\t\t * the MAC speed. Calling phy_setup_*() here restarts autoneg and\n\t\t\t\t * can sleep for seconds, starving DMA BD recycling. A cable\n\t\t\t\t * reconnect to the same 1-Gbit peer retains that configured MAC\n\t\t\t\t * speed and only needs the lwIP link flag restored.\n\t\t\t\t */\n#if defined(XLWIP_CONFIG_INCLUDE_GEM)\n\t\t\t\tlink_speed = XEmacPs_GetOperatingSpeed(xemacp);\n#elif defined(XLWIP_CONFIG_INCLUDE_AXI_ETHERNET)\n\t\t\t\tlink_speed = 0;\n#endif\n\t\t\t\tnetif_set_link_up(netif);\n\t\t\t\teth_link_status = ETH_LINK_UP;\n\t\t\t\txil_printf("Ethernet Link up (nonblocking, MAC speed %lu)\\r\\n",\n\t\t\t\t\t\t(unsigned long)link_speed);\n\t\t\t}\n\t\t\tbreak;\n'''


def main() -> int:
    if not XADAPTER.exists():
        print(f"ERROR: missing {XADAPTER}", file=sys.stderr)
        return 2

    text = XADAPTER.read_text(encoding="utf-8")
    changed = False

    if "Ethernet Link up (nonblocking, MAC speed %lu)" in text:
        print("xadapter.c: nonblocking link patch already present")
    elif ORIGINAL in text:
        text = text.replace(ORIGINAL, PATCHED, 1)
        changed = True
    else:
        print("ERROR: xadapter.c does not match the expected SDK 2018.3 source", file=sys.stderr)
        return 3

    if "u32_t link_speed, phy_link_status;" in text:
        text = text.replace(
            "u32_t link_speed, phy_link_status;",
            "u32_t link_speed = 0, phy_link_status;",
            1,
        )
        changed = True

    if changed:
        XADAPTER.write_text(text, encoding="utf-8")
        print(f"patched: {XADAPTER.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
