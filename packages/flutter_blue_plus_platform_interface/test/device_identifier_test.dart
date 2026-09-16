import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DeviceIdentifier equality', () {
    test('compares identifiers by exact string value', () {
      final identifier = DeviceIdentifier(String.fromCharCodes('AA:BB:CC:DD:EE:FF'.codeUnits));
      final equalIdentifier = DeviceIdentifier(String.fromCharCodes('AA:BB:CC:DD:EE:FF'.codeUnits));

      expect(identifier, equalIdentifier);
      expect(identifier, isNot(const DeviceIdentifier('AA:BB:CC:DD:EE:FE')));
      expect(identifier, isNot(const DeviceIdentifier('AA:BB:CC:DD:EE:FF:00')));
      expect(identifier, isNot('AA:BB:CC:DD:EE:FF'));
    });

    test('remains case-sensitive', () {
      expect(
        const DeviceIdentifier('AA:BB:CC:DD:EE:FF'),
        isNot(const DeviceIdentifier('aa:bb:cc:dd:ee:ff')),
      );
    });

    test('keeps equality and hash codes consistent', () {
      final first = DeviceIdentifier(String.fromCharCodes('device-identifier'.codeUnits));
      final second = DeviceIdentifier(String.fromCharCodes('device-identifier'.codeUnits));

      expect(first, second);
      expect(first.hashCode, second.hashCode);
      expect(<DeviceIdentifier>{first, second}, hasLength(1));
    });

    test('supports empty and Unicode identifiers', () {
      expect(const DeviceIdentifier(''), const DeviceIdentifier(''));
      expect(
        const DeviceIdentifier('device-\u84dd\u7259'),
        const DeviceIdentifier('device-\u84dd\u7259'),
      );
      expect(
        const DeviceIdentifier('device-\u84dd\u7259'),
        isNot(const DeviceIdentifier('device-\u84cd\u7259')),
      );
    });
  });
}
