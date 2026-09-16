import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Guid equality', () {
    test('normalizes 16, 32, and 128 bit Bluetooth UUIDs', () {
      final short = Guid('180d');
      final medium = Guid('0000180d');
      final full = Guid('0000180d-0000-1000-8000-00805f9b34fb');

      expect(short, medium);
      expect(medium, full);
      expect(short.hashCode, medium.hashCode);
      expect(medium.hashCode, full.hashCode);
    });

    test('distinguishes different UUIDs', () {
      expect(Guid('180d'), isNot(Guid('180f')));
      expect(
        Guid('12345678-1234-5678-1234-567812345678'),
        isNot(Guid('12345678-1234-5678-1234-567812345679')),
      );
    });

    test('supports equivalent UUIDs as map and set keys', () {
      final values = <Guid, String>{Guid('180d'): 'heart-rate'};
      final unique = <Guid>{Guid('180d'), Guid('0000180d'), Guid('0000180d-0000-1000-8000-00805f9b34fb')};

      expect(values[Guid('0000180d-0000-1000-8000-00805f9b34fb')], 'heart-rate');
      expect(unique, hasLength(1));
    });

    test('continues to reflect mutations to public bytes', () {
      final bytes = <int>[0x18, 0x0d];
      final guid = Guid.fromBytes(bytes);

      expect(guid, Guid('180d'));
      expect(guid.str128, Guid('180d').str128);
      bytes[1] = 0x0f;
      expect(guid, Guid('180f'));
      expect(guid.hashCode, Guid('180f').hashCode);
      expect(guid.str128, Guid('180f').str128);
    });

    test('masks byte values when comparing and hashing', () {
      final outOfRange = Guid.fromBytes(<int>[0x118, -0xf3]);
      final normalized = Guid('180d');

      expect(outOfRange, normalized);
      expect(outOfRange.hashCode, normalized.hashCode);
      expect(outOfRange.str128, normalized.str128);
    });

    test('continues to reject invalid lengths after bytes are mutated', () {
      final bytes = <int>[0x18, 0x0d];
      final guid = Guid.fromBytes(bytes);
      bytes.add(0);

      expect(() => guid == guid, throwsRangeError);
      expect(() => guid.hashCode, throwsRangeError);
      expect(() => guid.str128, throwsRangeError);
    });
  });

  test('string representations remain unchanged', () {
    expect(Guid('180d').str, '180d');
    expect(Guid('0000180d').str, '180d');
    expect(Guid('0000180d-0000-1000-8000-00805f9b34fb').str, '180d');
    expect(Guid('12345678').str, '12345678');
    expect(Guid('180d').str128, '0000180d-0000-1000-8000-00805f9b34fb');
    expect(Guid('12345678').str128, '12345678-0000-1000-8000-00805f9b34fb');
    expect(Guid('0000180d-0000-1000-8000-00805f9b34fb').str128, '0000180d-0000-1000-8000-00805f9b34fb');
    expect(Guid('ABCDEFAB-CDEF-ABCD-EFAB-CDEFABCDEFAB').str128, 'abcdefab-cdef-abcd-efab-cdefabcdefab');
    expect(Guid('12345678-1234-5678-1234-567812345678').str, '12345678-1234-5678-1234-567812345678');
  });
}
