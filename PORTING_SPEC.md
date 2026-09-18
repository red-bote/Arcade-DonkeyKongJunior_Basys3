# PORTING_SPEC -- Donkey Kong Junior (Arcade-DonkeyKongJunior_Basys3) to Basys3

Design intent for the from-scratch Basys 3 port (Artix-7 `xc7a35tcpg236-1`,
Vivado 2020.2) of gaz68's `Arcade-DonkeyKongJunior_MiSTer` core (CPU/video RTL
originally by Katsumi Degawa), following the per-tree DeMiSTified-family
convention (own git tree, `Makefile` + `contrib/`, non-nested
`basys3/dkongjr_basys3.xpr`).

This fork vendors the pristine MiSTer core directly at the repo top level
(`src/`, `sys/`, `releases/`, root `dpram.vhd`); the sibling
`gaz88/DonkeyKongJr_DeMiSTified` is a hardware-verified reference port of the
same core and is read as a proven oracle for wrapper/IO/audio decisions --
see §10. Where this port reuses an interface idiom of that sibling, it
re-derives it against the pristine RTL in this tree rather than copying the
sibling's implementation, so both ports stay independently maintainable.

This port is one of the confirmed examples generalized into
`.opencode/skills/port-mister-machine/SKILL.md` (the "separable core, thin
framework" case: `dkongjr_top.v` is HPS-free and reused directly, with the
pristine MiSTer HPS/OSD/HDMI top excluded wholesale). This document keeps
only this port's own design-intent detail, organized by topic rather than by
workflow step. It carries no port-status or build-verification report.

## 1. Source category and why this differs from every existing port

Every existing DeMiSTified-family port in this repo (EBAZ4205-Mappy,
EBAZ4205-CongoBongo, TangNano20K-DigDug, TangNano20K-MoonPatrol, DE2-Xevious)
starts from an already-adapted small-board variant of a core, none of which
depend on the MiSTer HPS/`hps_io` framework. This port instead starts from a
raw MiSTer-devel core: the pristine top (`Arcade-DonkeyKongJunior.sv`)
integrates `hps_io`, `ioctl_download`-based ROM streaming from the ARM
HPS/SD card, the OSD, and the HDMI/`ascal` scaler path -- none of which
exist on a Basys 3 (no HPS, no SD card, no HDMI).

The core proper, `src/dkongjr_top.v`, is HPS-free: its external boundary is
plain (`I_CLK_24576M`, `I_RESETn`, per-player input pins, `dn_addr/dn_data/
dn_wr` download bus, VGA-level RGB/sync outputs, `O_SOUND_DAT`). The port
vendors `src/` plus one data file (`releases/dkj_wave.bin`), not the
Quartus/MiSTer framework files -- see §12 -- and authors its own
`dkongjr_basys3` wrapper, exactly as the DigDug/Mappy/Xevious ports exclude
their pristine top and author their own. A Basys 3 port of this core already
exists in this repo (`gaz88/DonkeyKongJr_DeMiSTified`); this fork is a
distinct, from-scratch porting effort against the same upstream core, built
to this repository's `port-mister-machine` skill with the sibling consulted
as reference only (see §10).

## 2. ROM sourcing: single drop-in `dkongjr_rom` module, not a per-region split

`dkongjr_top.v` funnels program-ROM, `VID_ROM1/2`, `OBJ_ROM1-4`, and a
reset-time config-replay sequencer (`R_AD`/`phase`/`W_VC_A`, see below)
through **one shared bus** into a single `dkongjr_rom` instance (`I_ADDRB`
17 bits). At reset, that sequencer copies `R_AD` 0x0000-0x12FF (mapped to
flat ROM address 0xE000-0xF2FF) into separate on-chip destinations:
sound-CPU program RAM (0x0000-0x0FFF window -> `dkongjr_sound.v`'s
`ram_4096_8`), palette RAM (0x1000-0x11FF window, two ports), and one VRAM
init row (0x1200-0x12FF window). This sequencer lives inside `dkongjr_top.v`
(never modified), so the ROM replacement must preserve `dkongjr_rom.v`'s
exact module name, port list, and internal address-remap logic as **one**
module -- splitting into a module-per-logical-ROM (the TangNano20K-DigDug
precedent, `make_digdug_roms.py`) would silently corrupt the sequencer's
targets.

