import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_blue_plus_android/flutter_blue_plus_android.dart';
import 'package:flutter_blue_plus_darwin/flutter_blue_plus_darwin.dart';
import 'package:flutter_blue_plus_ohos/flutter_blue_plus_ohos.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

// Compare the preserved old getter with the actual production implementation.
// ignore: avoid_relative_lib_imports
import '../example/lib/benchmark/legacy_characteristic.dart';

final class _EmptyPlatform extends FlutterBluePlusPlatform {}

const _channel = MethodChannel('flutter_blue_plus/methods');
const _codec = StandardMethodCodec();
const _remote = DeviceIdentifier('02:00:00:00:00:01');

BluetoothCharacteristic _target(bool fused,
        {String? primary, int instance = 0}) =>
    fused
        ? BluetoothCharacteristic(
            remoteId: _remote,
            primaryServiceUuid: Guid.parse(primary),
            serviceUuid: Guid('180f'),
            characteristicUuid: Guid('2a19'),
            instanceId: instance)
        : BenchmarkLegacyCharacteristic(
            remoteId: _remote,
            primaryServiceUuid: Guid.parse(primary),
            serviceUuid: Guid('180f'),
            characteristicUuid: Guid('2a19'),
            instanceId: instance);

Map<String, Object?> _message(int sequence,
        {String? primary, Map<String, Object?>? changes}) =>
    {
      'remote_id': _remote.str,
      if (primary != null) 'primary_service_uuid': primary,
      'service_uuid': '180f',
      'characteristic_uuid': '2a19',
      'instance_id': 0,
      'value': Uint8List.fromList([sequence]),
      'success': 1,
      'error_code': 0,
      'error_string': '',
      ...?changes,
    };

