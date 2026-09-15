import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('flutter_blue_plus/methods');
const _codec = StandardMethodCodec();
const _remote = DeviceIdentifier('02:00:00:00:00:71');
const _operationTimeout = Duration(seconds: 2);

BluetoothCharacteristic _target(String? primary) => BluetoothCharacteristic(
      remoteId: _remote,
      primaryServiceUuid: Guid.parse(primary),
      serviceUuid: Guid('180f'),
      characteristicUuid: Guid('2a19'),
      instanceId: 7,
    );

Map<String, Object?> _value(int value, String? primary,
        [Map<String, Object?> changes = const {}]) =>
    {
      'remote_id': _remote.str,
      if (primary != null) 'primary_service_uuid': primary,
      'service_uuid': '180f',
      'characteristic_uuid': '2a19',
      'instance_id': 7,
      'value': Uint8List.fromList([value]),
      'success': 1,
      'error_code': 0,
      'error_string': '',
      ...changes,
    };

List<Map<String, Object?>> _mismatches(String? primary) => [
      {'remote_id': 'other-device'},
      {'primary_service_uuid': primary == null ? '1800' : null},
      {'service_uuid': '180a'},
      {'characteristic_uuid': '2a00'},
      {'instance_id': 8},
    ];

Future<void> _send(String method, Map<String, Object?> arguments) async {
  final reply = Completer<ByteData?>();
  ServicesBinding.instance.channelBuffers.push(_channel.name,
      _codec.encodeMethodCall(MethodCall(method, arguments)), reply.complete);
  _codec.decodeEnvelope((await reply.future.timeout(_operationTimeout))!);
  await Future<void>.delayed(Duration.zero);
}

Future<void> _connection(bool connected) => _send('OnConnectionStateChanged', {
      'remote_id': _remote.str,
      'connection_state': connected ? 1 : 0,
    });

Future<List<int>?> _perform(
    BluetoothCharacteristic characteristic, String operation) async {
  if (operation == 'read') {
    return characteristic.read(timeout: _operationTimeout);
  }
  await characteristic.write([9, 8],
      withoutResponse: operation == 'withoutResponse',
      timeout: _operationTimeout);
  return null;
}