Replacement: `proms/dkongjr_roms.v` defines a single
`module dkongjr_rom(I_CLKA, I_CLKB, I_ADDRA, I_ADDRB, I_ADDRC, I_DA, I_WEA,
O_DB, O_DC)` (port list identical to pristine), backed by two flat
`initial`-block arrays (Vivado infers BRAM for both): `mem[0:65535]`
(program/graphics/sound-table ROM, 8-bit) answering `I_ADDRB` through the
pristine `W_ADDRB` case-statement remap (the 0x0000-0x5FFF program-ROM
re-mapping, reproduced verbatim from `dkongjr_rom.v`), and `wav_mem[0:49151]`
(wave-sample ROM, 16-bit, from the vendored `releases/dkj_wave.bin`)
answering `I_ADDRC` -- see §4. `I_ADDRA`/`I_DA`/`I_WEA`/`I_CLKA` are accepted
but unused (the wrapper ties `dn_addr`/`dn_data`/`dn_wr` to `0`; there is no
download bus on a Basys 3).

These ties, and `I_SF` (§8), cannot be bare literals/aggregates
(`(others => '0')`, `'0'`) directly in `dkongjr_top`'s VHDL port map --
`dkongjr_top` is a foreign-language (Verilog) module, and Vivado's
mixed-language elaborator cannot resolve a bare literal's type against a
foreign port (`Synth 8-2784`/`8-2396`, "N visible types match here"). The
wrapper routes each constant through a locally-declared, explicitly-typed
signal instead (`dn_addr_tie`, `dn_data_tie`, `dn_wr_tie`, `i_sf_tie` in
`dkongjr_basys3.vhd`) -- see `.opencode/skills/port-mister-machine/
SKILL.md` §7 for this as a recurring pattern across the family, not a
one-off workaround.

This sidesteps the `dpram.vhd` (`altsyncram`, Altera-only) portability
problem for the ROM path entirely: no dual-port RAM primitive is needed
here, only a plain read-only BRAM.

## 3. RAM portability: portable `dpram` backs every internal RAM

`dpram.vhd` (repository-root in this fork, alongside `src/`) is a generic
Altera `altsyncram` entity (`intended_device_family => "Cyclone V"`), not
Vivado-synthesizable. It is instantiated by every RAM wrapper in
`src/dkongjr_bram.v` (10 instantiations, generic widths from
`dpram #(6,8)` up to `dpram #(12,8)` -- note the generic order is
`addr_width_g` then `data_width_g`, and single-generic forms like
`dpram #(16)` rely on the `data_width_g := 8` default), which back CPU work
RAM, sprite/OBJ RAM, VRAM, palette RAM, and the sound-CPU's internal
program/data RAM.

`add_files` never touches the pristine `dpram.vhd` (it lives outside the
`src/` glob `create_project.sh` walks); the import set instead adds
`contrib/basys3/rtl/dpram.vhd`, a plain inferred true-dual-port RAM,
entity- and port-compatible with the pristine file (same generics
`addr_width_g`/`data_width_g` with the same defaults, same 10 ports
`address_a/b`, `clock_a/b`, `data_a/b`, `enable_a/b`, `wren_a/b`,
`q_a/b`), no vendor primitive. Read-during-write is write-first on a
write/read address collision (the port that writes drives its own output
with the new data), matching altsyncram's `NEW_DATA_NO_NBE_READ` for the
common single-writer usage here. It drops into every `dkongjr_bram.v`
wrapper unmodified.

Read-during-write timing match against the pristine `altsyncram`
configuration (`address_reg_b => "CLOCK1"`, `indata_reg_b => "CLOCK1"`) is a
hardware-bring-up verification item, not provable statically -- see §13.

## 4. Audio scope: PCM sample layer included

`dkongjr_top.v` mixes two independent sound sources into `O_SOUND_DAT`:

- `dkongjr_sound.v` ("Digtal_sound"): the i8035/T48 sound-CPU board
  (`i8035ip.v` + `t48_ip/*.vhd`), producing the primary chip-driven game
  sound, further passed through an on-chip DAC (`dkongjr_dac.sv`) and a
  2nd-order IIR low-pass filter, selected by `I_SF`.
- Four instances of `dkongjr_wav_sound.v` ("walk_climb_sounds",
  "jump_sound", "land_sound", "fall_sound"): PCM playback of digitized
  analogue-board samples, backed by a 96 KiB (49152 x 16-bit) `wav_rom`
  region.

