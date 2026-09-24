#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="${1:?Pass build directory}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
sources=("$root/rtl/openjev_fp32_pkg.sv")
for source in "$root"/rtl/*.sv; do
 [[ "$source" == */openjev_fp32_pkg.sv ]] || sources+=("$source")
done
verilator --cc --exe --build -j 2 -O3 -Wno-fatal --top-module openjev_model_core \
 --Mdir "$out" -CFLAGS '-O3 -std=c++17' "${sources[@]}" "$root/sim/verilator/full_model.cpp"
