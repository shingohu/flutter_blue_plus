"""Compile the real iOS permission decisions against a fake OS boundary on macOS."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parent
manager = root.parent.parent / 'ios/Classes/FlutterBluePlusPermissionManager.swift'
with tempfile.TemporaryDirectory(prefix='fbp-ios-permission-') as task_dir:
    work = Path(task_dir)
    # UIKit is unused by the manager; CoreBluetooth enums remain the actual SDK types.
    (work / 'Manager.swift').write_text(manager.read_text().replace('import UIKit', 'import Foundation'))
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(work / 'modules'),
                    str(root / 'support.swift'), str(work / 'Manager.swift'), str(root / 'main.swift'),
                    '-o', str(work / 'check')], check=True)
    subprocess.run([str(work / 'check')], check=True)
