#!/usr/bin/env python3
"""Multi-job image generator for NeuroCore (step 3).
Job j owns window base = 0x1000_0000 + j*0x400 : A +0x000, B +0x100, meta +0x200 (+0x300 spare).
Writes into --out : sparse_data_memory.mem, dense_data_memory.mem (byte-per-line, N*0x400 bytes)
and --gold : gold_multi.mem  ($readmemh, one 64-bit hex word per line, job-major, row-major C).
Reuses gen_random_data.py (same layout, same self-check) so single-job and multi-job cannot drift.
Usage: gen_multijob.py --jobs 32 --seed 1 --out DIR --gold FILE [--allow-overflow]
"""
import argparse, os, random, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_random_data as g

WIN = 0x400
ap = argparse.ArgumentParser()
ap.add_argument("--jobs", type=int, default=32)
ap.add_argument("--seed", type=int, default=1)
ap.add_argument("--out", required=True); ap.add_argument("--gold", required=True)
ap.add_argument("--allow-overflow", action="store_true")
a = ap.parse_args()
if not 1 <= a.jobs <= 64: sys.exit("--jobs must be 1..64 (64 KB model)")

sp_img = bytearray(a.jobs * WIN); de_img = bytearray(a.jobs * WIN)
gold = []; modes = []
for j in range(a.jobs):
    seed = a.seed * 1000 + j
    mode = ["small", "int16", "zeros", "edge16"][seed % 4]
    rng = random.Random(seed)
    while True:
        Ac = [[g.pick(rng, mode) for _ in range(4)] for _ in range(8)]
        B  = [[g.pick(rng, mode) for _ in range(8)] for _ in range(8)]
        M  = [[rng.choice(range(6)) for _ in range(2)] for _ in range(8)]
        sp, de, A = g.build_images(Ac, M, B)
        C = g.golden(A, B)
        if a.allow_overflow or all(-2**31 <= v < 2**31 for v in C): break
    if not g.check(sp, de, C, f"job {j} {mode}"): sys.exit(1)
    sp_img[j*WIN : j*WIN+len(sp)] = sp
    de_img[j*WIN : j*WIN+len(de)] = de
    gold += C; modes.append(mode)

os.makedirs(a.out, exist_ok=True)
g.write_mem(os.path.join(a.out, "sparse_data_memory.mem"), sp_img)
g.write_mem(os.path.join(a.out, "dense_data_memory.mem"), de_img)
with open(a.gold, "w") as f:
    f.write("\n".join(f"{v & (2**64-1):016x}" for v in gold) + "\n")
print(f"GENMJ jobs={a.jobs} seed={a.seed} window=0x{WIN:x} modes={sorted(set(modes))}")