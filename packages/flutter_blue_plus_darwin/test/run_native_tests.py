#!/usr/bin/env python3
"""Compile and run native regression tests on macOS using Flutter's cached SDK."""

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def main():
    if sys.platform != "darwin":
        raise SystemExit("Native Darwin tests require macOS and Xcode.")
    flutter = shutil.which("flutter")
    if not flutter:
        raise SystemExit("Put the Flutter SDK's bin directory on PATH first.")
    engine = Path(flutter).resolve().parent / "cache/artifacts/engine/darwin-x64"
    frameworks = list(engine.glob("FlutterMacOS.xcframework/*/FlutterMacOS.framework"))
    if not frameworks:
        raise SystemExit("FlutterMacOS framework missing; run flutter precache --macos.")
    framework_dir = frameworks[0].parent
    with tempfile.TemporaryDirectory(prefix="fbp-darwin-tests-") as output:
        binary = Path(output) / "mtu_poll_test"
        subprocess.run(
            [
                "xcrun", "clang", "-fobjc-arc", "-fmodules",
                "-F", str(framework_dir),
                "-framework", "Foundation", "-framework", "CoreBluetooth",
                "-framework", "FlutterMacOS",
                "-Wl,-rpath," + str(framework_dir),
                str(Path(__file__).with_name("mtu_poll_test.m")),
                "-o", str(binary),
            ],
            check=True,
        )
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    main()
