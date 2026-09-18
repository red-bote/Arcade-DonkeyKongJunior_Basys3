#!/bin/bash
# Linux setup for the Donkey Kong Junior Basys3 port.
#
# 1. Applies the synthesis-fix patches idempotently (patch -p1 --forward) to
#    the pristine src/ sources.
# 2. Stages the romset and generates the single proms/dkongjr_roms.v (the
#    drop-in dkongjr_rom replacement). Nothing is compiled on the host --
#    generation is pure Python, no gcc needed.
#
# Patches under contrib/code/ (Vivado 2020.2 Verilog parser fixes -- Synth
# 8-1873 "declarations not allowed in unnamed block"; the pristine sources
# declare a local reg as the first statement in an unnamed always-block
# begin/end, valid Verilog but rejected by Vivado's synthesizer):
#   - dkongjr_dma_synth_fix.patch   moves `reg old_trig;` to module scope.
#   - dkongjr_vram_synth_fix.patch  moves `reg prev;` to module scope.
#
# Our fork carries the pristine core directly in src/ (the sibling
# DonkeyKongJr_DeMiSTified vendored it under a differently-named
# subdirectory); the patches here target src/ accordingly.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

step() { printf '\n==> %s\n' "$1"; }

step "1/2 Applying fix patches (contrib/code/*.patch)"
for p in "$ROOT"/contrib/code/*.patch; do
    [ -e "$p" ] || continue
    if (cd "$ROOT" && patch -p1 --forward --dry-run < "$p" > /dev/null 2>&1); then
        echo "==> applying $p"
        (cd "$ROOT" && patch -p1 --forward < "$p")
    elif (cd "$ROOT" && patch -p1 -R --dry-run --forward < "$p" > /dev/null 2>&1); then
        echo "==> $p already applied, skipping"
    else
        echo "ERROR: could not apply $p (context mismatch)" >&2
        exit 1
    fi
done

mkdir -p "$ROOT/proms"

step "2/2 Running rom-prep"
exec "$ROOT/contrib/tools/prep_roms.sh"