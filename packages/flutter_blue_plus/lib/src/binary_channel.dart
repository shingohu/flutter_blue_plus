part of '../flutter_blue_plus.dart';

/// Binary protocol channel for efficient BLE write operations.
///
/// Uses BasicMessageChannel + BinaryCodec to avoid MethodChannel
/// serialization overhead and eliminate redundant event-channel
/// round-trips for write responses.
class _BinaryWriteChannel {
  static final _BinaryWriteChannel _instance = _BinaryWriteChannel._();
  static _BinaryWriteChannel get instance => _instance;

  final BasicMessageChannel<ByteData> _channel =
      BasicMessageChannel<ByteData>(binaryChannelName, BinaryCodec());

  _BinaryWriteChannel._();

  /// Write a characteristic value via the binary channel.
  ///
  /// Returns the decoded response, or throws on error.
  Future<Map<String, dynamic>> writeCharacteristic({
    required DeviceIdentifier remoteId,
    required Guid? primaryServiceUuid,
    required Guid serviceUuid,
    required Guid characteristicUuid,
    required int instanceId,
    required bool withoutResponse,
    required bool allowLongWrite,
    required List<int> value,
  }) async {

    int flags = 0;
    if (withoutResponse) flags |= WriteFlags.withoutResponse;
    if (allowLongWrite) flags |= WriteFlags.allowLongWrite;

    final request = encodeWriteCharacteristic(
      flags: flags,
      instanceId: instanceId,
      remoteId: remoteId.str,
      serviceUuid: serviceUuid.str,
      characteristicUuid: characteristicUuid.str,
      primaryServiceUuid: primaryServiceUuid?.str,
      value: value,
    );

    final response = await _sendAndReceive(request, 'writeCharacteristic');
    final result = decodeResponse(response);

    if (result['success'] != 1) {
      throw FlutterBluePlusException(
        _nativeError,
        'write',
        result['errorCode'] as int,
        result['errorString'] as String,
      );
    }

    return result;
  }

  /// Write a descriptor value via the binary channel.
  Future<Map<String, dynamic>> writeDescriptor({
    required DeviceIdentifier remoteId,
    required Guid? primaryServiceUuid,
    required Guid serviceUuid,
    required Guid characteristicUuid,
    required int instanceId,
    required Guid descriptorUuid,
    required List<int> value,
  }) async {
    final request = encodeWriteDescriptor(
      flags: 0,
      instanceId: instanceId,
      remoteId: remoteId.str,
      serviceUuid: serviceUuid.str,
      characteristicUuid: characteristicUuid.str,
      primaryServiceUuid: primaryServiceUuid?.str,
      descriptorUuid: descriptorUuid.str,
      value: value,
    );

    final response = await _sendAndReceive(request, 'writeDescriptor');
    final result = decodeResponse(response);

    if (result['success'] != 1) {
      throw FlutterBluePlusException(
        _nativeError,
        'writeDescriptor',
        result['errorCode'] as int,
        result['errorString'] as String,
      );
    }

    return result;
  }

  /// Enable or disable notifications via the binary channel.
  Future<Map<String, dynamic>> setNotifyValue({
    required DeviceIdentifier remoteId,
    required Guid? primaryServiceUuid,
    required Guid serviceUuid,
    required Guid characteristicUuid,
    required int instanceId,
    required bool enable,
    required bool forceIndications,
  }) async {
    int flags = 0;
    if (enable) flags |= NotifyFlags.enable;
    if (forceIndications) flags |= NotifyFlags.forceIndications;

    final request = encodeSetNotifyValue(
      flags: flags,
      instanceId: instanceId,
      remoteId: remoteId.str,
      serviceUuid: serviceUuid.str,
      characteristicUuid: characteristicUuid.str,
      primaryServiceUuid: primaryServiceUuid?.str,
    );

    final response = await _sendAndReceive(request, 'setNotifyValue');
    final result = decodeResponse(response);

    if (result['success'] != 1) {
      throw FlutterBluePlusException(
        _nativeError,
        'setNotifyValue',
        result['errorCode'] as int,
        result['errorString'] as String,
      );
    }

    return result;
  }

  // Timeout protects the per-device operation mutex: if the native side never
  // replies (e.g. a pending-reply key mismatch), the awaiting write() would
  // otherwise hold the mutex forever and deadlock all further BLE operations
  // on that device. Matches the MethodChannel path's fbpTimeout behavior.
  static const Duration _sendTimeout = Duration(seconds: 15);

  Future<ByteData> _sendAndReceive(ByteData request, String function) async {
    try {
      final response = await _channel.send(request).timeout(_sendTimeout);
      if (response == null) {
        throw Exception('null response from binary channel');
      }
      return response;
    } on TimeoutException {
      throw FlutterBluePlusException(
          ErrorPlatform.fbp, function, FbpErrorCode.timeout.index,
          'Timed out after ${_sendTimeout.inMilliseconds}ms');
    }
  }
}
