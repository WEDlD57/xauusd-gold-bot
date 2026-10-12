#!/usr/bin/env python3
"""Run production-core invariants and evaluator tests; not a MetaEditor compile."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
subprocess.run([sys.executable, "-m", "unittest", "discover", "-s", "tests", "-v"],
               cwd=root, check=True)
compiler = shutil.which("g++") or shutil.which("clang++")
if not compiler:
    raise SystemExit("Install g++ or clang++ to run the production .mqh core checks")
with tempfile.TemporaryDirectory() as tmp:
    executable = Path(tmp) / "gold_core_checks"
    subprocess.run([compiler, "-std=c++17", "-O2", "-Wall", "-Wextra", "-Werror",
                    str(root / "tests" / "test_core.cpp"), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
print("Validation passed. Native MT5 compilation and market backtesting remain required.")
