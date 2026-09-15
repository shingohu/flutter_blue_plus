import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

const _control = MethodChannel('fbp_example/performance');
const _case = String.fromEnvironment('MEMORY_CASE', defaultValue: 'idle');
const _size = 244;
const _hz = 200;
const _batch = 200;
const _cycles = int.fromEnvironment('MEMORY_CYCLES', defaultValue: 2);
const _operationsPerCycle = int.fromEnvironment('MEMORY_OPERATIONS');
const _captureCheckpoints = bool.fromEnvironment('MEMORY_CHECKPOINTS');
const _activeSeconds = 20;
const _recoverySeconds = 20;
final _phase = ValueNotifier<String>('ready');
final _clock = Stopwatch();
bool _started = false;
bool _prepared = false;
bool _finished = false;
String? _failure;
int _cycle = 0;
int _operations = 0;
int _errors = 0;
int _batchReceived = 0;
StreamSubscription<List<int>>? _subscription;
final _checkpoints = <Map<String, dynamic>>[];

Future<Map<String, dynamic>> _snapshot() async {
  final native =
      await _control.invokeMapMethod<String, dynamic>('memoryDetailed');
  return {
    'case': _case,
    'phase': _phase.value,
    'cycle': _cycle,
    'elapsed_us': _clock.elapsedMicroseconds,
    'pid': pid,
    'operations': _operations,
    'errors': _errors,
    'finished': _finished,
    'failure': _failure,
    'native': native,
  };
}

Future<void> _checkpoint(String name) async {
  if (!_captureCheckpoints) return;
  final sample = await _snapshot();
  sample['checkpoint'] = name;
  _checkpoints.add(sample);
  // A bounded number of checkpoints, identical in both sampling modes.
  // ignore: avoid_print
  print('FBP_MEMORY_CHECKPOINT ${jsonEncode(sample)}');
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  registerExtension('ext.fbp.memoryPrepare', (_, __) async {
    await _prepare();
    return ServiceExtensionResponse.result(jsonEncode({'prepared': true}));
  });
  registerExtension('ext.fbp.arkHeapSnapshot', (_, __) async {
    final path = await _control.invokeMethod<String>('arkHeapSnapshot');
    return ServiceExtensionResponse.result(jsonEncode({'path': path}));
  });
  registerExtension('ext.fbp.memorySnapshot', (_, __) async {
    final sample = await _snapshot();
    sample['config'] = {
      'cycles': _cycles,
      'operations_per_cycle': _operationsPerCycle,
      'checkpoints': _captureCheckpoints,
    };
    if (_captureCheckpoints) sample['checkpoints'] = _checkpoints;
    return ServiceExtensionResponse.result(jsonEncode(sample));
  });
  registerExtension('ext.fbp.memoryStart', (_, __) async {
    if (_started) {
      return ServiceExtensionResponse.error(-32000, 'Already started');
    }
    _started = true;
    unawaited(_run());
    return ServiceExtensionResponse.result(jsonEncode({'started': true}));
  });
  runApp(MaterialApp(
      home: Scaffold(
    appBar: AppBar(title: const Text('FBP Memory')),
    body: Padding(
        padding: const EdgeInsets.all(24),
        child: ValueListenableBuilder<String>(
          valueListenable: _phase,
          builder: (context, phase, _) => Text(
              '$_case\n$phase\nCycle $_cycle / $_cycles\n$_operations operations',
              style: Theme.of(context).textTheme.titleMedium),
        )),
  )));
}

void _setPhase(String phase) {
  _phase.value = phase;
  // ignore: avoid_print
  print('FBP_MEMORY_PHASE $_case $phase cycle=$_cycle operations=$_operations');
}

void _receive(List<int> value) {
  if (value.length != _size) {
    _errors++;
    return;
  }
  final seq = value[0] | value[1] << 8 | value[2] << 16 | value[3] << 24;
  if (seq != _batchReceived) _errors++;
  _batchReceived++;
  _operations++;
  for (var i = 4; i < value.length; i++) {
    if (value[i] != i % 251) {
      _errors++;
      break;
    }
  }
}

