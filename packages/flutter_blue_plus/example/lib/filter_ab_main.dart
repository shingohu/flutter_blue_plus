import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'benchmark/legacy_characteristic.dart';
import 'perf_main.dart' show summarize;

const _channel = MethodChannel('fbp_example/performance');
const _remote = DeviceIdentifier('02:00:00:00:00:01');
const _pairs = 4;
const _lowRate = bool.fromEnvironment('FILTER_LOW_RATE');
const _count = _lowRate ? 200 : 400;
const _size = 244;
const _suite = _lowRate ? 'low-rate' : 'original';
const _reverse = bool.fromEnvironment('FILTER_REVERSE');
const _runToken = String.fromEnvironment('FILTER_RUN_TOKEN');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
      home: Scaffold(body: Center(child: Text('FBP Filter A/B')))));
  WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_run()));
}

Future<Map<String, Object?>> _events(
    bool fused, int listeners, String scenario, int pair,
    {int count = _count, int hz = 200, String targetPosition = 'last'}) async {
  final subscriptions = <StreamSubscription<dynamic>>[];
  final observerTimes = List<int>.filled(count, -1);
  final delivery = <int>[];
  var observed = 0, received = 0, errors = 0, unexpected = 0;
  final watch = Stopwatch()..start();
  int sequence(List<int> value) =>
      value[0] | value[1] << 8 | value[2] << 16 | value[3] << 24;
  subscriptions
      .add(FlutterBluePlus.events.onCharacteristicReceived.listen((event) {
    if (event.device.remoteId != _remote || event.value.length != _size) {
      errors++;
      return;
    }
    final seq = sequence(event.value);
    if (seq != observed || seq < 0 || seq >= count) {
      errors++;
      return;
    }
    observerTimes[seq] = watch.elapsedMicroseconds;
    observed++;
  }));
  try {
    for (var index = 0; index < listeners; index++) {
      final isTarget = index == (targetPosition == 'first' ? 0 : listeners - 1);
      final remote = !isTarget && scenario == 'early_miss'
          ? DeviceIdentifier('other-$index')
          : _remote;
      final instance = !isTarget && scenario == 'late_miss' ? index + 1 : 0;
      final characteristic = fused
          ? BluetoothCharacteristic(
              remoteId: remote,
              serviceUuid: Guid('180f'),
              characteristicUuid: Guid('2a19'),
              instanceId: instance)
          : BenchmarkLegacyCharacteristic(
              remoteId: remote,
              serviceUuid: Guid('180f'),
              characteristicUuid: Guid('2a19'),
              instanceId: instance);
      subscriptions.add(characteristic.onValueReceived.listen((value) {
        final now = watch.elapsedMicroseconds;
        if (!isTarget) {
          unexpected++;
          return;
        }
        if (value.length != _size) {
          errors++;
          return;
        }
        final seq = sequence(value);
        if (seq != received ||
            seq < 0 ||
            seq >= count ||
            observerTimes[seq] < 0) {
          errors++;
          return;
        }
        delivery.add(now - observerTimes[seq]);
        received++;
        for (var i = 4; i < value.length; i++) {
          if (value[i] != i % 251) {
            errors++;
            break;
          }
        }
      }));
    }
    final response =
        (await _channel.invokeMapMethod<String, dynamic>('events', {
      'plugin': true,
      'size': _size,
      'hz': hz,
      'count': count,
    }).timeout(const Duration(seconds: 20)))!;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final rtts = (response['native_rtt_us'] as List).cast<num>();
    final intervals = (response['native_interval_us'] as List).cast<num>();
    if (observed != count ||
        received != count ||
        errors != 0 ||
        unexpected != 0 ||
        response['sent'] != count ||
        response['replies'] != count ||
        response['errors'] != 0 ||
        rtts.length != count ||
        intervals.length != count - 1) {
      throw StateError(
          'Invalid events: observed=$observed received=$received errors=$errors unexpected=$unexpected '
          'sent=${response['sent']} replies=${response['replies']} nativeErrors=${response['errors']}');
    }
    return {
      'run_token': _runToken,
      'variant': fused ? 'fused' : 'baseline',
      'listeners': listeners,
      'scenario': scenario,
      'pair': pair,
      'count': count,
      'size': _size,
      'hz': hz,
      'target_position': targetPosition,
      'target_index': targetPosition == 'first' ? 0 : listeners - 1,
      'received': received,
      'observed': observed,
      'validation_errors': errors,
      'unexpected': unexpected,
      'sent': response['sent'],
      'replies': response['replies'],
      'native_errors': response['errors'],
      'observer_to_filtered_us': delivery,
      'native_rtt_us': rtts,
      'native_interval_us': intervals,
      'delivery_stats_us': summarize(delivery),
      'native_rtt_stats_us': summarize(rtts),
      'actual_hz': intervals.length * 1e6 / intervals.reduce((a, b) => a + b),
    };
  } finally {
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    await _channel.invokeMethod<void>('stop');
  }
}

