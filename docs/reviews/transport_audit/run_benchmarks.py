"""Generate a temporary standalone Dart AOT benchmark from repository sources."""
import pathlib
import shutil
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[3]
here = pathlib.Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix='fbp-transport-audit-') as tmp:
    out = pathlib.Path(tmp)
    guid = 'packages/flutter_blue_plus_platform_interface/lib/src/guid.dart'
    (out / 'old_guid.dart').write_bytes(subprocess.check_output(
        ['git', 'show', f'7013484533902f5e830ffd511e070245a098ee67:{guid}'], cwd=root))
    shutil.copy(root / guid, out / 'new_guid.dart')
    def write_mutex(source, destination):
        source = source[source.index('class _Mutex {'):source.index('// Create mutexes')]
        errors = """
enum ErrorPlatform { fbp }
enum FbpErrorCode { timeout }
class FlutterBluePlusException implements Exception {
  FlutterBluePlusException(Object a, Object b, Object c, Object d);
}
"""
        (out / destination).write_text("import 'dart:async';\nimport 'dart:collection';\n" + errors + source.replace('_Mutex', 'AuditMutex'))
    mutex_path = 'packages/flutter_blue_plus/lib/src/mutex_factory.dart'
    write_mutex((root / mutex_path).read_text(), 'mutex.dart')
    write_mutex(subprocess.check_output(['git', 'show', f'7013484533902f5e830ffd511e070245a098ee67:{mutex_path}'], cwd=root).decode(), 'old_mutex.dart')
    shutil.copy(here / 'algorithm_benchmark.dart.in', out / 'main.dart')
    subprocess.run(['dart', 'compile', 'exe', str(out / 'main.dart'), '-o', str(out / 'bench')], check=True)
    subprocess.run([str(out / 'bench')], check=True)
