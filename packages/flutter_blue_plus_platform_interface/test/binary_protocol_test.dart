import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart'
    show BinaryCommand, WriteFlags, NotifyFlags, encodeResponse, decodeResponse,
        encodeWriteCharacteristic, encodeWriteDescriptor, encodeSetNotifyValue;

void main() {
  group('encodeWriteCharacteristic', () {
    ByteData encode() => encodeWriteCharacteristic(
          flags: WriteFlags.withoutResponse,
          instanceId: 3,
          remoteId: 'AA:BB:CC:DD:EE:FF',
          serviceUuid: '180d',
          characteristicUuid: '2a37',
          primaryServiceUuid: '180d',
          value: [0x01, 0x02, 0x03],
        );

    test('header: cmd, flags, instanceId', () {
      final data = encode();
      expect(data.getUint8(0), BinaryCommand.writeCharacteristic);
      expect(data.getUint8(1), WriteFlags.withoutResponse);
      expect(data.getUint16(2), 3);
    });

    test('16-bit UUIDs are sent in shortest form', () {
      final data = encode();
      final bytes = data.buffer.asUint8List();
      // cmd(1) flags(1) inst(2) = 4; remoteIdLen at 4; remoteId at 5..21; svcLen at 22
      expect(bytes[22], 4);
      expect(String.fromCharCodes(bytes.sublist(23, 27)), '180d');
    });

    test('value bytes appended after 5 strings + valueLen', () {
      final data = encode();
      final bytes = data.buffer.asUint8List();
      // 1+1+2 + (1+17) + (1+4) + (1+4) + (1+4) + (1+0) = 38; valueLen at 38
      expect(bytes[38] << 8 | bytes[39], 3);
      expect(bytes[40], 0x01);
      expect(bytes[41], 0x02);
      expect(bytes[42], 0x03);
    });

    test('empty primaryServiceUuid encodes as zero-length string', () {
      final data = encodeWriteCharacteristic(
        flags: 0,
        instanceId: 0,
        remoteId: 'AA:BB:CC:DD:EE:FF',
        serviceUuid: '180d',
        characteristicUuid: '2a37',
        primaryServiceUuid: null,
        value: [],
      );
      final bytes = data.buffer.asUint8List();
      // 1+1+2 + (1+17) + (1+4) + (1+4) = 31; primary len at 32
      expect(bytes[32], 0);
    });
  });

  group('encodeWriteDescriptor', () {
    test('includes descriptorUuid', () {
      final data = encodeWriteDescriptor(
        flags: 0,
        instanceId: 0,
        remoteId: 'AA:BB:CC:DD:EE:FF',
        serviceUuid: '180d',
        characteristicUuid: '2a37',
        primaryServiceUuid: null,
        descriptorUuid: '2902',
        value: [0x01, 0x00],
      );
      expect(data.getUint8(0), BinaryCommand.writeDescriptor);
      final bytes = data.buffer.asUint8List();
      // 1+1+2 + (1+17) + (1+4) + (1+4) + (1+0) = 32; primary len at 32; desc len at 33
      expect(bytes[33], 4);
      expect(String.fromCharCodes(bytes.sublist(34, 38)), '2902');
    });
  });

  group('encodeSetNotifyValue', () {
    test('flags carry enable', () {
      final data = encodeSetNotifyValue(
        flags: NotifyFlags.enable,
        instanceId: 1,
        remoteId: 'AA:BB:CC:DD:EE:FF',
        serviceUuid: '180d',
        characteristicUuid: '2a37',
        primaryServiceUuid: null,
      );
      expect(data.getUint8(0), BinaryCommand.setNotifyValue);
      expect(data.getUint8(1), NotifyFlags.enable);
      expect(data.getUint16(2), 1);
    });
  });

  group('decodeResponse / encodeResponse', () {
    test('success roundtrip', () {
      final data = encodeResponse(success: true);
      final result = decodeResponse(data);
      expect(result['success'], 1);
      expect(result['errorCode'], 0);
      expect(result['errorString'], '');
    });

    test('error roundtrip', () {
      final data = encodeResponse(success: false, errorCode: 4, errorString: 'write failed');
      final result = decodeResponse(data);
      expect(result['success'], 0);
      expect(result['errorCode'], 4);
      expect(result['errorString'], 'write failed');
    });
  });
}
