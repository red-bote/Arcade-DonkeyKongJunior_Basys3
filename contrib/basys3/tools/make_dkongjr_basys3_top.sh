#!/bin/bash
# Author the Basys3 top level (dkongjr_basys3.vhd) for Donkey Kong Junior
# and register it, plus the clk_wiz_0 IP wrappers, in dkongjr_basys3.xpr.
#
# The pristine core (dkongjr_top, MiSTer-devel Verilog) is wrapped directly
# -- its HPS/OSD/HDMI framework (Arcade-DonkeyKongJunior.sv, sys/*) is not
# imported; dkongjr_top's own boundary is HPS-free. The wrapper adds the
# MMCM, an independent fabric PS/2 keyboard clock (the core's internal
# 12.288/6.144 MHz nodes are not exposed at its port boundary), the PS/2
# keyboard + PMODA joystick inputs, an H-blank delay match for the
# scandoubler, PWM audio to PmodAMP2, and VGA pin assignment.
#
# See PORTING_SPEC.md for full design intent. Requires `make setup`,
# `make create_prj`, `make clk_wiz` to have run. Per project rules this
# script runs from /tmp so logs stay outside the repo.

set -euo pipefail

VIVADO="${VIVADO:-/tools/Xilinx/Vivado/2020.2/bin/vivado}"

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PROJ_DIR="$ROOT/basys3"
XPR="$PROJ_DIR/dkongjr_basys3.xpr"
TARGET_SRC="$PROJ_DIR/dkongjr_basys3.srcs/sources_1/new"
TARGET="$TARGET_SRC/dkongjr_basys3.vhd"
CLK_WIZ_SRC="$PROJ_DIR/dkongjr_basys3.srcs/sources_1/imports/clk_wiz_0"

mkdir -p "$TARGET_SRC"

if [ ! -f "$XPR" ]; then
    echo "error: Vivado project not found: $XPR" >&2
    echo "Run 'make create_prj clk_wiz' first." >&2
    exit 1
fi