// Each platform entry point gets its own Flutter test isolate. The production
// library initializes its global cache listeners once, so do not swap adapters.
void characteristicOperationsSuite(
    String platform, FlutterBluePlusPlatform Function() factory) {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  Future<Object?> Function(MethodCall)? nativeReply;
  final subscriptions = <StreamSubscription<List<int>>>[];

  group(platform, () {
    setUpAll(() async {
      FlutterBluePlusPlatform.instance = factory();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel,
          (call) async {
        switch (call.method) {
          case 'flutterRestart':
            return 0;
          case 'getAdapterState':
            return {'adapter_state': BmAdapterStateEnum.on.index};
          case 'readCharacteristic':
          case 'writeCharacteristic':
          case 'readDescriptor':
          case 'writeDescriptor':
          case 'setNotifyValue':
          case 'disconnect':
            final handler = nativeReply;
            if (handler != null) return handler(call);
        }
        throw StateError('Unexpected native request: ${call.method}');
      });
      // Initializes real production connection/value cache subscriptions.
      expect(
          await FlutterBluePlus.adapterState.first, BluetoothAdapterState.on);
    });

    setUp(() async {
      nativeReply = null;
      await _connection(false);
      await _connection(true);
      expect(BluetoothDevice(remoteId: _remote).isConnected, isTrue);
    });

    tearDown(() async {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      subscriptions.clear();
      await _connection(false);
    });

    for (final primary in <String?>[null, '1800']) {
      test('lastValue cache, merged events and subscription lifecycle $primary',
          () async {
        final characteristic = _target(primary);
        await _send('OnCharacteristicReceived', _value(10, primary));
        final initial = characteristic.lastValue;
        final captured = characteristic.lastValueStream;
        await _send('OnCharacteristicWritten', _value(11, primary));
        final first = <List<int>>[], second = <List<int>>[];
        final a = captured.listen(first.add);
        final b = characteristic.lastValueStream.listen(second.add);
        subscriptions.addAll([a, b]);
        await Future<void>.delayed(Duration.zero);
        // The getter captures the initial value and immediately subscribes its
        // merge source, buffering subsequent events until the caller listens.
        expect(first, [
          [10],
          [11]
        ]);
        expect(identical(first.first, initial), isTrue);
        expect(second, [
          [11]
        ]);
        expect(identical(second.single, characteristic.lastValue), isTrue);
        a.pause();
        await _send('OnCharacteristicReceived', _value(12, primary));
        await _send('OnCharacteristicWritten', _value(13, primary));
        for (final method in [
          'OnCharacteristicReceived',
          'OnCharacteristicWritten'
        ]) {
          for (final mismatch in _mismatches(primary)) {
            await _send(method, _value(90, primary, mismatch));
          }
          await _send(method, _value(99, primary, {'success': 0}));
        }
        expect(first, [
          [10],
          [11]
        ]);
        expect(second, [
          [11],
          [12],
          [13]
        ]);
        expect(characteristic.lastValue, [13]);
        a.resume();
        await Future<void>.delayed(Duration.zero);
        expect(first, [
          [10],
          [11],
          [12],
          [13]
        ]);
        await a.cancel();
        await b.cancel();
        await _send('OnCharacteristicReceived', _value(14, primary));
        expect(first, [
          [10],
          [11],
          [12],
          [13]
        ]);
        expect(await characteristic.lastValueStream.first, [14]);
        await _connection(false);
        expect(characteristic.lastValue, isEmpty);
        expect(await characteristic.lastValueStream.first, isEmpty);
      });

      for (final operation in ['read', 'write', 'withoutResponse']) {
        test(
            '$operation matches identity, preserves errors and reuses stream $primary',
            () async {
          final characteristic = _target(primary);
          final method = operation == 'read'
              ? 'OnCharacteristicReceived'
              : 'OnCharacteristicWritten';
          var request = Completer<MethodCall>();
          nativeReply = (call) async {
            request.complete(call);
            return true;
          };
          var completed = false;
          final first = _perform(characteristic, operation);
          unawaited(first.then<void>((_) {
            completed = true;
          }, onError: (Object _, StackTrace __) {
            completed = true;
          }));
          final checked =
              expectLater(first, completion(operation == 'read' ? [41] : null));
          final call = await request.future.timeout(_operationTimeout);
          expect(
              call.method,
              operation == 'read'
                  ? 'readCharacteristic'
                  : 'writeCharacteristic');
          expect(call.arguments['instance_id'], 7);
          if (operation != 'read') {
            expect(call.arguments['value'], [9, 8]);
            expect(
                call.arguments['write_type'],
                operation == 'withoutResponse'
                    ? BmWriteType.withoutResponse.index
                    : BmWriteType.withResponse.index);
          }
          for (final mismatch in _mismatches(primary)) {
            await _send(method, _value(90, primary, mismatch));
            await _send(
                method, _value(91, primary, {...mismatch, 'success': 0}));
          }
          await _send(
              method == 'OnCharacteristicReceived'
                  ? 'OnCharacteristicWritten'
                  : 'OnCharacteristicReceived',
              _value(92, primary));
          expect(completed, isFalse,
              reason:
                  'Unrelated events and native submission ACK must not complete the operation');
          await _send(
              method,
              _value(41, primary, {
                'service_uuid': '0000180f-0000-1000-8000-00805f9b34fb',
                'characteristic_uuid': '00002a19-0000-1000-8000-00805f9b34fb',
              }));
          await checked;

          // A cached stream must not replay the previous response on reuse.
          await _send(method, _value(55, primary));
          request = Completer<MethodCall>();
          final failed = expectLater(
              _perform(characteristic, operation),
              throwsA(isA<FlutterBluePlusException>()
                  .having((e) => e.function, 'function', call.method)
                  .having((e) => e.code, 'native code', 133)
                  .having((e) => e.description, 'native message',
                      'native failure')));
          await request.future.timeout(_operationTimeout);
          await _send(
              method,
              _value(99, primary, {
                'success': 0,
                'error_code': 133,
                'error_string': 'native failure',
              }));
          await failed;

          // Failure must release the operation lock and allow another request.
          request = Completer<MethodCall>();
          final recovered = expectLater(_perform(characteristic, operation),
              completion(operation == 'read' ? [77] : null));
          await request.future.timeout(_operationTimeout);
          await _send(method, _value(77, primary));
          await recovered;
        });
      }
    }

    for (final operation in ['read', 'write']) {
      test('$operation handles response before native invocation returns',
          () async {
        nativeReply = (call) async {
          await _send(
              operation == 'read'
                  ? 'OnCharacteristicReceived'
                  : 'OnCharacteristicWritten',
              _value(41, null));
          return true;
        };
        expect(await _perform(_target(null), operation),
            operation == 'read' ? [41] : null);
      });
    }

    test('descriptor value streams preserve identity, success and cached value',
        () async {
      final descriptor = BluetoothDescriptor(
          remoteId: _remote,
          primaryServiceUuid: Guid('1800'),
          serviceUuid: Guid('180f'),
          characteristicUuid: Guid('2a19'),
          instanceId: 7,
          descriptorUuid: Guid('2901'));
      Map<String, Object?> value(int sequence,
              [Map<String, Object?> changes = const {}]) =>
          {..._value(sequence, '1800'), 'descriptor_uuid': '2901', ...changes};
      await _send('OnDescriptorRead', value(10));
      final reads = <List<int>>[], values = <List<int>>[];
      subscriptions.add(descriptor.onValueReceived.listen(reads.add));
      subscriptions.add(descriptor.lastValueStream.listen(values.add));
      await Future<void>.delayed(Duration.zero);
      expect(values, [
        [10]
      ]);
      for (final method in ['OnDescriptorRead', 'OnDescriptorWritten']) {
        for (final mismatch in [
          ..._mismatches('1800'),
          {'descriptor_uuid': '2902'}
        ]) {
          await _send(method, value(90, mismatch));
        }
        await _send(method, value(99, {'success': 0}));
      }
      await _send('OnDescriptorWritten', value(11));
      await _send('OnDescriptorRead', value(12));
      expect(reads, [
        [12]
      ]);
      expect(values, [
        [10],
        [11],
        [12]
      ]);
      expect(identical(values.last, descriptor.lastValue), isTrue);
    });

    for (final operation in [
      'readDescriptor',
      'writeDescriptor',
      'setNotifyValue'
    ]) {
      test('$operation matches descriptor identity and retains native failures',
          () async {
        final characteristic = _target('1800');
        final descriptor = BluetoothDescriptor(
            remoteId: _remote,
            primaryServiceUuid: Guid('1800'),
            serviceUuid: Guid('180f'),
            characteristicUuid: Guid('2a19'),
            instanceId: 7,
            descriptorUuid: Guid('2901'));
        final uuid = operation == 'setNotifyValue' ? '2902' : '2901';
        final method = operation == 'readDescriptor'
            ? 'OnDescriptorRead'
            : 'OnDescriptorWritten';
        Future<Object?> invoke() async {
          if (operation == 'readDescriptor') {
            return descriptor.read(timeout: _operationTimeout);
          }
          if (operation == 'setNotifyValue') {
            return characteristic.setNotifyValue(true,
                timeout: _operationTimeout);
          }
          await descriptor.write([8], timeout: _operationTimeout);
          return null;
        }

        Map<String, Object?> value(int sequence,
                [Map<String, Object?> changes = const {}]) =>
            {..._value(sequence, '1800'), 'descriptor_uuid': uuid, ...changes};
        var request = Completer<void>();
        nativeReply = (call) async {
          expect(call.method, operation);
          request.complete();
          return true;
        };
        var completed = false;
        final pending = invoke();
        unawaited(pending.then<void>((_) {
          completed = true;
        }, onError: (Object _, StackTrace __) {
          completed = true;
        }));
        final failed = expectLater(
            pending,
            throwsA(isA<FlutterBluePlusException>()
                .having((e) => e.function, 'function', operation)
                .having((e) => e.code, 'native code', 133)));
        await request.future.timeout(_operationTimeout);
        for (final mismatch in [
          ..._mismatches('1800'),
          {'descriptor_uuid': '2903'}
        ]) {
          await _send(method, value(90, mismatch));
        }
        expect(completed, isFalse);
        await _send(
            method,
            value(99,
                {'success': 0, 'error_code': 133, 'error_string': 'failure'}));
        await failed;
        request = Completer<void>();
        final recovered = expectLater(
            invoke(),
            completion(operation == 'readDescriptor'
                ? [42]
                : operation == 'setNotifyValue'
                    ? true
                    : null));
        await request.future.timeout(_operationTimeout);
        await _send(method, value(42));
        await recovered;
      });
    }

    test('disconnect waits for target device disconnected event', () async {
      final request = Completer<void>();
      nativeReply = (call) async {
        expect(call.method, 'disconnect');
        request.complete();
        return true;
      };
      var completed = false;
      final pending = BluetoothDevice(remoteId: _remote)
          .disconnect(timeout: _operationTimeout);
      unawaited(pending.then((_) {
        completed = true;
      }));
      final checked = expectLater(pending, completes);
      await request.future.timeout(_operationTimeout);
      await _connection(true);
      await _send('OnConnectionStateChanged',
          {'remote_id': 'other-device', 'connection_state': 0});
      expect(completed, isFalse);
      await _connection(false);
      await checked;
    });

    test('read then write remain serialized until matching response', () async {
      final characteristic = _target(null);
      final firstRequest = Completer<void>(), secondRequest = Completer<void>();
      final calls = <String>[];
      nativeReply = (call) async {
        calls.add(call.method);
        (calls.length == 1 ? firstRequest : secondRequest).complete();
        return true;
      };
      final read = _perform(characteristic, 'read');
      final write = _perform(characteristic, 'write');
      final checkedRead = expectLater(read, completion([41]));
      final checkedWrite = expectLater(write, completion(null));
      await firstRequest.future.timeout(_operationTimeout);
      await _send(
          'OnCharacteristicReceived', _value(90, null, {'instance_id': 8}));
      expect(calls, ['readCharacteristic']);
      await _send('OnCharacteristicReceived', _value(41, null));
      await checkedRead;
      await secondRequest.future.timeout(_operationTimeout);
      expect(calls, ['readCharacteristic', 'writeCharacteristic']);
      await _send('OnCharacteristicWritten', _value(42, null));
      await checkedWrite;
    });
  });
}