Future<void> _run() async {
  final record = <String, Object?>{
    'schema': _lowRate ? 2 : 1,
    'suite': _suite,
    'run_token': _runToken,
    'pid': pid,
    'started_utc': DateTime.now().toUtc().toIso8601String(),
    'mode': kProfileMode
        ? 'profile'
        : kReleaseMode
            ? 'release'
            : 'debug',
    'dart_version': Platform.version,
    'os_version': Platform.operatingSystemVersion,
    'pairs': _pairs,
    'count': _count,
    'reverse': _reverse,
    'scope':
        'OHOS simulated native events through production Dart handler; legacy subclass versus production fused getter',
  };
  final results = <Map<String, Object?>>[];
  record['results'] = results;
  try {
    if (!kProfileMode) {
      throw StateError('This experiment requires profile mode');
    }
    await FlutterBluePlus.setLogLevel(LogLevel.none, color: false);
    await Future<void>.delayed(const Duration(seconds: 3));
    record['memory_before'] =
        await _channel.invokeMapMethod<String, dynamic>('memoryDetailed');
    for (final hz in _lowRate ? [50, 100] : [200]) {
      for (final fused in [false, true]) {
        await _events(fused, 64, 'late_miss', -1, count: 100, hz: hz);
      }
    }
    for (var pair = 0; pair < _pairs; pair++) {
      final conditions = _lowRate
          ? [
              for (final hz in [50, 100]) ...[
                (1, 'late_miss', hz, 'first'),
                (64, 'early_miss', hz, 'first'),
                (64, 'early_miss', hz, 'last'),
                (64, 'late_miss', hz, 'first'),
                (64, 'late_miss', hz, 'last'),
              ]
            ]
          : [
              (1, 'late_miss', 200, 'last'),
              (16, 'late_miss', 200, 'last'),
              (64, 'late_miss', 200, 'last'),
              (64, 'early_miss', 200, 'last'),
            ];
      final reverse = pair.isOdd != _reverse;
      for (final condition in reverse ? conditions.reversed : conditions) {
        for (final fused in reverse ? [true, false] : [false, true]) {
          final row = await _events(fused, condition.$1, condition.$2, pair,
              hz: condition.$3, targetPosition: condition.$4);
          results.add(row);
          final summary = Map<String, Object?>.from(row)
            ..remove('observer_to_filtered_us')
            ..remove('native_rtt_us')
            ..remove('native_interval_us');
          // ignore: avoid_print
          print('FBP_FILTER_CASE ${jsonEncode(summary)}');
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
    }
    await Future<void>.delayed(const Duration(seconds: 10));
    record['memory_after'] =
        await _channel.invokeMapMethod<String, dynamic>('memoryDetailed');
  } catch (error, stack) {
    record['failure'] = '$error\n$stack';
  } finally {
    record['finished_utc'] = DateTime.now().toUtc().toIso8601String();
    final directory = await _channel.invokeMethod<String>('filesDir');
    final file = File(
        '$directory/fbp_filter_ab_${pid}_${DateTime.now().millisecondsSinceEpoch}.json');
    await file.writeAsString(jsonEncode(record), flush: true);
    // ignore: avoid_print
    print('FBP_FILTER_DONE ${jsonEncode({
          'run_token': _runToken,
          'path': file.path,
          'pid': pid,
          'cases': results.length,
          'failure': record['failure'] != null
        })}');
  }
}