Future<void> _send(Map<String, Object?> message,
    {String method = 'OnCharacteristicReceived'}) async {
  final reply = Completer<ByteData?>();
  ServicesBinding.instance.channelBuffers.push(_channel.name,
      _codec.encodeMethodCall(MethodCall(method, message)), reply.complete);
  final envelope = await reply.future.timeout(const Duration(seconds: 5));
  expect(envelope, isNotNull, reason: 'The real adapter handler must reply');
  _codec.decodeEnvelope(envelope!);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final factories = <String, FlutterBluePlusPlatform Function()>{
    'Android Dart adapter': FlutterBluePlusAndroid.new,
    'Darwin Dart adapter': FlutterBluePlusDarwin.new,
    'OHOS Dart adapter': FlutterBluePlusOhos.new,
  };

  for (final entry in factories.entries) {
    group(entry.key, () {
      late FlutterBluePlusPlatform adapter;
      FlutterBluePlusPlatform? previous;
      final subscriptions = <StreamSubscription<dynamic>>[];

      Future<void> install(FlutterBluePlusPlatform platform) async {
        FlutterBluePlusPlatform.instance = platform;
        // This public adapter call installs its actual incoming message handler.
        expect(await platform.setLogLevel(BmSetLogLevelRequest()), isTrue);
      }

      setUp(() async {
        try {
          previous = FlutterBluePlusPlatform.instance;
        } on UnsupportedError {
          previous = null;
        }
        binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel,
            (call) async {
          if (call.method == 'setLogLevel') return true;
          throw StateError('Unexpected native call: ${call.method}');
        });
        adapter = entry.value();
        await install(adapter);
      });

      tearDown(() async {
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
        subscriptions.clear();
        _channel.setMethodCallHandler(null);
        binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
        FlutterBluePlusPlatform.instance = previous ?? _EmptyPlatform();
      });

      for (final primary in <String?>[null, '1800']) {
        test('decoded identity and all matching fields, primary=$primary',
            () async {
          final observed = <BmCharacteristicData>[];
          final baseline = <List<int>>[], fused = <List<int>>[];
          subscriptions
              .add(adapter.onCharacteristicReceived.listen(observed.add));
          subscriptions.add(_target(false, primary: primary)
              .onValueReceived
              .listen(baseline.add));
          subscriptions.add(_target(true, primary: primary)
              .onValueReceived
              .listen(fused.add));
          await _send(_message(1, primary: primary));
          final mismatches = <Map<String, Object?>>[
            {'remote_id': 'other-device'},
            {'primary_service_uuid': primary == null ? '1800' : null},
            {'service_uuid': '180a'},
            {'characteristic_uuid': '2a00'},
            {'instance_id': 1},
            {'success': 0, 'error_code': 7, 'error_string': 'failure'},
          ];
          for (final mismatch in mismatches) {
            await _send(_message(2, primary: primary, changes: mismatch));
          }
          await _send(_message(3, primary: primary, changes: {
            'service_uuid': '0000180f-0000-1000-8000-00805f9b34fb',
            'characteristic_uuid': '00002a19-0000-1000-8000-00805f9b34fb',
          }));
          expect(observed, hasLength(8));
          expect(baseline, [
            [1],
            [3]
          ]);
          expect(fused, baseline);
          expect(identical(baseline.first, observed.first.value), isTrue);
          expect(identical(fused.first, observed.first.value), isTrue);
          expect(observed.first.value, isA<Uint8List>());
        });
      }

      test('64 duplicate-instance listeners and public observer', () async {
        final baseline = List<int>.filled(64, 0),
            fused = List<int>.filled(64, 0);
        var allEvents = 0;
        subscriptions.add(FlutterBluePlus.events.onCharacteristicReceived
            .listen((_) => allEvents++));
        for (var i = 0; i < 64; i++) {
          subscriptions.add(_target(false, instance: i)
              .onValueReceived
              .listen((_) => baseline[i]++));
          subscriptions.add(_target(true, instance: i)
              .onValueReceived
              .listen((_) => fused[i]++));
        }
        for (var i = 0; i < 64; i++) {
          await _send(_message(i, changes: {'instance_id': i}));
        }
        await _send(_message(0, changes: {'success': 0}));
        await _send(_message(0, changes: {'remote_id': 'other-device'}));
        expect(baseline, List<int>.filled(64, 1));
        expect(fused, baseline);
        expect(allEvents, 66,
            reason:
                'Filtered listeners must not consume or suppress global events');
      });

      for (final candidate in [false, true]) {
        test('pause/cancel/resubscribe, candidate=$candidate', () async {
          final stream = _target(candidate).onValueReceived;
          expect(stream.isBroadcast, isTrue);
          final first = <List<int>>[], second = <List<int>>[];
          final a = stream.listen(first.add), b = stream.listen(second.add);
          subscriptions.addAll([a, b]);
          await _send(_message(1));
          a.pause();
          await _send(_message(2));
          expect(first, [
            [1]
          ]);
          expect(second, [
            [1],
            [2]
          ]);
          a.resume();
          await Future<void>.delayed(Duration.zero);
          expect(first, second);
          await a.cancel();
          await _send(_message(3));
          expect(first, [
            [1],
            [2]
          ]);
          expect(second, [
            [1],
            [2],
            [3]
          ]);
          await b.cancel();
          await _send(_message(4));
          final later = <List<int>>[];
          subscriptions.add(stream.listen(later.add));
          await Future<void>.delayed(Duration.zero);
          expect(later, isEmpty);
          await _send(_message(5));
          expect(later, [
            [5]
          ]);
        });

        test('lastValueStream coexistence, candidate=$candidate', () async {
          final characteristic = _target(candidate);
          final received = <List<int>>[], lastValues = <List<int>>[];
          subscriptions
              .add(characteristic.onValueReceived.listen(received.add));
          subscriptions
              .add(characteristic.lastValueStream.listen(lastValues.add));
          await Future<void>.delayed(Duration.zero);
          expect(received, isEmpty);
          expect(lastValues, [<int>[]]);
          await _send(_message(1), method: 'OnCharacteristicWritten');
          await _send(_message(2));
          await _send(_message(3, changes: {'success': 0}));
          expect(received, [
            [2]
          ]);
          expect(lastValues, [
            <int>[],
            [1],
            [2]
          ]);
        });

        test('getter binds platform at access time, candidate=$candidate',
            () async {
          final characteristic = _target(candidate);
          final oldValues = <List<int>>[], newValues = <List<int>>[];
          subscriptions
              .add(characteristic.onValueReceived.listen(oldValues.add));
          final replacement = entry.value();
          await install(replacement);
          subscriptions
              .add(characteristic.onValueReceived.listen(newValues.add));
          await _send(_message(1));
          expect(oldValues, isEmpty);
          expect(newValues, [
            [1]
          ]);
          await install(adapter);
          await _send(_message(2));
          expect(oldValues, [
            [2]
          ]);
          expect(newValues, [
            [1]
          ]);
        });
      }

      test('bounded bursts preserve order through subscription churn',
          () async {
        final counts = [0, 0];
        var unexpected = 0;
        for (var variant = 0; variant < 2; variant++) {
          final index = variant;
          subscriptions
              .add(_target(variant == 1).onValueReceived.listen((value) {
            final sequence =
                value[0] | value[1] << 8 | value[2] << 16 | value[3] << 24;
            expect(sequence, counts[index]);
            counts[index]++;
          }));
          for (var instance = 1; instance < 16; instance++) {
            subscriptions.add(_target(variant == 1, instance: instance)
                .onValueReceived
                .listen((_) => unexpected++));
          }
        }
        var temporaryCount = 0;
        for (var offset = 0; offset < 4096; offset += 32) {
          final before = temporaryCount;
          final temporary =
              _target(true).onValueReceived.listen((_) => temporaryCount++);
          try {
            await Future.wait(List.generate(32, (index) {
              final sequence = offset + index;
              return _send(_message(0, changes: {
                'value': Uint8List.fromList([
                  sequence & 255,
                  sequence >> 8 & 255,
                  sequence >> 16 & 255,
                  sequence >> 24 & 255,
                ]),
              }));
            }));
            expect(temporaryCount - before, 32);
          } finally {
            await temporary.cancel();
          }
        }
        expect(counts, [4096, 4096]);
        expect(temporaryCount, 4096);
        expect(unexpected, 0);
      });

      test('malformed envelope errors and subsequent valid event', () async {
        final baseline = <List<int>>[], fused = <List<int>>[];
        subscriptions.add(_target(false).onValueReceived.listen(baseline.add));
        subscriptions.add(_target(true).onValueReceived.listen(fused.add));
        await expectLater(_send(_message(1, changes: {'value': 'invalid'})),
            throwsA(isA<PlatformException>()));
        expect(baseline, isEmpty);
        expect(fused, isEmpty);
        await _send(_message(2));
        expect(baseline, [
          [2]
        ]);
        expect(fused, baseline);
      });
    });
  }
}
