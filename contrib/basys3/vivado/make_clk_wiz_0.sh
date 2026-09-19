#!/bin/bash
# Generate the clk_wiz_0 MMCM IP (100 MHz -> 24.576 MHz) for the Basys3
# port and place its Verilog wrappers where dkongjr_basys3.xpr expects them.
#
# Single MMCM output:
#   clk_out1 = 24.576 MHz (requested) -- I_CLK_24576M into dkongjr_top
#
# 100 / 24.576 is not an exact ratio (~4.069); the actual generated
# frequency is recorded from the wrapper output below, not assumed -- see
# PORTING_SPEC.md section 6.
#
# The core's internal 12.288 MHz / 6.144 MHz nodes are derived *inside*
# dkongjr_top.v and are not exposed at its port boundary; the PS/2
# keyboard clock is instead an independent fabric divider authored in the
# wrapper (make_dkongjr_basys3_top.sh), not this script.
#
# Per project rules this script runs from /tmp so vivado.log / vivado.jou
# stay outside the repo.

set -euo pipefail

VIVADO="${VIVADO:-/tools/Xilinx/Vivado/2020.2/bin/vivado}"
PART=xc7a35tcpg236-1

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
XPR_DIR="$ROOT/basys3"
CLK_WIZ_IMPORT_DIR="$XPR_DIR/dkongjr_basys3.srcs/sources_1/imports/clk_wiz_0"

WORK=/tmp/mmcm_dkongjr
TCL="$WORK/gen_clk_wiz_0.tcl"

rm -rf "$WORK"
mkdir -p "$WORK"

cat > "$TCL" <<EOF
create_project mmcm_dkongjr "$WORK" -part $PART -force

create_ip -name clk_wiz -vendor xilinx.com -library ip -version 6.0 \
    -module_name clk_wiz_0 -dir "$WORK"

set_property -dict [list \
    CONFIG.PRIMITIVE {MMCM} \
    CONFIG.PRIM_SOURCE {Single_ended_clock_capable_pin} \
    CONFIG.CLKIN1_JITTER_PS {50.0} \
    CONFIG.CLKOUT1_USED {true} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {24.576} \
    CONFIG.USE_PHASE_ALIGNMENT {true} \
] [get_ips clk_wiz_0]

generate_target all [get_ips clk_wiz_0]
EOF

"$VIVADO" -mode batch -nolog -nojournal -source "$TCL"

GEN_DIR="$WORK/clk_wiz_0"
mkdir -p "$CLK_WIZ_IMPORT_DIR"
cp "$GEN_DIR/clk_wiz_0.v"            "$CLK_WIZ_IMPORT_DIR/"
cp "$GEN_DIR/clk_wiz_0_clk_wiz.v"    "$CLK_WIZ_IMPORT_DIR/"

# Report the actual achieved clk_out1 frequency (100/24.576 is not an exact
# ratio -- see PORTING_SPEC.md section 6) from the generated .xci rather
# than assuming the request was met exactly. Note: the IP's internal MMCM
# primitive numbering is 0-based (C_CLKOUT0_*), one behind the user-facing
# clk_out1 port -- C_CLKOUT1_ACTUAL_FREQ is a different, unused output.
ACTUAL=$(grep -m1 'C_CLKOUT0_ACTUAL_FREQ' "$GEN_DIR/clk_wiz_0.xci" | sed -E 's/.*>([0-9.]+)<.*/\1/')
echo "clk_wiz_0 clk_out1 requested 24.576 MHz, actual: ${ACTUAL:-unknown} MHz"

rm -rf "$WORK"

echo "Generated clk_wiz_0 IP files:"
ls -l "$CLK_WIZ_IMPORT_DIR"