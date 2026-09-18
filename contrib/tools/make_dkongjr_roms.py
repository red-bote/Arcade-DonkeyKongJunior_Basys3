#!/usr/bin/env python3
"""Emit proms/dkongjr_roms.v -- the single drop-in dkongjr_rom module.

A single Verilog module that replaces the vendored
src/dkongjr_rom.v: same module name and identical port list, so the
instantiation inside dkongjr_top.v is satisfied unchanged. It is backed
by two flat `initial`-block arrays (no $readmemh path fragility) that
Vivado synthesizes into BRAM.

It is generated from the unzipped romset on the host (no gcc, pure
Python) so the ROM bytes are baked in at synthesis time. The wrapper
ties dn_addr/dn_data/dn_wr to 0, so the pristine core's download-bus
write path (I_ADDRA/I_DA/I_WEA, I_CLKA) is dead on Basys3 and is not
reproduced here -- the ports remain on the module for instantiation
compatibility, unconnected.

Memory map (flat addresses, from the pristine dkongjr_rom.v header and
releases/build_rom.ini -- the authoritative byte order):

  0x00000-0x01FFF  5B program (8 KiB)
  0x02000-0x03FFF  5C program (8 KiB)
  0x04000-0x05FFF  5E program (8 KiB)
  0x06000-0x06FFF  3P gfx    (4 KiB)
  0x07000-0x07FFF  3N gfx    (4 KiB)
  0x08000-0x09FFF  5B repeat (8 KiB)
  0x0A000-0x0A7FF  7C gfx    (2 KiB)
  0x0A800-0x0AFFF  7C repeat (2 KiB)
  0x0B000-0x0B7FF  7D gfx    (2 KiB)
  0x0B800-0x0BFFF  7D repeat (2 KiB)
  0x0C000-0x0C7FF  7E gfx    (2 KiB)
  0x0C800-0x0CFFF  7E repeat (2 KiB)
  0x0D000-0x0D7FF  7F gfx    (2 KiB)
  0x0D800-0x0DFFF  7F repeat (2 KiB)
  0x0E000-0x0EFFF  3H sound  (4 KiB)
  0x0F000-0x0F0FF  2E prom   (256 B)
  0x0F100-0x0F1FF  2F prom   (256 B)
  0x0F200-0x0F2FF  2N prom   (256 B)
  0x0F300-0x0FFFF  empty.bin pad (3328 B, all zero)

The 0x10000-0x27FFF wave-sample region is NOT part of mem; the sample
RAM (walk/climb/jump/land/fall PCM) is built separately from the
vendored releases/dkj_wave.bin (open-source sample data, not MAME ROM
content) as 49152 little-endian 16-bit words feeding O_DC. See
PORTING_SPEC.md the audio section.

Integrity: the combined flat image (main + wave) is checked against the
MD5 that releases/build_rom.ini records for A.DKONGJR.ROM
(ofileMd5sumValid), gating the whole generator. The pristine program-ROM
address remap (W_ADDRB case statement) is reproduced verbatim.

Usage:
    make_dkongjr_roms.py ROMS_DIR PROMS_DIR WAVE_BIN
"""

import hashlib
import os
import sys

IMAGE_MD5 = "ebfc471d12606afd1408d62c7f4c90c9"  # build_rom.ini ofileMd5sumValid

MAIN_SIZE = 0x10000  # bytes 0x00000-0x0FFFF program/gfx/prom ("mem")
WAVE_SIZE = 0x18000  # bytes 0x10000-0x27FFF wave samples in the flat image
WAVE_WORDS = WAVE_SIZE // 2  # 49152 samples, little-endian 16-bit

