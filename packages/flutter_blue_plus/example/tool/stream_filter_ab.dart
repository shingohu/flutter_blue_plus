import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

// Standalone SDK probe: use repository types without changing app dependencies.
// ignore: avoid_relative_lib_imports
import '../../../flutter_blue_plus_platform_interface/lib/flutter_blue_plus_platform_interface.dart';

// Prototype only. Neither pipeline is installed into the production plugin.
class Target {
  final DeviceIdentifier remoteId;
  final Guid? primaryServiceUuid;
  final Guid serviceUuid;
  final Guid characteristicUuid;
  final int instanceId;

  Target(
      {String remote = '02:00:00:00:00:01',
      String? primary,
      String service = '180f',
      String characteristic = '2a19',
      this.instanceId = 0})
      : remoteId = DeviceIdentifier(remote),
        primaryServiceUuid = Guid.parse(primary),
        serviceUuid = Guid(service),
        characteristicUuid = Guid(characteristic);

  Stream<List<int>> filter(Stream<BmCharacteristicData> source, bool fused) {
    if (fused) {
      return source
          .where((p) =>
              p.remoteId == remoteId &&
              p.primaryServiceUuid == primaryServiceUuid &&
              p.serviceUuid == serviceUuid &&
              p.characteristicUuid == characteristicUuid &&
              p.instanceId == instanceId &&
              p.success == true)
          .map((p) => p.value);
    }
    return source
        .where((p) => p.remoteId == remoteId)
        .where((p) => p.primaryServiceUuid == primaryServiceUuid)
        .where((p) => p.serviceUuid == serviceUuid)
        .where((p) => p.characteristicUuid == characteristicUuid)
        .where((p) => p.instanceId == instanceId)
        .where((p) => p.success == true)
        .map((c) => c.value);
  }
}

BmCharacteristicData event(int sequence,
        {String remote = '02:00:00:00:00:01',
        String? primary,
        String service = '180f',
        String characteristic = '2a19',
        int instance = 0,
        bool success = true}) =>
    BmCharacteristicData(
        remoteId: DeviceIdentifier(remote),
        primaryServiceUuid: Guid.parse(primary),
        serviceUuid: Guid(service),
        characteristicUuid: Guid(characteristic),
        instanceId: instance,
        value: Uint8List.fromList([sequence & 255]),
        success: success,
        errorCode: success ? 0 : 1,
        errorString: 'fixture');

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> drain() => Future<void>.delayed(Duration.zero);

Future<int> verify() async {
  // The fused implementation is now production; retain the old baseline here.
  final source = await File.fromUri(
          Uri.base.resolve('../lib/src/bluetooth_characteristic.dart'))
      .readAsString();
  final start = source.indexOf('Stream<List<int>> get onValueReceived =>');
  check(start >= 0, 'Production getter not found');
  final body = source.substring(start, source.indexOf(';', start));
  final compact = body.replaceAll(RegExp(r'\s+'), '');
  check(
      compact ==
          'Stream<List<int>>getonValueReceived=>'
              'FlutterBluePlusPlatform.instance.onCharacteristicReceived'
              '.where((p)=>p.remoteId==remoteId&&'
              'p.primaryServiceUuid==primaryServiceUuid&&'
              'p.serviceUuid==serviceUuid&&'
              'p.characteristicUuid==characteristicUuid&&'
              'p.instanceId==instanceId&&p.success==true)'
              '.map((c)=>c.value)',
      'Production fused getter changed');
  var checks = 1;
  for (final fused in [false, true]) {
    for (final sync in [false, true]) {
      for (final primary in <String?>[null, '1800']) {
        final controller =
            StreamController<BmCharacteristicData>.broadcast(sync: sync);
        final target = Target(primary: primary);
        final stream = target.filter(controller.stream, fused);
        check(stream.isBroadcast, 'Broadcast semantics lost');
        final seen = <List<int>>[];
        final errors = <Object>[];
        final stacks = <StackTrace>[];
        final closed = Completer<void>();
        final subscription =
            stream.listen(seen.add, onError: (Object e, StackTrace s) {
          errors.add(e);
          stacks.add(s);
        }, onDone: closed.complete);
        var secondaryCount = 0;
        final secondary =
            stream.listen((_) => secondaryCount++, onError: (Object _) {});
        final accepted = event(1,
            primary: primary, service: '0000180f-0000-1000-8000-00805f9b34fb');
        controller.add(accepted);
        controller.add(event(2, primary: primary, remote: 'other-device'));
        controller.add(event(3, primary: primary == null ? '1800' : null));
        controller.add(event(4, primary: primary, service: '180a'));
        controller.add(event(5, primary: primary, characteristic: '2a00'));
        controller.add(event(6, primary: primary, instance: 1));
        controller.add(event(7, primary: primary, success: false));
        final error = StateError('source error');
        final stack = StackTrace.current;
        controller.addError(error, stack);
        await drain();
        check(seen.length == 1 && identical(seen.single, accepted.value),
            'Matching/payload identity');
        check(
            errors.length == 1 &&
                identical(errors.single, error) &&
                identical(stacks.single, stack),
            'Error/stack forwarding');
        check(secondaryCount == 1, 'Multiple listeners');
        subscription.pause();
        controller.add(event(8, primary: primary));
        await drain();
        check(seen.length == 1 && secondaryCount == 2, 'Independent pause');
        subscription.resume();
        await drain();
        check(seen.length == 2 && seen.last.single == 8, 'Resume/order');
        await secondary.cancel();
        controller.add(event(9, primary: primary));
        await controller.close();
        await closed.future;
        check(seen.length == 3 && seen.last.single == 9 && secondaryCount == 2,
            'Cancel/close/order');
        await subscription.cancel();

        final lifecycle =
            StreamController<BmCharacteristicData>.broadcast(sync: sync);
        final filtered = target.filter(lifecycle.stream, fused);
        final stopped = filtered.listen(
            (_) => throw StateError('Cancelled listener'),
            onError: (Object _) {},
            cancelOnError: true);
        lifecycle.addError(StateError('cancelOnError'));
        await drain();
        check(!lifecycle.hasListener, 'cancelOnError did not detach');
        await stopped.cancel();
        lifecycle.add(event(10, primary: primary));
        var replayed = 0;
        final restarted = filtered.listen((_) => replayed++);
        await drain();
        check(replayed == 0, 'Unexpected replay');
        lifecycle.add(event(11, primary: primary));
        await drain();
        check(replayed == 1, 'Resubscribe');
        await restarted.cancel();
        await lifecycle.close();
        checks += 10;
      }
    }
  }
  return checks;
}

