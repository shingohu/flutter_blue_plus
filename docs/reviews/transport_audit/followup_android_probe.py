"""Compatibility entry point for the review reproduction, now a regression test."""
from pathlib import Path
import runpy
runpy.run_path(str(Path(__file__).resolve().parents[3] /
    "packages/flutter_blue_plus_android/test/run_callback_tests.py"), run_name="__main__")
