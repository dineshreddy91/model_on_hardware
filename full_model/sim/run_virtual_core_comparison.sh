#!/usr/bin/env bash
# Compare actual RTL revisions on the same small graph and AXI memory model.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
baseline="${1:?Pass the baseline full_model directory}"
out="${2:?Pass an output directory}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
for revision in serial parallel; do
  source_root="$root"
  [[ "$revision" != serial ]] || source_root="$baseline"
  sources=("$source_root/rtl/openjev_fp32_pkg.sv")
  for source in "$source_root"/rtl/*.sv; do
    [[ "$source" == */openjev_fp32_pkg.sv ]] || sources+=("$source")
  done
  for latency in 0 16 64; do
    target="$out/$revision-$latency"
    python3 "$root/program/core_fixture.py" generate "$target"
    iverilog -g2012 -s tb_openjev_model_core -Ptb_openjev_model_core.READ_LATENCY="$latency" \
      -o "$target/core.vvp" "${sources[@]}" "$root/sim/tb_openjev_model_core.sv" 2> "$target/compile.log"
    vvp "$target/core.vvp" "+directory=$target" > "$target/simulation.log"
    python3 "$root/program/core_fixture.py" check "$target" > "$target/comparison.log"
  done
done
for latency in 0 16 64; do
  cmp "$out/serial-$latency/results.txt" "$out/parallel-$latency/results.txt"
  cmp "$out/serial-$latency/trace.txt" "$out/parallel-$latency/trace.txt"
  cat "$out/serial-$latency/simulation.log" "$out/parallel-$latency/simulation.log"
done
python3 "$root/tools/check_virtual_core.py" "$out"