Future<Map<String, Object>> measure(
    bool fused, int listeners, String scenario, int events, int round) async {
  final controller = StreamController<BmCharacteristicData>.broadcast();
  final received = List<int>.filled(listeners, 0);
  final subscriptions = <StreamSubscription<List<int>>>[];
  final targets = List.generate(
      listeners,
      (i) => Target(
          remote: scenario == 'early_miss' && i != listeners - 1
              ? 'other-$i'
              : '02:00:00:00:00:01',
          instanceId:
              scenario == 'late_miss' && i != listeners - 1 ? i + 1 : 0));
  final setup = Stopwatch()..start();
  for (var i = 0; i < listeners; i++) {
    subscriptions
        .add(targets[i].filter(controller.stream, fused).listen((value) {
      check(value.single == (received[i] & 255), 'Sequence mismatch');
      received[i]++;
    }));
  }
  setup.stop();
  // Prebuild actual message objects; payload construction is outside timing.
  final messages = List.generate(events, (i) => event(i));
  final watch = Stopwatch()..start();
  for (var offset = 0; offset < events; offset += 128) {
    for (var i = offset; i < min(offset + 128, events); i++) {
      controller.add(messages[i]);
    }
    await drain();
  }
  watch.stop();
  for (var i = 0; i < listeners; i++) {
    check(
        received[i] ==
            (scenario == 'all_match' || i == listeners - 1 ? events : 0),
        'Incorrect delivery count');
    await subscriptions[i].cancel();
  }
  await controller.close();
  return {
    'variant': fused ? 'fused' : 'baseline',
    'listeners': listeners,
    'scenario': scenario,
    'round': round,
    'events': events,
    'wall_us': watch.elapsedMicroseconds,
    'setup_us': setup.elapsedMicroseconds,
    'delivered': received.reduce((a, b) => a + b)
  };
}

double median(List<double> values) {
  final sorted = [...values]..sort();
  final middle = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[middle]
      : (sorted[middle - 1] + sorted[middle]) / 2;
}

Future<void> main(List<String> args) async {
  if (args.length == 1 && args.single == '--verify-only') {
    final checks = await verify().timeout(const Duration(seconds: 20));
    print('Correctness: $checks checks passed (no performance measurement)');
    return;
  }
  if (args.length != 1) {
    throw ArgumentError(
        'Run from example: stream_filter_ab.dart OUTPUT.json | --verify-only');
  }
  final output = File(args.single);
  check(!output.existsSync(), 'Refusing to overwrite results');
  final checks = await verify().timeout(const Duration(seconds: 20));
  print('Correctness: $checks checks passed');
  final results = <Map<String, Object>>[];
  final summaries = <Map<String, Object>>[];
  for (final listeners in [1, 16, 64]) {
    for (final scenario in ['early_miss', 'late_miss', 'all_match']) {
      for (var warmup = 0; warmup < 2; warmup++) {
        await measure(false, listeners, scenario, 512, -1);
        await measure(true, listeners, scenario, 512, -1);
      }
      final ratios = <double>[];
      final baselineTimes = <double>[];
      final fusedTimes = <double>[];
      for (var round = 0; round < 10; round++) {
        final pair = <bool, Map<String, Object>>{};
        for (final fused in round.isEven ? [false, true] : [true, false]) {
          final row = await measure(fused, listeners, scenario, 1024, round);
          results.add(row);
          pair[fused] = row;
        }
        final before = (pair[false]!['wall_us'] as int).toDouble();
        final after = (pair[true]!['wall_us'] as int).toDouble();
        baselineTimes.add(before);
        fusedTimes.add(after);
        ratios.add(after / before);
      }
      final summary = <String, Object>{
        'listeners': listeners,
        'scenario': scenario,
        'baseline_median_wall_us': median(baselineTimes),
        'fused_median_wall_us': median(fusedTimes),
        'median_paired_reduction_percent': (1 - median(ratios)) * 100,
        'improved_pairs': ratios.where((ratio) => ratio < 1).length,
        'pairs': ratios.length,
        'worst_paired_ratio': ratios.reduce(max)
      };
      summaries.add(summary);
      print(jsonEncode(summary));
    }
  }
  await output.writeAsString(const JsonEncoder.withIndent('  ').convert({
    'schema': 1,
    'utc': DateTime.now().toUtc().toIso8601String(),
    'dart': Platform.version,
    'os': Platform.operatingSystem,
    'os_version': Platform.operatingSystemVersion,
    'scope':
        'Host Dart stream microbenchmark; not MethodChannel, BLE or phone latency',
    'correctness_checks': checks,
    'events_per_run': 1024,
    'batch_size': 128,
    'timing':
        'Wall time includes asynchronous drain and validation; not per-event P95',
    'summaries': summaries,
    'results': results,
  }));
}