cat > "$TARGET" <<'EOF'
---------------------------------------------------------------------------------
-- Basys3 top level for Donkey Kong Junior (MiSTer-devel core; gaz68 port)
--
-- Wraps the pristine dkongjr_top directly; the upstream HPS/OSD/HDMI
-- framework (Arcade-DonkeyKongJunior.sv, sys/*) is not imported.
-- dkongjr_top's own boundary is HPS-free. Design intent in PORTING_SPEC.md.
--
-- This wrapper adds:
--   - MMCM clock (100 MHz -> 24.576 MHz) for the core, plus an independent
--     fabric /2 divider (12.288 MHz) for the PS/2 keyboard clock -- the
--     core's own internal 12.288 MHz node is not exposed at its boundary.
--   - PS/2 keyboard (io_ps2_keyboard + kbd_joystick, vendored from an
--     existing Basys3 port) OR-merged with the PMODA JA joystick. Both are
--     active-high internally and inverted at the dkongjr_top map to match
--     its active-low convention. P2 mirrors P1; only start/coin differ.
--   - An 8-stage H-blank delay shift register (mirrors the pristine
--     MiSTer top's `hbl <= (hbl<<1)|hbl0`, clocked on an O_PIX edge)
--     before gating RGB -- dkongjr_top's RGB is not internally blanked and
--     its color pipeline has latency beyond the raw O_H_BLANK edge.
--   - The vendored MiST-style scandoubler (scandoubler_new.v, entity
--     `scandoubler`), fed 6-bit RGB by bit replication (3-3-2 -> 6-6-6),
--     narrowed to 4-4-4 for the Basys 3 VGA connector.
--   - A wrapper-owned 9-bit PWM accumulator driving PmodAMP2 from the
--     core's signed 16-bit O_SOUND_DAT (sign-bit inversion + truncation to
--     a unsigned 8-bit value -- repo-standard PWM idiom, section 13).
--   - I_DIP_SW derived from `sw` via the pristine MiSTer top's own m_dip
--     formula (same port on the same core).
--
-- Controls:
--   btnC = reset (active-high; held during MMCM lock as well)
--   btnU = coin   btnL = 1P start   btnR = 2P start   (btnD unused)
--   sw(11 downto 8) = wave-sample channel volume (dkongjr_wav_sound.v
--     select: 4=OFF 5=10% 6=20% 7=30% 8=40% 9=50% 10=60% 0=70% 1=80%
--     2=90% 3=100%)
--   sw(14) = AMP shutdown (0 = enable)
--   sw(15) = AMP gain (0 = 12 dB, 1 = 6 dB)
--   ps2_clk/ps2_dat = onboard USB HID connector (C17/B17)
--   I_SF (sound filter) tied to '1' (filtered) -- not switch-selectable v1.
---------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;

library work;

entity dkongjr_basys3 is
port(
 clk              : in  std_logic;
 sw               : in  std_logic_vector(15 downto 0);
 btnC             : in  std_logic;  -- reset
 btnU             : in  std_logic;  -- coin
 btnL             : in  std_logic;  -- 1P start
 btnR             : in  std_logic;  -- 2P start

 JA               : in  std_logic_vector(4 downto 0);  -- active-low joystick (right,left,down,up,fire)

 ps2_clk          : in  std_logic;
 ps2_dat          : in  std_logic;

 O_PMODAMP2_AIN   : out std_logic;
 O_PMODAMP2_GAIN  : out std_logic;
 O_PMODAMP2_SHUTD : out std_logic;

 vgaRed           : out std_logic_vector(3 downto 0);
 vgaGreen         : out std_logic_vector(3 downto 0);
 vgaBlue          : out std_logic_vector(3 downto 0);
 vgaHsync         : out std_logic;
 vgaVsync         : out std_logic;

 led              : out std_logic_vector(5 downto 0)
);
end dkongjr_basys3;

architecture struct of dkongjr_basys3 is

 -- MMCM output
 signal clock_24576 : std_logic;
 signal mmcm_locked : std_logic;

 -- fabric /2 divider for the PS/2 clock (core node not exposed)
 signal clock_12288 : std_logic := '0';

 signal reset_n : std_logic;

 -- keyboard chain
 signal kbd_intr     : std_logic;
 signal kbd_scancode : std_logic_vector(7 downto 0);
 signal kbd_joy      : std_logic_vector(8 downto 0);

 -- PMODA joystick (after inversion) + combined vector
 signal ja_up, ja_down, ja_left, ja_right, ja_fire : std_logic;
 signal btn_joy : std_logic_vector(8 downto 0);
 signal joy     : std_logic_vector(8 downto 0);

 signal dip_sw : std_logic_vector(7 downto 0);

 -- dkongjr_top is foreign Verilog: Vivado's mixed-language elaborator
 -- cannot bind a bare literal/aggregate in a direct port association to a
 -- foreign port (Synth 8-2784/8-2396); route constants through local,
 -- explicitly-typed signals instead.
 signal dn_addr_tie  : std_logic_vector(18 downto 0) := (others => '0');
 signal dn_data_tie  : std_logic_vector(7 downto 0)  := (others => '0');
 signal dn_wr_tie    : std_logic := '0';
 signal i_sf_tie     : std_logic := '1';

 -- core video (3-3-2)
 signal core_r : std_logic_vector(2 downto 0);
 signal core_g : std_logic_vector(2 downto 0);
 signal core_b : std_logic_vector(1 downto 0);
 signal hblank0 : std_logic;
 signal vblank  : std_logic;
 signal hsyncn  : std_logic;
 signal vsyncn  : std_logic;
 signal pix_clk : std_logic;

 -- H-blank delay match (8-stage shift register on an O_PIX edge)
 signal old_pix         : std_logic := '0';
 signal hbl             : std_logic_vector(8 downto 0) := (others => '0');
 signal hblank_delayed  : std_logic;

 -- blanked RGB before the scandoubler
 signal r_gated : std_logic_vector(2 downto 0);
 signal g_gated : std_logic_vector(2 downto 0);
 signal b_gated : std_logic_vector(1 downto 0);

 -- scandoubler result (internal; VGA ports get one driver each)
 signal video_r_x2 : std_logic_vector(5 downto 0);
 signal video_g_x2 : std_logic_vector(5 downto 0);
 signal video_b_x2 : std_logic_vector(5 downto 0);
 signal hsync_x2    : std_logic;
 signal vsync_x2    : std_logic;

 -- audio
 signal audio_16       : std_logic_vector(15 downto 0);
 signal audio_u8       : std_logic_vector(7 downto 0);

begin

 ---------------------------------------------------------------------------
 -- Reset: hold in reset while the MMCM locks, or while btnC is held.
 ---------------------------------------------------------------------------
 reset_n <= mmcm_locked and (not btnC);

 ---------------------------------------------------------------------------
 -- MMCM: 100 MHz -> 24.576 MHz (requested; actual recorded by
 -- make_clk_wiz_0.sh, see PORTING_SPEC.md section 6)
 ---------------------------------------------------------------------------
 clocks : entity work.clk_wiz_0
 port map(
  clk_in1  => clk,
  clk_out1 => clock_24576,
  reset    => std_logic'('0'),
  locked   => mmcm_locked
 );

 process(clock_24576)
 begin
  if rising_edge(clock_24576) then
   clock_12288 <= not clock_12288;
  end if;
 end process;

 ---------------------------------------------------------------------------
 -- PS/2 keyboard -> joystick chain (vendored unmodified; dkongjr_top has
 -- no PS/2 decoder of its own)
 ---------------------------------------------------------------------------
 keyboard : entity work.io_ps2_keyboard
 port map (
  clk       => clock_12288,
  kbd_clk   => ps2_clk,
  kbd_dat   => ps2_dat,
  interrupt => kbd_intr,
  scancode  => kbd_scancode
 );

 joystick : entity work.kbd_joystick
 port map (
  clk           => clock_12288,
  kbdint        => kbd_intr,
  kbdscancode   => kbd_scancode,
  joy_BBBBFRLDU => kbd_joy,
  fn_pulse      => open,
  fn_toggle     => open
 );

 ---------------------------------------------------------------------------
 -- PMODA JA joystick fallback (active-low, pulled up by the XDC), OR-merged
 -- with the keyboard. Bit layout matches kbd_joystick's joy_BBBBFRLDU:
 -- 0=up 1=down 2=left 3=right 4=fire 5=start1 6=start2 7=coin.
 ---------------------------------------------------------------------------
 ja_right <= not JA(0);
 ja_left  <= not JA(1);
 ja_down  <= not JA(2);
 ja_up    <= not JA(3);
 ja_fire  <= not JA(4);

 btn_joy <= '0' & btnU & btnR & btnL & ja_fire & ja_right & ja_left & ja_down & ja_up;
 joy     <= kbd_joy or btn_joy;

 ---------------------------------------------------------------------------
 -- DIP switches: same m_dip formula the pristine MiSTer top uses
 -- (Arcade-DonkeyKongJunior.sv), applied to the same port on the same
 -- core. See PORTING_SPEC.md section 8.
 ---------------------------------------------------------------------------
 dip_sw <= (not sw(7)) & "000" & sw(3 downto 2) & sw(1 downto 0);

 ---------------------------------------------------------------------------
 -- Donkey Kong Junior core (dkongjr_top, MiSTer-devel Verilog).
 -- I_U1..I_J2/I_S1/I_S2/I_C1 are active-low at the core boundary; the
 -- wrapper's active-high joy vector is inverted at the map. P2 mirrors
 -- P1 (repo convention), only start/coin distinguish players.
 ---------------------------------------------------------------------------
 dkong : entity work.dkongjr_top
 port map (
  I_CLK_24576M => clock_24576,
  I_RESETn     => reset_n,

  dn_addr => dn_addr_tie,
  dn_data => dn_data_tie,
  dn_wr   => dn_wr_tie,

  O_PIX => pix_clk,

  I_U1 => not joy(0), I_D1 => not joy(1), I_L1 => not joy(2), I_R1 => not joy(3), I_J1 => not joy(4),
  I_U2 => not joy(0), I_D2 => not joy(1), I_L2 => not joy(2), I_R2 => not joy(3), I_J2 => not joy(4),

  I_S1 => not joy(5),
  I_S2 => not joy(6),
  I_C1 => not joy(7),
  I_SF => i_sf_tie,

  I_ANLG_VOL => sw(11 downto 8),
  I_DIP_SW   => dip_sw,

  O_VGA_R => core_r,
  O_VGA_G => core_g,
  O_VGA_B => core_b,

  O_H_BLANK => hblank0,
  O_V_BLANK => vblank,

  O_VGA_H_SYNCn => hsyncn,
  O_VGA_V_SYNCn => vsyncn,

  O_SOUND_DAT => audio_16
 );

 ---------------------------------------------------------------------------
 -- Video: 8-stage H-blank delay match, clocked on an O_PIX rising edge.
 -- Mirrors the pristine MiSTer top's `hbl <= (hbl<<1)|hbl0` to realign the
 -- raw H_BLANK edge with the core's color-pipeline latency; V-blank is
 -- used undelayed, matching upstream. Depth is an RTL-reading starting
 -- point, not yet hardware-verified (PORTING_SPEC.md section 7).
 ---------------------------------------------------------------------------
 process(clock_24576)
 begin
  if rising_edge(clock_24576) then
   old_pix <= pix_clk;
   if old_pix = '0' and pix_clk = '1' then
    hbl <= hbl(7 downto 0) & hblank0;
   end if;
  end if;
 end process;
 hblank_delayed <= hbl(8);

 r_gated <= core_r when (hblank_delayed = '0' and vblank = '0') else "000";
 g_gated <= core_g when (hblank_delayed = '0' and vblank = '0') else "000";
 b_gated <= core_b when (hblank_delayed = '0' and vblank = '0') else "00";

 ---------------------------------------------------------------------------
 -- Scandoubler (vendored MiST-style scandoubler_new.v, entity
 -- `scandoubler`). RGB filled to 6 bits by replication (3-3-2 -> 6-6-6),
 -- narrowed to 4-4-4 after. hsyncn/vsyncn are already active-low,
 -- matching the scandoubler's falling-edge-detected convention.
 ---------------------------------------------------------------------------
 dblscan : entity work.scandoubler
 port map(
  clk_sys   => clock_24576,
  scanlines => std_logic_vector'("00"),
  r_in      => r_gated & r_gated,
  g_in      => g_gated & g_gated,
  b_in      => b_gated & b_gated & b_gated,
  hs_in     => hsyncn,
  vs_in     => vsyncn,
  r_out     => video_r_x2,
  g_out     => video_g_x2,
  b_out     => video_b_x2,
  hs_out    => hsync_x2,
  vs_out    => vsync_x2
 );

 vgaRed   <= video_r_x2(5 downto 2);
 vgaGreen <= video_g_x2(5 downto 2);
 vgaBlue  <= video_b_x2(5 downto 2);
 vgaHsync <= hsync_x2;
 vgaVsync <= vsync_x2;

 ---------------------------------------------------------------------------
 -- Audio: XAPP154-style delta-sigma DAC (10-bit accumulator reset to
 -- mid-scale; dac.vhd from contrib/basys3/rtl/) -> PmodAMP2. O_SOUND_DAT
 -- is signed 16-bit (unlike every other port's 8-bit-unsigned source);
 -- convert by sign-bit inversion + truncation to the top 8 bits
 -- (PORTING_SPEC.md section 13).
 --
 -- Audio-variant C: exact replica of the other/donkey-kong-fpga output
 -- stage -- the delta-sigma DAC clocked at 24.576 MHz (clock_24576) and
 -- fed full-scale audio_u8 (0..255), no attenuation.
 ---------------------------------------------------------------------------
 audio_u8 <= (not audio_16(15)) & audio_16(14 downto 8);

 audio_dac : entity work.dac
 generic map(
  msbi_g => 7
 )
 port map(
  clk_i   => clock_24576,
  res_n_i => reset_n,
  dac_i   => audio_u8,
  dac_o   => O_PMODAMP2_AIN
 );

 O_PMODAMP2_SHUTD <= sw(14);  -- shutdown: 0 = enable
 O_PMODAMP2_GAIN  <= sw(15);  -- 0 = 12 dB, 1 = 6 dB

 ---------------------------------------------------------------------------
 -- Debug: MMCM lock indicator only (minimal-LED convention, cf. DE2-Xevious)
 ---------------------------------------------------------------------------
 led(0)          <= mmcm_locked;
 led(5 downto 1) <= (others => '0');

end struct;
EOF

echo "Placed target: $TARGET"

# Register the wrapper and clk_wiz_0 IP wrappers in the project and re-assert
# the top entity (create_project.sh sets the top before this file exists, so
# Vivado auto-discovers dkongjr_top instead).
WORK=/tmp/dkongjr_reg_top
TCL="$WORK/register_top.tcl"
rm -rf "$WORK"
mkdir -p "$WORK"

cat > "$TCL" <<EOF
open_project "$XPR"
add_files -fileset sources_1 -norecurse "$TARGET"
add_files -fileset sources_1 -norecurse "$CLK_WIZ_SRC/clk_wiz_0.v"
add_files -fileset sources_1 -norecurse "$CLK_WIZ_SRC/clk_wiz_0_clk_wiz.v"
set_property top dkongjr_basys3 [current_fileset]
close_project
EOF

(cd "$WORK" && "$VIVADO" -mode batch -nolog -nojournal -source "$TCL")

rm -rf "$WORK"

echo "Registered sources and set top to dkongjr_basys3"