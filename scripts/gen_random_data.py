#!/usr/bin/env python3
"""Random 2:4-sparse / dense matmul data generator for NeuroCore.

Writes (byte-per-line, little-endian 32-bit words, same layout as the shipped files):
  <out>/sparse_data_memory.mem   576 B : A-window 256 B (compressed A 8x4 = 128 B, rest 0),
                                          B-window 256 B (8x8), meta-window 64 B (16 words, codes)
  <out>/dense_data_memory.mem    512 B : A expanded 8x8 (256 B) + B 8x8 (256 B)
  <gold>                         gold_arrays.svh (exp_sp[i] / exp_de[i], row-major C = A x B)

Usage:
  gen_random_data.py --seed N --out DIR --gold FILE [--mode small|int16|zeros|edge16|int32] [--codes 0,1,2,3,4,5]
  gen_random_data.py --check-shipped "mem files" verification/tb/gold_arrays.svh   # self-test of the layout
Mode default is chosen from the seed (seed % 4 -> small, int16, zeros, edge16) so a plain
sweep automatically mixes value styles. int32 uses full-range operands (64-bit wraparound).
"""
import argparse, os, random, re, struct, sys

# metadata_decoder.sv: 3-bit code -> (index0, index1) of the two kept elements in a group of 4
CODE2IDX = {0: (0, 1), 1: (0, 2), 2: (0, 3), 3: (1, 2), 4: (1, 3), 5: (2, 3)}

def wrap64(x):
    x &= (1 << 64) - 1
    return x - (1 << 64) if x >> 63 else x

def golden(A, B):
    return [wrap64(sum(A[i][k] * B[k][j] for k in range(8))) for i in range(8) for j in range(8)]

def pack32(vals):
    return b"".join(struct.pack("<i", v) for v in vals)

def build_images(Ac, M, B):
    # sparse image
    a_win = pack32([Ac[r][c] for r in range(8) for c in range(4)]).ljust(256, b"\0")
    b_win = pack32([B[r][c] for r in range(8) for c in range(8)]).ljust(256, b"\0")
    m_win = pack32([M[r][g] for r in range(8) for g in range(2)]).ljust(64, b"\0")
    sparse = a_win + b_win + m_win
    # dense image: expanded A + B
    A = expand(Ac, M)
    dense = pack32([A[r][c] for r in range(8) for c in range(8)]) + pack32([B[r][c] for r in range(8) for c in range(8)])
    return sparse, dense, A

def expand(Ac, M):
    A = [[0] * 8 for _ in range(8)]
    for r in range(8):
        for g in range(2):
            i0, i1 = CODE2IDX[M[r][g]]
            A[r][4 * g + i0] = Ac[r][2 * g]
            A[r][4 * g + i1] = Ac[r][2 * g + 1]
    return A

def write_mem(path, data):
    with open(path, "w") as f:
        f.write("\n".join(f"{b:02x}" for b in data) + "\n")

def write_gold(path, C):
    with open(path, "w") as f:
        f.write("initial begin\n")
        for i, v in enumerate(C):
            h = f"64'sh{v & ((1 << 64) - 1):016x}"      # 64-bit literal: values can exceed 32 bits
            f.write(f"    exp_sp[{i}]={h}; exp_de[{i}]={h};\n")
        f.write("end\n")

def read_mem(path):
    return bytes(int(x, 16) for x in open(path).read().split() if not x.startswith(("@", "//")))

def decode_images(sp, de):
    w = lambda b, i: struct.unpack_from("<i", b, i * 4)[0]
    Ac = [[w(sp, r * 4 + c) for c in range(4)] for r in range(8)]
    B = [[w(sp, 64 + r * 8 + c) for c in range(8)] for r in range(8)]
    M = [[w(sp, 128 + r * 2 + g) for g in range(2)] for r in range(8)]
    Ad = [[w(de, r * 8 + c) for c in range(8)] for r in range(8)]
    Bd = [[w(de, 64 + r * 8 + c) for c in range(8)] for r in range(8)]
    return Ac, B, M, Ad, Bd

def check(sp, de, gold_vals, label):
    Ac, B, M, Ad, Bd = decode_images(sp, de)
    A = expand(Ac, M)
    ok = (golden(A, B) == gold_vals) and (Ad == A) and (Bd == B)
    print(f"[{label}] sparse decode == golden: {golden(A, B) == gold_vals} | dense A == expanded sparse A: {Ad == A} | dense B == sparse B: {Bd == B}")
    return ok

def gold_from_svh(path):
    t = open(path).read()
    out = []
    for m in re.finditer(r"exp_sp\[\d+\]=(?:64'sh([0-9a-fA-F]+)|(-?\d+))", t):
        out.append(wrap64(int(m.group(1), 16)) if m.group(1) else int(m.group(2)))
    return out

def pick(rng, mode):
    if mode == "small":  return rng.randint(-100, 100)
    if mode == "int16":  return rng.randint(-32768, 32767)
    if mode == "zeros":  return 0 if rng.random() < 0.4 else rng.randint(-32768, 32767)
    if mode == "edge16": return rng.choice([0, 1, -1, 32767, -32768, 2, -2])
    if mode == "int32":  return rng.randint(-2**31, 2**31 - 1)
    raise SystemExit(f"unknown mode {mode}")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out"); ap.add_argument("--gold")
    ap.add_argument("--mode", default=None)
    ap.add_argument("--codes", default="0,1,2,3,4,5")
    ap.add_argument("--allow-overflow", action="store_true",
                    help="keep results that do not fit in int32 (CPU registers are 32-bit; use FMAC_READ high-word)")
    ap.add_argument("--check-shipped", nargs=2, metavar=("MEMDIR", "GOLD_SVH"))
    a = ap.parse_args()

    if a.check_shipped:
        md, gs = a.check_shipped
        ok = check(read_mem(os.path.join(md, "sparse_data_memory.mem")),
                   read_mem(os.path.join(md, "dense_data_memory.mem")), gold_from_svh(gs), "shipped data")
        sys.exit(0 if ok else 1)

    mode = a.mode or ["small", "int16", "zeros", "edge16"][a.seed % 4]
    codes = [int(c) for c in a.codes.split(",")]
    rng = random.Random(a.seed)
    while True:   # first draw is the same for a given seed; resample only if a result would not fit in int32
        Ac = [[pick(rng, mode) for _ in range(4)] for _ in range(8)]
        B = [[pick(rng, mode) for _ in range(8)] for _ in range(8)]
        M = [[rng.choice(codes) for _ in range(2)] for _ in range(8)]
        sparse, dense, A = build_images(Ac, M, B)
        C = golden(A, B)
        if a.allow_overflow or all(-2**31 <= v < 2**31 for v in C):
            break
    os.makedirs(a.out, exist_ok=True)
    write_mem(os.path.join(a.out, "sparse_data_memory.mem"), sparse)
    write_mem(os.path.join(a.out, "dense_data_memory.mem"), dense)
    write_gold(a.gold, C)
    ok = check(sparse, dense, C, f"seed {a.seed} {mode}")   # round-trip self-check of what was just written
    hist = [sum(1 for r in M for m in r if m == c) for c in range(6)]
    ovf = [i for i, v in enumerate(C) if not -2**31 <= v < 2**31]
    print(f"GEN seed={a.seed} mode={mode} META_HIST={hist} GOLD0={C[0]} OVERFLOW_IDX={ovf}")
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main()