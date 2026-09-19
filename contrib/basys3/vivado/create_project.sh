#!/bin/bash
# Create the Vivado Basys3 project for Donkey Kong Junior.
#
# This script creates the project and imports all RTL sources into the
# Vivado project database. Per project rules it runs from /tmp so
# vivado.log / vivado.jou stay outside the repo.
#
# Import strategy (pristine src/ is never modified):
#   * All *.vhd / *.v / *.sv under src/ EXCEPT:
#       - fz80_ip/*        (dead-code alternate Z80 CPU IP, never built
#                            upstream -- see PORTING_SPEC.md section 5)
#       - z80ip_f.v        (wraps fz80_ip; same reason)
#       - dkongjr_rom.v    (replaced by proms/dkongjr_roms.v)
#       - t80asd_ip/T80_RegX.vhd (declares a duplicate `entity T80_Reg`,
#                            collides with T80_Reg.vhd)
#   * contrib/basys3/rtl/ -- portable dual-port RAM (dpram.vhd, replaces
#     the pristine Altera-only dpram.vhd -- never imported), plus the
#     vendored PS/2 keyboard chain (io_ps2_keyboard.vhd,
#     kbd_joystick.vhd) and the MiST-style scandoubler (scandoubler_new.v)
#   * proms/dkongjr_roms.v -- the single drop-in dkongjr_rom module
#     (authored by the Python make_dkongjr_roms.py generator at
#     `make setup` time).
#   * The dkongjr_basys3.vhd wrapper (authored by make_dkongjr_basys3_top.sh)
#     replaces the pristine top -- not imported by this script, added later
#     by `make patch`.
#
# Prerequisites: `make setup` must have run first (generates dkongjr_roms.v).

set -euo pipefail

VIVADO="${VIVADO:-/tools/Xilinx/Vivado/2020.2/bin/vivado}"
PART=xc7a35tcpg236-1

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SRC="$ROOT/src"
RTL="$ROOT/contrib/basys3/rtl"
PROMS="$ROOT/proms"
CONTRIB="$ROOT/contrib/basys3"
XPR_DIR="$ROOT/basys3"

WORK=/tmp/dkongjr_create_proj
TCL="$WORK/create_project.tcl"

step() { printf '\n==> %s\n' "$1"; }

if [ ! -f "$PROMS/dkongjr_roms.v" ]; then
    echo "error: dkongjr_roms.v not found in $PROMS" >&2
    echo "Run 'make setup' first." >&2
    exit 1
fi

rm -rf "$WORK" "$XPR_DIR"
mkdir -p "$WORK"

step "1/3 Generating Vivado project TCL script"

cat > "$TCL" <<EOF
create_project dkongjr_basys3 "$XPR_DIR" -part $PART -force
set_property target_language VHDL [current_project]
set_property board_part digilentinc.com:basys3:part0:1.2 [current_project]

# --- Constraints ---
add_files -fileset constrs_1 -norecurse "$CONTRIB/vivado/Basys-3-Master.xdc"
EOF

# Add all VHDL/Verilog/SystemVerilog files from src/ EXCEPT the dead-code
# CPU alternative and the pristine ROM module (replaced by
# proms/dkongjr_roms.v). SystemVerilog (dkongjr_dac.sv) is required --
# omitting it fails elaboration with "module 'dkongjr_dac' not found".
(
    cd "$SRC"
    find . \( -name '*.vhd' -o -name '*.v' -o -name '*.sv' \) -type f \
        ! -path './fz80_ip/*' \
        ! -name 'z80ip_f.v' \
        ! -name 'dkongjr_rom.v' \
        ! -name 'T80_RegX.vhd' \
        | sort | while read -r f; do
            echo "add_files -fileset sources_1 -norecurse \"$SRC/$f\"" >> "$TCL"
        done
)

# Add the wrapper-owned RTL utilities (portable dual-port RAM, PS/2
# keyboard chain, scandoubler -- see header comment above). Note the
# pristine dpram.vhd is NOT here; the portable contrib one is.
find "$RTL" \( -name '*.vhd' -o -name '*.v' \) -type f | sort | while read -r f; do
    echo "add_files -fileset sources_1 -norecurse \"$f\"" >> "$TCL"
done

# Add the generated ROM Verilog
find "$PROMS" -name '*.v' -type f | sort | while read -r f; do
    echo "add_files -fileset sources_1 -norecurse \"$f\"" >> "$TCL"
done

# --- Set top entity (placeholder until `make patch` authors the wrapper) ---
cat >> "$TCL" <<EOF
set_property top dkongjr_basys3 [current_fileset]
EOF

step "2/3 Running Vivado to create project"
(cd "$WORK" && "$VIVADO" -mode batch -nolog -nojournal -source "$TCL")

rm -rf "$WORK"

echo
echo "Project created:"
ls -l "$XPR_DIR/dkongjr_basys3.xpr"