Future<void> _load() async {
  final until = _clock.elapsedMicroseconds + _activeSeconds * 1000000;
  final target = _operations + _operationsPerCycle;
  if (_case == 'idle') {
    await Future<void>.delayed(const Duration(seconds: _activeSeconds));
    return;
  }
  if (_case.startsWith('echo')) {
    final size = _case == 'echo' ? _size : 4096;
    final bytes = Uint8List.fromList(List.generate(size, (i) => i % 251));
    final List<int> value = _case == 'echo_large_list'
        ? List<int>.of(bytes, growable: false)
        : bytes;
    final payload = <String, Object>{
      'remote_id': '02:00:00:00:00:01',
      'service_uuid': '180f',
      'characteristic_uuid': '2a19',
      'instance_id': 0,
      'value': value,
      'write_type': 1,
    };
    while (_operationsPerCycle > 0
        ? _operations < target
        : _clock.elapsedMicroseconds < until) {
      final started = _clock.elapsedMicroseconds;
      final reply =
          await _control.invokeMapMethod<String, dynamic>('echo', payload);
      if (!listEquals<Object?>(reply?['value'] as List<Object?>?, bytes)) {
        _errors++;
      }
      _operations++;
      final wait = 1000000 ~/ _hz - (_clock.elapsedMicroseconds - started);
      if (wait > 0) await Future<void>.delayed(Duration(microseconds: wait));
    }
  } else {
    while (_clock.elapsedMicroseconds < until) {
      _batchReceived = 0;
      final result =
          (await _control.invokeMapMethod<String, dynamic>('events', {
        'plugin': _case == 'plugin',
        'size': _size,
        'hz': _hz,
        'count': _batch,
        'retain_samples': false,
      }).timeout(const Duration(seconds: 15)))!;
      await Future<void>.delayed(Duration.zero);
      if (result['sent'] != _batch ||
          result['replies'] != _batch ||
          result['errors'] != 0 ||
          _batchReceived != _batch) {
        _errors++;
      }
    }
  }
  if (_errors != 0) throw StateError('$_errors validation errors');
}

Future<void> _run() async {
  _clock.start();
  try {
    if (_cycles < 1 ||
        _cycles > 20 ||
        _operationsPerCycle < 0 ||
        _operationsPerCycle > 100000 ||
        (_operationsPerCycle > 0 && !_case.startsWith('echo'))) {
      throw ArgumentError('Invalid cycles or operation count');
    }
    if (![
      'idle',
      'echo',
      'raw',
      'plugin',
      'echo_large_bytes',
      'echo_large_list'
    ].contains(_case)) {
      throw ArgumentError('Unknown case: $_case');
    }
    await _prepare();
    if (_case == 'plugin') {
      _subscription = BluetoothCharacteristic(
        remoteId: const DeviceIdentifier('02:00:00:00:00:01'),
        serviceUuid: Guid('180f'),
        characteristicUuid: Guid('2a19'),
      ).onValueReceived.listen(_receive);
    } else if (_case == 'raw') {
      _control.setMethodCallHandler((call) async {
        if (call.method != 'sample') throw MissingPluginException(call.method);
        _receive((call.arguments as Map)['value'] as Uint8List);
        return null;
      });
    }
    _setPhase('baseline');
    await Future<void>.delayed(const Duration(seconds: 10));
    await _checkpoint('baseline');
    for (_cycle = 1; _cycle <= _cycles; _cycle++) {
      _setPhase('load');
      await _load();
      await _checkpoint('load_end');
      _setPhase('recovery');
      await Future<void>.delayed(const Duration(seconds: _recoverySeconds));
      await _checkpoint('recovery_end');
    }
    _cycle = _cycles;
    await _subscription?.cancel();
    _subscription = null;
    _control.setMethodCallHandler(null);
    await _control.invokeMethod<void>('stop');
    _setPhase('cooldown');
    await Future<void>.delayed(const Duration(seconds: 20));
    _setPhase('complete');
    await _checkpoint('complete');
  } catch (error, stack) {
    _failure = '$error\n$stack';
    _setPhase('failed');
  } finally {
    await _subscription?.cancel();
    _subscription = null;
    _control.setMethodCallHandler(null);
    _finished = true;
    // ignore: avoid_print
    print(
        'FBP_MEMORY_FINISHED case=$_case errors=$_errors failure=${_failure != null}');
  }
}

Future<void> _prepare() async {
  if (_prepared) return;
  await FlutterBluePlus.setLogLevel(LogLevel.none, color: false);
  _prepared = true;
}