The PCM sample layer is included. Rationale: the xc7a35t's 1800 Kb block
RAM budget comfortably covers the 96 KiB wave ROM on top of the core's
program/OBJ/VRAM. Each `dkongjr_wav_sound` instance's `O_SND` depends only
on its `I_DMA_DATA` input -- `W_DMA_DATA <= I_DMA_DATA * W_VOL`,
`W_SAMPL <= W_DMA_DATA[23:8]` -- wired from the ROM's `O_DC` output (§2),
and on `I_VOL` (`I_ANLG_VOL` at the `dkongjr_top` boundary), which selects
the mix volume per the pristine `dkongjr_wav_sound.v` case table (`4`=OFF,
`5`-`10`=10%-60%, `0`=70%, `1`=80%, `2`=90%, `3`=100%). The wrapper drives
`I_ANLG_VOL` from `sw(11 downto 8)`, giving the switches direct control over
this non-linear volume encoding (see §8) rather than tying it to a fixed
value.

`dkj_wave.bin` (the flat, 16-bit little-endian PCM sample data feeding
`wav_mem`) stays vendored at `releases/dkj_wave.bin`. Unlike the MAME
romset, this is open-source data distributed as part of gaz68's MiSTer-devel
port under that repo's own license, not copyrighted arcade ROM content -- it
is tracked in git, not gitignored alongside `/roms/`/`/proms/`.

## 5. CPU IP

Main CPU is instantiated as `Z80IP CPU (...)` in `dkongjr_top.v`. `Z80IP` is
not a macro -- `z80ip_f.v` and `z80ip_t.v` both independently declare
`module Z80IP(...)` with an identical port list, so selection is a
project-file-list choice (only one can be compiled without a name
collision). The pristine `.qsf` includes `z80ip_t.v` plus
`t80asd_ip/{T80_Pack,T80_ALU,T80_MCode,T80_Reg,T80,T80as}.vhd`, and does
**not** reference `fz80_ip/` or `z80ip_f.v` (dead code, never built
upstream). This port imports the `z80ip_t.v` / `t80asd_ip` set and excludes
`fz80_ip/*` and `z80ip_f.v` entirely.

`t80asd_ip/T80_RegX.vhd` also declares `entity T80_Reg` (confirmed by direct
inspection, an exact duplicate of `T80_Reg.vhd`'s entity name) -- the
duplicate-entity landmine that recurs across this family whenever a T80 CPU
IP set is vendored (see `.opencode/skills/port-mister-machine/SKILL.md` §2)
-- it must be excluded from the Vivado project alongside the fz80 files, or
elaboration fails on a duplicate entity. `T80_Reg.vhd` (the one with a real
`architecture rtl`) is the file to keep.

Neither CPU variant uses Altera/Quartus-specific primitives (confirmed: no
`altera`/`cyclone`/`altsyncram`/`lpm_` hits in `t80asd_ip/*.vhd` or
`fz80_ip/*.v`).

Sound CPU is `i8035ip.v` (T48/8035-compatible, `t48_ip/*.vhd`), the same IP
family already used by sf-darfpga Dar ports that carry an 8035/8039 sound
CPU -- no new CPU IP family for this repo.

## 6. Clocking

Core clock is `I_CLK_24576M` (24.576 MHz), a non-integer ratio of the
100 MHz Basys 3 oscillator (100 / 24.576 ~= 4.069). As with the DE2-Xevious
port's 18/11 MHz pair, exact integer division from one VCO is not required
-- `clk_wiz_0` requests 24.576 MHz. `make_clk_wiz_0.sh` records the actual
achieved frequency from `C_CLKOUT0_ACTUAL_FREQ` in the generated `.xci`
(the internal MMCM primitive numbering is 0-based, one behind the
user-facing `clk_out1` port; `C_CLKOUT1_ACTUAL_FREQ` is a different, unused
output). The expected value is ~24.574 MHz (~0.0006% off request) -- if the
logever diverges significantly, re-check the MMCM config. This is a
non-risk item pending `make clk_wiz` confirmation (§13).

`I_CLK_24576M` feeds the core directly; the core's internal 12.288 MHz /
6.144 MHz nodes (`W_CLK_12288M`, `W_H_CNT[0]`) are derived *inside*
`dkongjr_top.v` via `dkongjr_hv_count.v` and are **not exposed at the core's
port boundary**. Unlike TangNano20K-DigDug (whose core does expose its
divided clock), the wrapper cannot tap the core's internal node for the
PS/2 keyboard clock -- it needs its own independent `clock_24576/2`
(12.288 MHz) fabric divider, clearing the repo's >=6 MHz USB-HID keyboard-
clock floor with margin.

## 7. Video

`dkongjr_top.v` exposes `O_VGA_R[2:0]/O_VGA_G[2:0]/O_VGA_B[1:0]` (3-3-2),
active-low `O_VGA_H_SYNCn/O_VGA_V_SYNCn`, and active-high `O_H_BLANK/
O_V_BLANK`. Confirmed from `dkongjr_hv_count.v`: `H_CNT` runs 0-767 at
12.288 MHz (768 states: 512 active + 256 blank), `V_CNT` runs 0-255 then
504-511 (264 states: 224 active + 40 blank, standard 60 Hz arcade timing);
both sync pulses are active-low (already the polarity the vendored MiST-style
scandoubler, `scandoubler_new.v`, expects -- see §12). `O_PIX = H_CNT[0]`,
an effective ~6.144 MHz pixel-rate toggle (`I_CLK/4`).

**RGB is not internally blanked** -- confirmed, no AND-gate against
H_BLANK/V_BLANK anywhere in `dkongjr_top.v` or `dkongjr_col_pal.v`. The
wrapper must gate RGB externally before the scandoubler. The pristine
MiSTer top (`Arcade-DonkeyKongJunior.sv`, excluded from this port) delays
`O_H_BLANK` through an 8-stage shift register clocked on an `O_PIX`
edge-detect before gating color, to realign the blank edge with
`dkongjr_col_pal.v`'s internal pipeline latency (a clocked address-latch,
`W_1EF_Q`). The wrapper reproduces that exact construct (edge-detect on
`O_PIX`, 8-deep shift register on H_BLANK only, gate RGB on the delayed
H-blank AND the undelayed V-blank). No existing port in this repo has solved
this exact problem before; the 8-stage depth is a starting point derived
from RTL reading, not a hardware-proven value -- see §13.

