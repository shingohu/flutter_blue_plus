import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

const _channel = MethodChannel('fbp_example/performance');
const _remote = DeviceIdentifier('02:00:00:00:00:01');
const _repetitions = 3;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: PerformancePage()));
}

Map<String, Object> summarize(List<num> values) {
  if (values.isEmpty) return {'count': 0};
  final sorted = [...values]..sort();
  num percentile(double p) => sorted[max(0, (sorted.length * p).ceil() - 1)];
  return {
    'count': sorted.length,
    'mean': sorted.reduce((a, b) => a + b) / sorted.length,
    'p50': percentile(.5),
    'p95': percentile(.95),
    'p99': percentile(.99),
    'max': sorted.last,
  };
}

class PerformancePage extends StatefulWidget {
  const PerformancePage({super.key});
  @override
  State<PerformancePage> createState() => _PerformancePageState();
}

class _PerformancePageState extends State<PerformancePage> {
  bool _running = false;
  String _status = 'Ready';
  final List<Map<String, dynamic>> _results = [];

  @override
  void initState() {
    super.initState();
    if (const bool.fromEnvironment('PERF_AUTORUN', defaultValue: true)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _run());
    }
  }

  void _show(String message) {
    if (mounted) setState(() => _status = message);
  }

  Future<void> _record(Future<Map<String, dynamic>> Function() test) async {
    // Resource queries and UI updates stay outside the measured sample loop.
    final before = await _channel.invokeMapMethod<String, dynamic>('memory');
    final result = await test();
    result['memory_before'] = before;
    result['memory_after'] =
        await _channel.invokeMapMethod<String, dynamic>('memory');
    _results.add(result);
    final summary = Map<String, dynamic>.from(result)
      ..remove('samples_us')
      ..remove('native_rtt_us')
      ..remove('native_interval_us')
      ..remove('dart_interval_us')
      ..remove('observer_to_filtered_us');
    // One line per case, after timing has stopped.
    // ignore: avoid_print
    print('FBP_PERF_RESULT ${jsonEncode(summary)}');
  }

  Future<Map<String, dynamic>> _echo(
      String representation, int size, int concurrency, int repetition) async {
    final bytes = Uint8List.fromList(List.generate(size, (i) => i % 251));
    final Object? payload = switch (representation) {
      'null' => null,
      'list' => bytes.toList(),
      'map' => <String, Object>{
          'remote_id': _remote.str,
          'service_uuid': '180f',
          'characteristic_uuid': '2a19',
          'instance_id': 0,
          'value': bytes,
          'write_type': 1,
        },
      _ => bytes,
    };
    void validate(dynamic response) {
      if (payload == null) {
        if (response != null) throw StateError('Null echo mismatch');
      } else {
        final List<dynamic> actual =
            representation == 'map' ? response['value'] : response;
        if (!listEquals(actual, bytes)) {
          throw StateError('Echo payload mismatch');
        }
      }
    }

    for (var i = 0; i < 100; i++) {
      validate(await _channel.invokeMethod<dynamic>('echo', payload));
    }
    const count = 1000;
    final samples = <int>[];
    final clock = Stopwatch()..start();
    var next = 0;
    Future<void> worker() async {
      while (next < count) {
        next++;
        final start = clock.elapsedMicroseconds;
        final response = await _channel.invokeMethod<dynamic>('echo', payload);
        samples.add(clock.elapsedMicroseconds - start);
        validate(response);
      }
    }

    await Future.wait(List.generate(concurrency, (_) => worker()))
        .timeout(const Duration(seconds: 30));
    clock.stop();
    return {
      'kind': 'echo',
      'representation': representation,
      'size': size,
      'concurrency': concurrency,
      'repetition': repetition,
      'rtt_us': summarize(samples),
      'samples_us': samples,
      'wall_us': clock.elapsedMicroseconds,
      'operations_per_second': count * 1e6 / clock.elapsedMicroseconds,
      'payload_verified': count,
      'errors': 0,
    };
  }

  Future<Map<String, dynamic>> _events(
      bool plugin, int size, int hz, int listeners, int repetition,
      {LogLevel logLevel = LogLevel.none, bool warmup = false}) async {
    await FlutterBluePlus.setLogLevel(logLevel, color: false);
    final count = warmup ? 50 : hz * 3;
    final clock = Stopwatch()..start();
    final arrivals = <int>[];
    final delivery = <int>[];
    final observerTimes = <int, int>{};
    final seen = <int>{};
    var errors = 0;
    var unexpected = 0;
    var outOfOrder = 0;
    var lastSequence = -1;
    var previous = 0;
    final subscriptions = <StreamSubscription<dynamic>>[];
    int sequence(List<int> value) =>
        value[0] | value[1] << 8 | value[2] << 16 | value[3] << 24;
    void receive(List<int> value) {
      final arrival = clock.elapsedMicroseconds;
      if (value.length != size) {
        errors++;
        return;
      }
      final seq = sequence(value);
      if (seq < 0 || seq >= count || !seen.add(seq)) errors++;
      if (seq != lastSequence + 1) outOfOrder++;
      lastSequence = seq;
      if (previous != 0) arrivals.add(arrival - previous);
      previous = arrival;
      if (plugin) {
        final observed = observerTimes.remove(seq);
        if (observed == null) {
          errors++;
        } else {
          delivery.add(arrival - observed);
        }
      }
      for (var i = 4; i < size; i++) {
        if (value[i] != i % 251) {
          errors++;
          break;
        }
      }
    }

    if (plugin) {
      subscriptions
          .add(FlutterBluePlus.events.onCharacteristicReceived.listen((event) {
        if (event.device.remoteId != _remote) {
          unexpected++;
          return;
        }
        observerTimes[sequence(event.value)] = clock.elapsedMicroseconds;
      }));
      // Nonmatching listeners differ at instance_id, exercising all preceding filters.
      for (var i = 1; i < listeners; i++) {
        final characteristic = BluetoothCharacteristic(
            remoteId: _remote,
            serviceUuid: Guid('180f'),
            characteristicUuid: Guid('2a19'),
            instanceId: i);
        subscriptions
            .add(characteristic.onValueReceived.listen((_) => unexpected++));
      }
      final target = BluetoothCharacteristic(
          remoteId: _remote,
          serviceUuid: Guid('180f'),
          characteristicUuid: Guid('2a19'));
      subscriptions.add(target.onValueReceived.listen(receive));
    } else {
      _channel.setMethodCallHandler((call) async {
        if (call.method != 'sample') throw MissingPluginException(call.method);
        receive((call.arguments as Map)['value'] as Uint8List);
        return null;
      });
    }
    try {
      final response =
          (await _channel.invokeMapMethod<String, dynamic>('events', {
        'plugin': plugin,
        'size': size,
        'hz': hz,
        'count': count,
      }).timeout(Duration(seconds: count ~/ hz + 15)))!;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final rtts = (response['native_rtt_us'] as List).cast<num>();
      final intervals = (response['native_interval_us'] as List).cast<num>();
      return {
        'kind': plugin ? 'plugin_events' : 'raw_events',
        'size': size,
        'hz': hz,
        'listeners': listeners,
        'repetition': repetition,
        'log_level': logLevel.name,
        'expected': count,
        'received': seen.length,
        'missing': count - seen.length,
        'validation_errors': errors,
        'unexpected': unexpected,
        'out_of_order': outOfOrder,
        ...response,
        'native_handler_rtt_us': summarize(rtts),
        'native_interval_stats_us': summarize(intervals),
        'actual_send_hz': intervals.isEmpty
            ? 0
            : intervals.length * 1e6 / intervals.reduce((a, b) => a + b),
        'dart_interval_stats_us': summarize(arrivals),
        'observer_to_filtered_stats_us': summarize(delivery),
        'dart_interval_us': arrivals,
        'observer_to_filtered_us': delivery,
      };
    } finally {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      _channel.setMethodCallHandler(null);
      await _channel.invokeMethod<void>('stop');
      await FlutterBluePlus.setLogLevel(LogLevel.none, color: false);
    }
  }

  Future<void> _run() async {
    if (_running) return;
    setState(() {
      _running = true;
      _results.clear();
    });
    final started = DateTime.now().toUtc().toIso8601String();
    String? failure;
    try {
      await FlutterBluePlus.setLogLevel(LogLevel.none, color: false);
      _show('Warming up');
      await Future<void>.delayed(const Duration(seconds: 2));
      await _events(false, 244, 200, 1, 0, warmup: true);
      await _events(true, 244, 200, 1, 0, warmup: true);
      for (var repetition = 1; repetition <= _repetitions; repetition++) {
        final sizes = repetition.isEven
            ? [4096, 512, 244, 100, 20, 1]
            : [1, 20, 100, 244, 512, 4096];
        _show('Echo: round $repetition/$_repetitions');
        await _record(() => _echo('null', 0, 1, repetition));
        for (final size in sizes) {
          for (final representation in ['bytes', 'list', 'map']) {
            await _record(() => _echo(representation, size, 1, repetition));
          }
        }
        for (final concurrency in [4, 16]) {
          await _record(() => _echo('map', 244, concurrency, repetition));
        }
        for (final hz in [10, 50, 100, 200]) {
          for (final size in [20, 244, 512]) {
            _show('Events: $hz Hz / $size B / round $repetition');
            final modes = repetition.isEven ? [true, false] : [false, true];
            for (final plugin in modes) {
              await _record(() => _events(plugin, size, hz, 1, repetition));
            }
          }
        }
        for (final listeners in [16, 64]) {
          _show('Stream filters: $listeners listeners / round $repetition');
          await _record(() => _events(true, 244, 200, listeners, repetition));
        }
        _show('Verbose logging: round $repetition');
        await _record(() =>
            _events(true, 244, 200, 1, repetition, logLevel: LogLevel.verbose));
      }
      _show('Complete: ${_results.length} cases');
    } catch (error, stack) {
      failure = '$error\n$stack';
      _show('Failed: $error');
      // ignore: avoid_print
      print('FBP_PERF_ERROR $failure');
    } finally {
      try {
        final directory = await _channel.invokeMethod<String>('filesDir');
        final file = File(
            '$directory/fbp_performance_${kProfileMode ? 'profile' : kReleaseMode ? 'release' : 'debug'}.json');
        await file.writeAsString(
            jsonEncode({
              'schema': 1,
              'started_utc': started,
              'finished_utc': DateTime.now().toUtc().toIso8601String(),
              'mode': kProfileMode
                  ? 'profile'
                  : kReleaseMode
                      ? 'release'
                      : 'debug',
              'dart_version': Platform.version,
              'os_version': Platform.operatingSystemVersion,
              'repetitions': _repetitions,
              'failure': failure,
              'results': _results,
            }),
            flush: true);
        // ignore: avoid_print
        print(
            'FBP_PERF_DONE ${file.path} cases=${_results.length} failure=${failure != null}');
      } finally {
        if (mounted) setState(() => _running = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('FBP Performance')),
        body: Padding(
          padding: const EdgeInsets.all(20),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_status, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            if (_running) const LinearProgressIndicator(),
            const SizedBox(height: 16),
            Text('${_results.length} cases'),
            const SizedBox(height: 16),
            FilledButton.icon(
                onPressed: _running ? null : _run,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Run')),
          ]),
        ),
      );
}