# (file, offset, size) in flat-address order, byte order straight from
# releases/build_rom.ini ifiles. Sizes assert each member's length.
LAYOUT = [
    ("dkj.5b",   0x0000, 0x2000),
    ("dkj.5c",   0x2000, 0x2000),
    ("dkj.5e",   0x4000, 0x2000),
    ("dkj.3p",   0x6000, 0x1000),
    ("dkj.3n",   0x7000, 0x1000),
    ("dkj.5b",   0x8000, 0x2000),  # repeat
    ("v_7c.bin", 0xA000, 0x0800),
    ("v_7c.bin", 0xA800, 0x0800),  # repeat
    ("v_7d.bin", 0xB000, 0x0800),
    ("v_7d.bin", 0xB800, 0x0800),  # repeat
    ("v_7e.bin", 0xC000, 0x0800),
    ("v_7e.bin", 0xC800, 0x0800),  # repeat
    ("v_7f.bin", 0xD000, 0x0800),
    ("v_7f.bin", 0xD800, 0x0800),  # repeat
    ("c_3h.bin", 0xE000, 0x1000),
    ("c-2e.bpr", 0xF000, 0x0100),
    ("c-2f.bpr", 0xF100, 0x0100),
    ("v-2n.bpr", 0xF200, 0x0100),
    # 0xF300-0xFFFF: empty.bin pad (all zero) -- left as zero padding.
]

# Pristine dkongjr_rom.v's program-ROM address remap, reproduced
# verbatim. Case on the flat address's bits [16:11]; applied only
# inside the 0x0000-0x5FFF program-ROM range, everything else passes
# through unchanged.
ADDR_REMAP = {
    0x02: 0x06, 0x03: 0x0B, 0x05: 0x09,
    0x06: 0x02, 0x07: 0x03, 0x09: 0x05, 0x0B: 0x07,
}


def read_arranged(src_dir):
    """Assemble the 96 KiB main image from the romset, size-checked."""
    mem = bytearray(MAIN_SIZE)
    for name, offset, size in LAYOUT:
        path = os.path.join(src_dir, name)
        with open(path, "rb") as f:
            data = f.read()
        if len(data) != size:
            sys.exit(f"error: {name}: expected {size:#x} bytes, got {len(data):#x}")
        mem[offset:offset + size] = data
    return mem


def read_wave(wave_bin):
    """Load releases/dkj_wave.bin as little-endian 16-bit words.

    The pristine download-path packs two 8-bit writes (low byte first,
    high byte second) into one 16-bit word -- reverse that here.
    """
    with open(wave_bin, "rb") as f:
        data = f.read()
    if len(data) != WAVE_SIZE:
        sys.exit(f"error: {wave_bin}: expected {WAVE_SIZE:#x} bytes, got {len(data):#x}")
    return [data[2 * i] | (data[2 * i + 1] << 8) for i in range(WAVE_WORDS)]


def check_integrity(mem, wave):
    """Gate the whole generator on build_rom.ini's recorded MD5."""
    flat = bytearray(MAIN_SIZE + WAVE_SIZE)
    flat[0:MAIN_SIZE] = mem
    for i, w in enumerate(wave):
        flat[MAIN_SIZE + 2 * i] = w & 0xFF
        flat[MAIN_SIZE + 2 * i + 1] = (w >> 8) & 0xFF
    digest = hashlib.md5(flat).hexdigest()
    if digest != IMAGE_MD5:
        sys.exit(
            f"error: combined image MD5 {digest} != recorded {IMAGE_MD5}\n"
            f"  the romset does not match releases/build_rom.ini's A.DKONGJR.ROM"
        )
    return flat