## 8. Inputs

Per-player discrete inputs (`I_U1/I_D1/I_L1/I_R1/I_J1`, `I_U2/...`,
`I_S1/I_S2/I_C1`), **active-low** at the core boundary
(`W_SW1={1,1,1,I_J1,I_D1,I_U1,I_L1,I_R1}` etc.), plus `I_SF` (sound-filter
select: `1` = filtered/IIR low-pass output, `0` = unfiltered -- tied to `1`
by default, filtered is the pristine cabinet's typical configuration) and
`I_DIP_SW[7:0]` / `I_ANLG_VOL[3:0]` (the latter driven from `sw(11 downto
8)`, selecting the wave-sample mix volume -- see §4). Repo convention
applies: PS/2 keyboard (`io_ps2_keyboard`/`kbd_joystick`, vendored from an
existing Dar/DeMiSTified port -- this pristine core has no PS/2 decoder of
its own) OR-merged with the PMODA JA joystick and button/switch fallback,
inverted at the port map boundary to match the core's active-low convention.
Per existing repo convention ("P2 mirrors P1",
`sf-darfpga/PORTING_SPEC.md` §4), the same joystick/keyboard vector drives
both `I_U1..I_J1` and `I_U2..I_J2`; only `I_S1`/`I_S2`/`I_C1` distinguish
players.

`I_DIP_SW[7:0]` mapping, copied directly from the pristine MiSTer top's own
`m_dip` formula (`Arcade-DonkeyKongJunior.sv`, `{~status[12], 3'b000,
status[11:10], status[9:8]}`) -- the same port on the same core, not an
independent re-derivation:

| I_DIP_SW bit | Meaning | sw source |
|---|---|---|
| [7] | Cabinet (0=Upright, 1=Cocktail) | `not sw(7)` |
| [6:4] | unused | `"000"` |
| [3:2] | Bonus score (10000/15000/20000/25000) | `sw(3:2)` |
| [1:0] | Lives (3/4/5/6) | `sw(1:0)` |

Treat this table as needing empirical confirmation against real DIP
documentation (see §13), not final.

## 9. ROM map

Program/graphics/sound-table region, address range 0x0000-0xF2FF, confirmed
against `src/dkongjr_rom.v`'s header comment and `~/roms/dkongjr.zip`'s
actual contents (13 files, verified by the generator's size/`ofileMd5sum`
gate -- see §10):

| Offset | File | Size |
|---|---|---|
| 0x0000 | dkj.5b | 8192 |
| 0x2000 | dkj.5c | 8192 |
| 0x4000 | dkj.5e | 8192 |
| 0x6000 | dkj.3p | 4096 |
| 0x7000 | dkj.3n | 4096 |
| 0x8000 | dkj.5b (repeat) | 8192 |
| 0xA000 / 0xA800 | v_7c.bin (x2 repeat) | 2048 each |
| 0xB000 / 0xB800 | v_7d.bin (x2 repeat) | 2048 each |
| 0xC000 / 0xC800 | v_7e.bin (x2 repeat) | 2048 each |
| 0xD000 / 0xD800 | v_7f.bin (x2 repeat) | 2048 each |
| 0xE000 | c_3h.bin | 4096 |
| 0xF000 | c-2e.bpr | 256 |
| 0xF100 | c-2f.bpr | 256 |
| 0xF200 | v-2n.bpr | 256 |
| 0xF300-0xFFFF | zero-fill | 3328 |

`dkongjr_rom.v`'s program-ROM address translation (its own `W_ADDRB` case
statement) is reproduced verbatim by the generator -- the CPU-visible
0x0000-0x5FFF program space is a re-mapped view of the 5B/5C/5E bank, not a
linear concatenation.

