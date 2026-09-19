# Donkey Kong Junior (MiSTer-devel)

Donkey Kong Junior arcade core ported to MiSTer by gaz68
(https://github.com/gaz68), CPU/video RTL originally by Katsumi Degawa.

## Basys3 port

Basys3 (Artix-7 `xc7a35tcpg236-1`) port of `dkongjr_top` (the core proper,
already free of the MiSTer HPS/OSD/HDMI framework). The pristine `src/` is
untouched here (aside from two tracked synthesis-fix patches, below); the
Vivado project imports `src/` minus a dead-code alternate CPU IP
(`fz80_ip/`, `z80ip_f.v`, never built upstream), a duplicate-entity file
(`t80asd_ip/T80_RegX.vhd`), and the pristine `dkongjr_rom.v` (replaced by a
generated drop-in module). ROMs are generated at `make setup` time into a
single `proms/dkongjr_roms.v` (one module, byte-identical port list to the
pristine `dkongjr_rom.v`: a flat 64 KiB program/graphics/sound-table ROM
plus a 96 KiB wave-sample ROM) by the host-side Python generator
`contrib/tools/make_dkongjr_roms.py` (no gcc needed). The pristine
`dpram.vhd` (Altera `altsyncram`) is replaced by a portable dual-port RAM,
`contrib/basys3/rtl/dpram.vhd`. The wrapper `dkongjr_basys3` (authored by
`make patch`) adds MMCM clocking, an independent PS/2 keyboard clock, an
8-stage H-blank delay match, the vendored MiST-style scandoubler, PMODA
joystick + keyboard input, and a PWM audio path. See `PORTING_SPEC.md` for
full design intent, including the unresolved empirical-verification items
(video blanking depth, DIP mapping, RAM timing, audio scaling, wave-sample
audio). The sibling `gaz88/DonkeyKongJr_DeMiSTified` is a hardware-verified
port of the same core; where this port reuses an interface decision from
it, the choice is re-derived against the pristine RTL in this tree (see
`PORTING_SPEC.md` section 10).

**Audio scope**: both sound sources are included -- the primary
chip-driven sound (i8035/T48 sound CPU) and the four PCM sample channels
(walk/climb/jump/land/fall, from the vendored `releases/dkj_wave.bin`,
open-source data, not MAME ROM content). Sample mix volume is
switch-selectable (`sw[11:8]`). See `PORTING_SPEC.md` section 4.

**Synthesis fixes** (`contrib/code/*.patch`, applied idempotently by
`setup_dkongjr.sh`): two Vivado 2020.2 Verilog-parser rejections (Synth
8-1873, local `reg` declared in an unnamed `begin`/`end` block) in
`dkongjr_dma.v` and `dkongjr_vram.v`. See `PORTING_SPEC.md` section 11.
Verify: `grep -c "reg old_trig;$" src/dkongjr_dma.v` and
`grep -c "reg    prev;$" src/dkongjr_vram.v` should each report `1`
(module-scope, not inside the `always` block).

`create_project.sh` imports `.sv` alongside `.vhd`/`.v` -- `dkongjr_dac.sv`
is the one SystemVerilog file in the vendored tree and is silently dropped
by a `.vhd`/`.v`-only glob. Verify:
`find src -name '*.sv'` should list `dkongjr_dac.sv`, and after
`make create_prj` the project should contain it (Vivado Tcl:
`llength [get_files -quiet *dkongjr_dac.sv]` should report `1`).

Build from this directory (see `make help`):

    make setup        # stage romset + generate proms/dkongjr_roms.v
    make create_prj    # create Vivado project (imports src/ minus dead-code CPU alt + proms)
    make clk_wiz       # generate clk_wiz_0 MMCM IP (100 -> 24.576 MHz)
    make patch         # author dkongjr_basys3.vhd top level
    make bitstream     # implementation + write_bitstream (runs synth first)

`ROMZIP` defaults to `~/roms/dkongjr.zip` (dkongjr romset). Roms and the
generated ROM Verilog stay local (never committed);
`releases/dkj_wave.bin` (open-source wave-sample data) is tracked normally,
it is not MAME ROM content.

## IO mapping

| Function | Basys 3 resource | Notes |
|---|---|---|
| reset | `btnC` | active-high |
| coin-in | `btnU` | single coin input on this core |
| 1P start | `btnL` | |
| 2P start | `btnR` | |
| joystick up/down/left/right/fire | PMODA `JA[3]/JA[2]/JA[1]/JA[0]/JA[4]` | active-low; OR-merged with the keyboard |
| PS/2 keyboard | onboard USB HID (`ps2_dat`/`ps2_clk`, B17/C17) | arrows + Ctrl/Space (fire), 1/2 (start), 5 (coin) |
| DIP switches | `sw[7:0]` | cabinet (`sw7`), bonus (`sw3:2`), lives (`sw1:0`) -- see PORTING_SPEC.md section 8 |
| wave-sample volume | `sw[11:8]` | non-linear encoding: `4`=OFF, `5`-`10`=10%-60%, `0`=70%, `1`=80%, `2`=90%, `3`=100% -- see PORTING_SPEC.md section 4 |
| audio PWM | `O_PMODAMP2_AIN/GAIN/SHUTD` (JC) | `sw14` = shutdown, `sw15` = gain |
| VGA | `vgaRed/vgaGreen/vgaBlue[3:0]`, `Hsync`, `Vsync` | 4-4-4 RGB |
| debug | `led[0]` | MMCM lock indicator |

## Status

Scripted and staged; not yet synthesised or hardware-verified in this
fork. IO/audio/video decisions follow the proven sibling port. See repo
status for the current per-port record.

## Music synthesis

Music synthesis output stage is provided by an XAPP154-style delta-sigma DAC (`contrib/basys3/rtl/
dac.vhd`, 10-bit accumulator reset to mid-scale) clocked at 24.576 MHz
(`clock_24576`) and fed full-scale 8-bit `audio_u8`.