def emit(flat, vf):
    vf.write("// dkongjr_roms.v -- generated by contrib/tools/make_dkongjr_roms.py\n")
    vf.write("// ROM contents derived from the ~/roms/dkongjr.zip romset and the\n")
    vf.write("// vendored releases/dkj_wave.bin (open-source sample data).\n")
    vf.write("// Copyrighted content -- never commit or distribute this file.\n")
    vf.write("// Single drop-in replacement for src/dkongjr_rom.v (same module name\n")
    vf.write("// and ports); ROM bytes baked into BRAM at synthesis. MD5-verified\n")
    vf.write("// against build_rom.ini's recorded A.DKONGJR.ROM image.\n\n")

    vf.write("module dkongjr_rom\n(\n")
    vf.write("\tinput\t\tI_CLKA,I_CLKB,\n")
    vf.write("\tinput\t\t[17:0]I_ADDRA,\n")
    vf.write("\tinput\t\t[16:0]I_ADDRB,\n")
    vf.write("\tinput\t\t[15:0]I_ADDRC,\n")
    vf.write("\tinput\t\t[7:0]I_DA,\n")
    vf.write("\tinput\t\tI_WEA,\n")
    vf.write("\toutput\treg [7:0]O_DB,\n")
    vf.write("\toutput\treg [15:0]O_DC\n")
    vf.write(");\n\n")

    vf.write("// I_ADDRA/I_DA/I_WEA/I_CLKA are unused -- no download bus on\n")
    vf.write("// Basys3 (wrapper ties dn_addr/dn_data/dn_wr to 0).\n\n")

    vf.write(f"reg [7:0] mem [0:{MAIN_SIZE - 1}];\n")
    vf.write("initial begin\n")
    for i in range(0, MAIN_SIZE, 16):
        cells = "; ".join(f"mem[{j}] = 8'h{flat[j]:02x}" for j in range(i, min(i + 16, MAIN_SIZE)))
        vf.write(f"\t{cells};\n")
    vf.write("end\n\n")

    vf.write("// Pristine program-ROM address remap (dkongjr_rom.v W_ADDRB case),\n")
    vf.write("// reproduced verbatim.\n")
    vf.write("reg [16:0] W_ADDRB;\n")
    vf.write("always @(*) begin\n")
    vf.write("\tcase(I_ADDRB[16:11])\n")
    for src, dst in sorted(ADDR_REMAP.items()):
        vf.write(f"\t\t6'h{src:02x}: W_ADDRB = {{6'h{dst:02x},I_ADDRB[10:0]}};\n")
    vf.write("\t\tdefault: W_ADDRB = I_ADDRB;\n")
    vf.write("\tendcase\n")
    vf.write("end\n\n")

    vf.write("// Registered read on I_CLKB preserves the pristine dpram pipeline.\n")
    vf.write("always @(posedge I_CLKB) O_DB <= mem[W_ADDRB];\n\n")

    vf.write(f"reg [15:0] wav_mem [0:{WAVE_WORDS - 1}];\n")
    vf.write("initial begin\n")
    wave = [flat[MAIN_SIZE + 2 * i] | (flat[MAIN_SIZE + 2 * i + 1] << 8) for i in range(WAVE_WORDS)]
    for i in range(0, WAVE_WORDS, 8):
        cells = "; ".join(f"wav_mem[{j}] = 16'h{wave[j]:04x}" for j in range(i, min(i + 8, WAVE_WORDS)))
        vf.write(f"\t{cells};\n")
    vf.write("end\n\n")
    vf.write("always @(posedge I_CLKB) O_DC <= wav_mem[I_ADDRC];\n\n")

    vf.write("endmodule\n")


def main():
    if len(sys.argv) != 4:
        sys.exit("usage: make_dkongjr_roms.py ROMS_DIR PROMS_DIR WAVE_BIN")
    src_dir, proms_dir, wave_bin = sys.argv[1], sys.argv[2], sys.argv[3]
    os.makedirs(proms_dir, exist_ok=True)

    mem = read_arranged(src_dir)
    wave = read_wave(wave_bin)
    flat = check_integrity(mem, wave)

    out = os.path.join(proms_dir, "dkongjr_roms.v")
    with open(out, "w") as vf:
        emit(flat, vf)

    print(f"wrote {out} ({MAIN_SIZE} bytes program/gfx ROM + {WAVE_WORDS} x 16-bit wave words, MD5 OK)")


if __name__ == "__main__":
    main()