Wave-sample region: 49152 x 16-bit little-endian words (96 KiB), a direct
word-for-word load of `dkj_wave.bin` with no offset math (the pristine
`dkongjr_rom.v` download-path rebasing, `I_ADDRA[17:1] - 0x8000`, existed
only to relocate the HPS download stream's flat byte address into
`dkj_wave.bin`'s own 0-based word address -- moot here, since the generator
reads `dkj_wave.bin` directly).

The generator (`contrib/tools/make_dkongjr_roms.py`) assembles both regions
in one pass and MD5-gates the combined result against
`releases/build_rom.ini`'s recorded `ofileMd5sumValid` value, so a wrong or
re-corrupted romset fails closed at `make setup` rather than misbaking into
BRAM.

## 10. ROM sourcing

`ROMZIP` defaults to `~/roms/dkongjr.zip`. The zip present on disk contains
the 13 files above under the MiSTer-era **renamed** member names
(`dkj.5b/dkj.5c/...`, `v_7c.bin/v_7d.bin/...`, `c_3h.bin`,
`c-2e.bpr/c-2f.bpr/v-2n.bpr`) -- the same convention the
TangNano20K-DonkeyKongJr/Gaz68 small-board ports use; these are not the MAME
`djr1-*` original filenames, which is why the pristine Quartus-era
`build_rom.bat`/`build_rom.ini` member names do not match this set. The
on-disk `~/roms/dkong.z*` files (`dkongjr.zip`, `dkong.zip`) are the plain
Donkey Kong romset -- unrelated to this port, same situation documented in
the sibling port's spec.

The sibling `gaz88/DonkeyKongJr_DeMiSTified` uses the identical 13-member
renamed layout, and its generated `proms/dkongjr_roms.v` was byte-compared
during this port's bring-up: the value sets are identical (only header
comment formatting differs). The sibling is otherwise treated as a reviewed
design oracle for §7/§8/§12 decisions, not a source to be copied from -- the
wrapper, scripts, and docs in this tree are authored fresh.

`AGENTS.md` at the repo root describes `dkong_sound_samples/` staging both
romsets; that namespace does not exist in this working tree -- this port
stages its own romset independently via `prep_roms.sh`, unaffected.

## 11. Synthesis fixes

Two Vivado 2020.2 Verilog-parser rejections found by static inspection of
the pristine sources (Synth 8-1873, "declarations not allowed in unnamed
block"): the pristine sources declare a local `reg` as the first statement
inside an unnamed `always @(...) begin ... end` block -- valid Verilog,
rejected by Vivado's synthesizer (the same class of issue as DE2-Xevious's
`scandoubler_fix.patch`; both are cited as the confirmed-recurring example
for this error class in `.opencode/skills/port-mister-machine/SKILL.md`
§10). Fixed via tracked patches under `contrib/code/`, applied idempotently
by `setup_dkongjr.sh` (`patch -p1 --forward`, guarded by a reverse-dry-run
check per the repo's documented `patch -p1 --forward` non-idempotency
pitfall):

