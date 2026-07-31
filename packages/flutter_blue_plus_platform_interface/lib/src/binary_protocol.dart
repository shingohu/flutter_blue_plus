import 'dart:typed_data';

/// Command IDs for the binary BLE protocol.
class BinaryCommand {
  BinaryCommand._();

  /// Write a characteristic value.
  static const int writeCharacteristic = 0x01;

  /// Write a descriptor value.
  static const int writeDescriptor = 0x02;

  /// Enable/disable notifications.
  static const int setNotifyValue = 0x03;
}

/// Flags for [BinaryCommand.writeCharacteristic].
class WriteFlags {
  WriteFlags._();
  static const int withoutResponse = 1 << 0;
  static const int allowLongWrite = 1 << 1;
}

/// Flags for [BinaryCommand.setNotifyValue].
class NotifyFlags {
  NotifyFlags._();
  static const int enable = 1 << 0;
  static const int forceIndications = 1 << 1;
}

/// Binary protocol channel name.
const String binaryChannelName = 'flutter_blue_plus/binary';

/// Encode a write characteristic request into binary format.
///
/// Binary layout:
///   [0]     cmd (1 byte)
///   [1]     flags (1 byte)
///   [2-3]   instanceId (uint16 BE)
///   [4]     remoteIdLen (1 byte)
///   [5..]   remoteId (N bytes UTF-8)
///   [..]    serviceUuidLen (1 byte)
///   [..]    serviceUuid (M bytes UTF-8)
///   [..]    characteristicUuidLen (1 byte)
///   [..]    characteristicUuid (P bytes UTF-8)
///   [..]    primaryServiceUuidLen (1 byte, 0=null)
///   [..]    primaryServiceUuid (Q bytes UTF-8, absent if len=0)
///   [..]    valueLen (uint16 BE)
///   [..]    value (S bytes)
ByteData encodeWriteCharacteristic({
  required int flags,
  required int instanceId,
  required String remoteId,
  required String serviceUuid,
  required String characteristicUuid,
  required String? primaryServiceUuid,
  required List<int> value,
}) {
  return _encode(
    command: BinaryCommand.writeCharacteristic,
    flags: flags,
    instanceId: instanceId,
    remoteId: remoteId,
    serviceUuid: serviceUuid,
    characteristicUuid: characteristicUuid,
    primaryServiceUuid: primaryServiceUuid,
    descriptorUuid: null,
    value: value,
  );
}

/// Encode a write descriptor request into binary format.
ByteData encodeWriteDescriptor({
  required int flags,
  required int instanceId,
  required String remoteId,
  required String serviceUuid,
  required String characteristicUuid,
  required String? primaryServiceUuid,
  required String descriptorUuid,
  required List<int> value,
}) {
  return _encode(
    command: BinaryCommand.writeDescriptor,
    flags: flags,
    instanceId: instanceId,
    remoteId: remoteId,
    serviceUuid: serviceUuid,
    characteristicUuid: characteristicUuid,
    primaryServiceUuid: primaryServiceUuid,
    descriptorUuid: descriptorUuid,
    value: value,
  );
}

/// Encode a setNotifyValue request into binary format.
ByteData encodeSetNotifyValue({
  required int flags,
  required int instanceId,
  required String remoteId,
  required String serviceUuid,
  required String characteristicUuid,
  required String? primaryServiceUuid,
}) {
  return _encode(
    command: BinaryCommand.setNotifyValue,
    flags: flags,
    instanceId: instanceId,
    remoteId: remoteId,
    serviceUuid: serviceUuid,
    characteristicUuid: characteristicUuid,
    primaryServiceUuid: primaryServiceUuid,
    descriptorUuid: null,
    value: const [],
  );
}

