"""Compile the pinned checkpoint manifest without running any model on the CPU."""
import sys
from pathlib import Path

from compiler import OpenJevCompiler
from execution import ExecutionPlan
from schema import InputProfile


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit("Usage: python compile_program.py CONFIG MANIFEST OUTPUT_DIRECTORY")
    program = OpenJevCompiler(Path(sys.argv[1]), Path(sys.argv[2])).compile(InputProfile())
    plan = ExecutionPlan(program)
    program.write(Path(sys.argv[3]))
    plan.write(Path(sys.argv[3]))
    print(f"Compiled {len(program.instructions)} instructions; {len(program.covered_weights)} checkpoint tensors.")
    print("Compilation only. A compatible FPGA backend is required for execution.")
