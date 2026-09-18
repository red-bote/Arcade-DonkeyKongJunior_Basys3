#!/bin/bash
# Linux rom-prep for the Donkey Kong Junior Basys3 port.
#
# 1. Unzip the romset ($ROMZIP, default ~/roms/dkongjr.zip) into roms/.
# 2. Run make_dkongjr_roms.py to generate proms/dkongjr_roms.v (the single
#    drop-in dkongjr_rom module: flat 64 KiB program/gfx ROM plus the
#    96 KiB wave-sample ROM from the vendored releases/dkj_wave.bin,
#    MD5-gated against releases/build_rom.ini's recorded A.DKONGJR.ROM
#    image -- see PORTING_SPEC.md).
#
# The dkj.*/v_7*/c_3h/*.bpr MAME romset contents stay local (never
# distributed). dkj_wave.bin is open-source sample data vendored with the
# core, not MAME ROM content -- see PORTING_SPEC.md.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TOOLS_DIR="$ROOT/contrib/tools"
ROMS_DIR="$ROOT/roms"
PROMS_DIR="$ROOT/proms"
WAVE_BIN="$ROOT/releases/dkj_wave.bin"

ROMZIP="${ROMZIP:-$HOME/roms/dkongjr.zip}"

# Expected ROMZIP contents (the dkongjr romset in the same *renamed*
# member layout the sibling DonkeyKongJr_DeMiSTified port uses -- these
# are the MiSTer-era names, not the MAME djr1-* originals; the pristine
# releases/build_rom.bat expects the originals, see build_rom.ini). All
# files are consumed by make_dkongjr_roms.py; sizes/MD5 are checked there.
ROM_FILES=(dkj.5b dkj.5c dkj.5e dkj.3p dkj.3n \
           v_7c.bin v_7d.bin v_7e.bin v_7f.bin \
           c_3h.bin c-2e.bpr c-2f.bpr v-2n.bpr)

step() { printf '\n==> %s\n' "$1"; }

if [ ! -f "$ROMZIP" ]; then
    echo "error: ROMZIP not found: $ROMZIP" >&2
    exit 1
fi

if [ ! -f "$WAVE_BIN" ]; then
    echo "error: wave-sample data not found: $WAVE_BIN" >&2
    exit 1
fi

mkdir -p "$ROMS_DIR" "$PROMS_DIR"

step "1/2 Unzipping romset"
unzip -o "$ROMZIP" -d "$ROMS_DIR" > /dev/null

missing=()
for f in "${ROM_FILES[@]}"; do
    [ -f "$ROMS_DIR/$f" ] || missing+=("$f")
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "error: ROMZIP ($ROMZIP) is missing files this port expects:" >&2
    printf '  %s\n' "${missing[@]}" >&2
    exit 1
fi

step "2/2 Generating proms/dkongjr_roms.v"
python3 "$TOOLS_DIR/make_dkongjr_roms.py" "$ROMS_DIR" "$PROMS_DIR" "$WAVE_BIN"

echo
echo "Rom-prep complete. Generated:"
ls -l "$PROMS_DIR/dkongjr_roms.v"