/// Internal helper to build a binary request.
ByteData _encode({
  required int command,
  required int flags,
  required int instanceId,
  required String remoteId,
  required String serviceUuid,
  required String characteristicUuid,
  required String? primaryServiceUuid,
  required String? descriptorUuid,
  required List<int> value,
}) {
  final remoteIdBytes = _utf8Encode(remoteId);
  final svcBytes = _utf8Encode(serviceUuid);
  final charBytes = _utf8Encode(characteristicUuid);
  final primaryBytes = primaryServiceUuid != null ? _utf8Encode(primaryServiceUuid) : Uint8List(0);
  final descBytes = descriptorUuid != null ? _utf8Encode(descriptorUuid) : Uint8List(0);

  // total size = command(1) + flags(1) + instanceId(2) + remoteIdLen(1)
  //            + remoteId + svcLen(1) + svc + charLen(1) + char
  //            + primaryLen(1) + primary + descLen(1) + desc
  //            + valueLen(2) + value
  int offset = 0;
  int size = 1 + 1 + 2 + 1 + remoteIdBytes.length +
             1 + svcBytes.length +
             1 + charBytes.length +
             1 + primaryBytes.length +
             1 + descBytes.length +
             2 + value.length;
  final data = ByteData(size);

  data.setUint8(offset, command & 0xFF); offset += 1;
  data.setUint8(offset, flags & 0xFF); offset += 1;
  data.setUint16(offset, instanceId & 0xFFFF); offset += 2;

  data.setUint8(offset, remoteIdBytes.length); offset += 1;
  if (remoteIdBytes.isNotEmpty) {
    data.buffer.asUint8List().setAll(offset, remoteIdBytes);
    offset += remoteIdBytes.length;
  }

  data.setUint8(offset, svcBytes.length); offset += 1;
  if (svcBytes.isNotEmpty) {
    data.buffer.asUint8List().setAll(offset, svcBytes);
    offset += svcBytes.length;
  }

  data.setUint8(offset, charBytes.length); offset += 1;
  if (charBytes.isNotEmpty) {
    data.buffer.asUint8List().setAll(offset, charBytes);
    offset += charBytes.length;
  }

  data.setUint8(offset, primaryBytes.length); offset += 1;
  if (primaryBytes.isNotEmpty) {
    data.buffer.asUint8List().setAll(offset, primaryBytes);
    offset += primaryBytes.length;
  }

  data.setUint8(offset, descBytes.length); offset += 1;
  if (descBytes.isNotEmpty) {
    data.buffer.asUint8List().setAll(offset, descBytes);
    offset += descBytes.length;
  }

  data.setUint16(offset, value.length); offset += 2;
  if (value.isNotEmpty) {
    data.buffer.asUint8List().setAll(offset, value);
  }

  return data;
}

/// Decode a binary response.
///
/// Returns a map with keys: success (int), errorCode (int), errorString (String).
///
/// Binary layout:
///   [0]     success (1 byte, 0 or 1)
///   [1-4]   errorCode (int32 BE)
///   [5-6]   errorStrLen (uint16 BE)
///   [7..]   errorStr (N bytes UTF-8)
Map<String, dynamic> decodeResponse(ByteData data) {
  int offset = 0;
  final success = data.getUint8(offset); offset += 1;
  final errorCode = data.getInt32(offset); offset += 4;
  final errorStrLen = data.getUint16(offset); offset += 2;
  final errorStr = errorStrLen > 0
      ? _utf8Decode(data.buffer.asUint8List(), offset, errorStrLen)
      : '';
  return {
    'success': success,
    'errorCode': errorCode,
    'errorString': errorStr,
  };
}

/// Encode a success response (native → Dart).
ByteData encodeResponse({required bool success, int errorCode = 0, String errorString = ''}) {
  final errorStrBytes = errorString.isNotEmpty ? _utf8Encode(errorString) : Uint8List(0);
  final size = 1 + 4 + 2 + errorStrBytes.length;
  final data = ByteData(size);
  int offset = 0;
  data.setUint8(offset, success ? 1 : 0); offset += 1;
  data.setInt32(offset, errorCode); offset += 4;
  data.setUint16(offset, errorStrBytes.length); offset += 2;
  if (errorStrBytes.isNotEmpty) {
    data.buffer.asUint8List().setAll(offset, errorStrBytes);
  }
  return data;
}

Uint8List _utf8Encode(String s) => Uint8List.fromList(s.codeUnits);

String _utf8Decode(Uint8List bytes, int offset, int length) {
  return String.fromCharCodes(bytes.sublist(offset, offset + length));
}