- `dkongjr_dma_synth_fix.patch`: moves `reg old_trig;` (`dkongjr_dma.v`)
  from inside the unnamed block to module scope. No behavioral change -- a
  `reg` declared inside a Verilog procedural block already persists across
  clock edges like any register; this only relocates the declaration
  textually.
- `dkongjr_vram_synth_fix.patch`: moves `reg prev;` (`dkongjr_vram.v`)
  from inside the unnamed block to module scope, same rationale.

A full scan of the vendored `src/*.v` tree (all `begin`/`always` blocks,
allowing intervening blank lines) confirms these are the only two
occurrences of this pattern -- no other Vivado 2020.2 Verilog-parser
rejections found by this scan.

## 12. Project import

Vendors `src/` (pristine core, at repo root in this fork) plus one file from
`releases/`: `dkj_wave.bin` (§4, open-source sample data, not Quartus
framework). `sys/`, the Quartus project files
(`Arcade-DonkeyKongJunior.qpf/.qsf/.srf`, `clean.bat`), the pristine
`Arcade-DonkeyKongJunior.sv`, and the root `dpram.vhd` remain unvendored/
unimported -- 100% MiSTer/Quartus framework or Altera-only primitive, never
touched by this port. The pristine material is never modified in place
except by the tracked §11 patches; all port-specific work lives in
`contrib/` and the generated wrapper/ROM assembly.

`create_project.sh` imports all `.vhd`/`.v`/`.sv` under `src/` **except**:
`fz80_ip/*`, `z80ip_f.v`, `dkongjr_rom.v` (replaced by
`proms/dkongjr_roms.v`), `t80asd_ip/T80_RegX.vhd` (§5). Note the `.sv`
extension matters: `dkongjr_dac.sv` (the DAC discharge-circuit model,
instantiated by `dkongjr_top.v`) is the only SystemVerilog file in the tree
and is easy to miss with a `.vhd`/`.v`-only glob (elaboration fails with
"module 'dkongjr_dac' not found"). The pristine `dpram.vhd` is not under
`src/` so it is naturally excluded; the portable `dpram` (§3) is added from
`contrib/basys3/rtl/`.

Adds `contrib/basys3/rtl/dpram.vhd` (§3), `proms/dkongjr_roms.v` (§2/§4),
and the wrapper-owned RTL utilities also vendored into
`contrib/basys3/rtl/` (§7): `io_ps2_keyboard.vhd`/`kbd_joystick.vhd` (PS/2
decoder, this core has none) and `scandoubler_new.v` (the MiST-style
scandoubler used by the TangNano20K-DigDug/EBAZ4205-Mappy/DE2-Xevious
family, not the sf-darfpga-family DECA `vga_scandoubler.v` -- this core has
no existing small-board variant to inherit a scandoubler from, so one is
vendored fresh from an existing DeMiSTified port).

## 13. Remaining risks/unknowns requiring empirical verification

Not resolved by this implementation pass -- flagged here rather than
assumed:

1. The 8-stage H_BLANK delay-match (§7) is unverified beyond RTL reading --
   no existing port in this repo has solved this; needs waveform simulation
   or hardware bring-up to confirm no fringe/smear at column boundaries.
2. DIP switch bit semantics (§8) -- derived from the pristine wrapper's own
   wiring, not independently verified against real DIP documentation or
   hardware.
3. `contrib/basys3/rtl/dpram.vhd`'s read-during-write timing (§3) must
   reasonably match the pristine `altsyncram` configuration's semantics
   closely enough for the CPU/VRAM/palette RAM read-after-write patterns
   already baked into the core's timing assumptions -- a behavioral mismatch
   here could produce subtle data-hazard bugs undetectable until hardware
   bring-up.
4. The `clk_wiz_0` requested-vs-achieved frequency (§6) is expected at
   ~24.574 MHz; the actual value is reported by `make clk_wiz` and should
   be read back before the first `make synth`.
5. The PWM audio scaling for the signed 16-bit `O_SOUND_DAT` (sign-bit
   inversion + truncation to reuse the standard 9-bit-accumulator idiom) and
   the mixed digital+analogue sound path (§4) are unverified until hardware
   bring-up -- volume breadth and clipping headroom are the unknowns.