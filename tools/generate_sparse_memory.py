#!/usr/bin/env python3

from pathlib import Path

# ============================================================
# Sparse 8x8 memory image generator
#
# Architectural layout:
#
#   0x1000_0000 : A compressed values   (128 bytes)
#   0x1000_0100 : B dense values       (256 bytes)
#   0x1000_0200 : 2:4 metadata          (64 bytes)
#
# Total = 448 bytes
#
# The values below are copied from the already-verified
# sparse_datapath_8x8_wrapper_tb.sv test vectors.
# ============================================================

A = [
    [10, 20, 30, 40],
    [50, 60, 70, 80],
    [90, 11, 12, 13],
    [14, 15, 16, 17],
    [18, 19, 20, 21],
    [22, 23, 24, 25],
    [26, 27, 28, 29],
    [31, 32, 33, 34],
]

B = [
    [1, 2, 3, 4, 5, 6, 7, 8],
    [9, 10, 11, 12, 13, 14, 15, 16],
    [17, 18, 19, 20, 21, 22, 23, 24],
    [25, 26, 27, 28, 29, 30, 31, 32],
    [33, 34, 35, 36, 37, 38, 39, 40],
    [41, 42, 43, 44, 45, 46, 47, 48],
    [49, 50, 51, 52, 53, 54, 55, 56],
    [57, 58, 59, 60, 61, 62, 63, 64],
]

# Exact metadata used by the verified sparse TB.
META = [
    [0b010, 0b001],
    [0b011, 0b100],
    [0b010, 0b000],
    [0b011, 0b001],
    [0b001, 0b100],
    [0b011, 0b000],
    [0b000, 0b011],
    [0b011, 0b010],
]

OUTPUT = Path("mem files/sparse_data_memory.mem")


def write_u32_le(f, value):
    """Write one 32-bit word as four little-endian bytes."""
    value &= 0xFFFFFFFF

    for shift in (0, 8, 16, 24):
        f.write(f"{(value >> shift) & 0xFF:02x}\n")


def main():

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)

    word_count = 0

    with OUTPUT.open("w") as f:

        # ----------------------------------------------------
        # A compressed values
        # ----------------------------------------------------

        for row in A:
            for value in row:
                write_u32_le(f, value)
                word_count += 1

        # ----------------------------------------------------
        # B dense values
        # ----------------------------------------------------

        for row in B:
            for value in row:
                write_u32_le(f, value)
                word_count += 1

        # ----------------------------------------------------
        # 2:4 metadata
        #
        # Two metadata words per row.
        # ----------------------------------------------------

        for row in META:
            write_u32_le(f, row[0])
            write_u32_le(f, row[1])
            word_count += 2

    byte_count = word_count * 4

    print("==============================================")
    print("Sparse memory image generated")
    print("==============================================")
    print(f"Output       : {OUTPUT}")
    print(f"32-bit words : {word_count}")
    print(f"Bytes        : {byte_count}")
    print("")
    print("Memory map:")
    print("  0x10000000 : A      128 bytes")
    print("  0x10000100 : B      256 bytes")
    print("  0x10000200 : META    64 bytes")
    print("==============================================")


if __name__ == "__main__":
    main()