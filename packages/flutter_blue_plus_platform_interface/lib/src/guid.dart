// Copyright 2017-2023, Charles Weinberger
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:typed_data';

class Guid {
  static const String _hexDigits = '0123456789abcdef';
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
    final output = Uint8List(36);
    var offset = 0;
    for (var i = 0; i < 16; i++) {
      if (i == 4 || i == 6 || i == 8 || i == 10) {
        output[offset++] = 0x2d;
      }
      final byte = _canonicalByteAt(i);
      output[offset++] = _hexDigits.codeUnitAt(byte >> 4);
      output[offset++] = _hexDigits.codeUnitAt(byte & 0x0f);
    }
    return String.fromCharCodes(output);
  }

  // shortest representation
  String get str {
    final value = str128;
    bool starts = value.startsWith('0000');
    bool ends = value.contains('-0000-1000-8000-00805f9b34fb');
    if (starts && ends) {
      // 16-bit
      return value.substring(4, 8);
    }
    if (ends) {
      // 32-bit
      return value.substring(0, 8);
    }
    // 128-bit
    return value;
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
