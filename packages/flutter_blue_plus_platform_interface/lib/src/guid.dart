// Copyright 2017-2023, Charles Weinberger
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

class Guid {
  static const List<int> _bluetoothBaseTail = [
    0x00,
    0x00,
    0x10,
    0x00,
    0x80,
    0x00,
    0x00,
    0x80,
    0x5f,
    0x9b,
    0x34,
    0xfb,
  ];

  final List<int> bytes;

  Guid.empty() : bytes = List.filled(16, 0);

  Guid.fromBytes(this.bytes) : assert(_checkLen(bytes.length), 'GUID must be 16, 32, or 128 bit.');

  Guid.fromString(String input) : bytes = _toBytes(input);

  Guid(String input) : bytes = _toBytes(input);

  static Guid? parse(String? input) {
    if (input == null || input.isEmpty) {
      return null;
    } else {
      return Guid(input);
    }
  }

  static List<int> _toBytes(String input) {
    if (input.isEmpty) {
      return List.filled(16, 0);
    }

    input = input.replaceAll('-', '');

    List<int>? bytes = _tryHexDecode(input);
    if (bytes == null) {
      throw FormatException("GUID not hex format: $input");
    }

    _checkLen(bytes.length);

    return bytes;
  }

  static bool _checkLen(int len) {
    if (!(len == 16 || len == 4 || len == 2)) {
      throw FormatException("GUID must be 16, 32, or 128 bit, yours: ${len * 8}-bit");
    }
    return true;
  }

  // 128-bit representation
  String get str128 {
    if (bytes.length == 2) {
      // 16-bit uuid
      return '0000${_hexEncode(bytes)}-0000-1000-8000-00805f9b34fb'.toLowerCase();
    }
    if (bytes.length == 4) {
      // 32-bit uuid
      return '${_hexEncode(bytes)}-0000-1000-8000-00805f9b34fb'.toLowerCase();
    }
    // 128-bit uuid
    String one = _hexEncode(bytes.sublist(0, 4));
    String two = _hexEncode(bytes.sublist(4, 6));
    String three = _hexEncode(bytes.sublist(6, 8));
    String four = _hexEncode(bytes.sublist(8, 10));
    String five = _hexEncode(bytes.sublist(10, 16));
    return "$one-$two-$three-$four-$five".toLowerCase();
  }

  // shortest representation
  String get str {
    bool starts = str128.startsWith('0000');
    bool ends = str128.contains('-0000-1000-8000-00805f9b34fb');
    if (starts && ends) {
      // 16-bit
      return str128.substring(4, 8);
    }
    if (ends) {
      // 32-bit
      return str128.substring(0, 8);
    }
    // 128-bit
    return str128;
  }

  @override
  String toString() => str;

  @override
  bool operator ==(Object other) {
    if (other is! Guid) return false;

    final length = bytes.length;
    if (length == other.bytes.length && (length == 2 || length == 4 || length == 16)) {
      for (var i = 0; i < length; i++) {
        if ((bytes[i] & 0xff) != (other.bytes[i] & 0xff)) return false;
      }
      return true;
    }

    for (var i = 0; i < 16; i++) {
      if (_canonicalByteAt(i) != other._canonicalByteAt(i)) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        _canonicalByteAt(0),
        _canonicalByteAt(1),
        _canonicalByteAt(2),
        _canonicalByteAt(3),
        _canonicalByteAt(4),
        _canonicalByteAt(5),
        _canonicalByteAt(6),
        _canonicalByteAt(7),
        _canonicalByteAt(8),
        _canonicalByteAt(9),
        _canonicalByteAt(10),
        _canonicalByteAt(11),
        _canonicalByteAt(12),
        _canonicalByteAt(13),
        _canonicalByteAt(14),
        _canonicalByteAt(15),
      );

  int _canonicalByteAt(int index) {
    if (bytes.length == 2) {
      if (index < 2) return 0;
      if (index < 4) return bytes[index - 2] & 0xff;
      return _bluetoothBaseTail[index - 4];
    }
    if (bytes.length == 4) {
      if (index < 4) return bytes[index] & 0xff;
      return _bluetoothBaseTail[index - 4];
    }
    return bytes[index] & 0xff;
  }
}

String _hexEncode(List<int> numbers) {
  return numbers.map((n) => (n & 0xFF).toRadixString(16).padLeft(2, '0')).join();
}

List<int>? _tryHexDecode(String hex) {
  List<int> numbers = [];
  for (int i = 0; i < hex.length; i += 2) {
    String hexPart = hex.substring(i, i + 2);
    int? num = int.tryParse(hexPart, radix: 16);
    if (num == null) {
      return null;
    }
    numbers.add(num);
  }
  return numbers;
}
