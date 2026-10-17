// Codec CPU/bytes only, NOT BLE throughput or native-engine latency.
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object> event(int size, bool fullIds) => {
  'remote_id': fullIds
      ? '1E2D3C4B-5A69-7887-96A5-B4C3D2E1F001'
      : 'AA:BB:CC:DD:EE:FF',
  'service_uuid': fullIds ? '12345678-1234-5678-9abc-123456789abc' : '180f',
  'characteristic_uuid': fullIds
      ? '12345679-1234-5678-9abc-123456789abc'
      : '2a19',
  'instance_id': 0,
  'value': Uint8List(size),
  'success': 1,
  'error_code': 0,
  'error_string': 'GATT_SUCCESS',
};

int medianMicros(void Function() f) {
  for (var i = 0; i < 200; i++) {
    f();
  }
  final samples = <int>[];
  for (var r = 0; r < 7; r++) {
    final watch = Stopwatch()..start();
    for (var i = 0; i < 2000; i++) {
      f();
    }
    samples.add(watch.elapsedMicroseconds);
  }
  samples.sort();
  return samples[3];
}

void main() {
  test('codec framing, batching and CPU audit', () {
    const method = StandardMethodCodec();
    const message = StandardMessageCodec();
    for (final full in [false, true]) {
      // Legacy LiberLive event/control data can be only 3–7 bytes before its
      // own protocol framing; bulk sheet transfers also use ~490-byte chunks.
      for (final size in [3, 4, 6, 7, 20, 244, 490, 512]) {
        final data = event(size, full);
        final call = MethodCall('OnCharacteristicReceived', data);
        final encoded = method.encodeMethodCall(call);
        final compact = [
          data['remote_id'],
          data['service_uuid'],
          data['characteristic_uuid'],
          0,
          data['value'],
          1,
          0,
          'GATT_SUCCESS',
        ];
        final batch = List.generate(16, (_) => data);
        final batchCall = MethodCall('OnCharacteristicBatch', batch);
        final batched = method.encodeMethodCall(batchCall);
        final frame = ByteData(
          size + 16,
        ); // hypothetical pre-negotiated route+session+sequence header
        final encodeTime = medianMicros(() {
          method.encodeMethodCall(call);
        });
        final decodeTime = medianMicros(() {
          method.decodeMethodCall(encoded);
        });
        final batchEncodeTime = medianMicros(() {
          method.encodeMethodCall(batchCall);
        });
        expect(
          (method.decodeMethodCall(encoded).arguments as Map)['value'],
          data['value'],
        );
        print(
          'AUDIT codec ids=${full ? 'full' : 'short'} payload=$size '
          'methodBytes=${encoded.lengthInBytes} tupleBytes=${message.encodeMessage(compact)!.lengthInBytes} '
          'routeFrameBytes=${frame.lengthInBytes} batch16Bytes=${batched.lengthInBytes} '
          'encodeUsPer2000=$encodeTime decodeUsPer2000=$decodeTime '
          'batch16EncodeUsPer2000=$batchEncodeTime',
        );
      }
    }
  });
}
