#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

BSP_INC=DS_system.sdk/DS_System_PS_bsp/ps7_cortexa9_0/include
APP_INC=DS_system.sdk/DS_System_PS/src
LWIP_XIL_INC=DS_system.sdk/DS_System_PS_bsp/ps7_cortexa9_0/libsrc/lwip202_v1_2/src/contrib/ports/xilinx/include
LWIP_INC=DS_system.sdk/DS_System_PS_bsp/ps7_cortexa9_0/libsrc/lwip202_v1_2/src/include
COMMON_FLAGS=(-std=gnu99 -fsyntax-only -Wall -Wextra -Wformat=2 -Wno-unused-parameter)

python3 tools/fr16_m2_static_check.py

gcc "${COMMON_FLAGS[@]}" -I "$BSP_INC" -I "$APP_INC" \
  DS_system.sdk/DS_System_PS/src/echo.c
gcc "${COMMON_FLAGS[@]}" -D__arm__ -I "$BSP_INC" -I "$APP_INC" \
  DS_system.sdk/DS_System_PS/src/main.c
gcc "${COMMON_FLAGS[@]}" -D__arm__ -I "$BSP_INC" -I "$APP_INC" \
  DS_system.sdk/DS_System_PS/src/platform_zynq.c
gcc "${COMMON_FLAGS[@]}" -D__arm__ -I "$BSP_INC" -I "$LWIP_XIL_INC" -I "$LWIP_INC" \
  DS_system.sdk/DS_System_PS_bsp/ps7_cortexa9_0/libsrc/lwip202_v1_2/src/contrib/ports/xilinx/netif/xadapter.c

printf 'PASS: echo.c, main.c, platform_zynq.c and patched xadapter.c syntax checks\n'
