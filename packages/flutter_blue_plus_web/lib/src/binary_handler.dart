import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart'
    show binaryChannelName, encodeResponse, BinaryCommand, WriteFlags, NotifyFlags, Guid;

import '../flutter_blue_plus_web.dart';

/// Binary message handler for Web platform.
///
/// Registered by [FlutterBluePlusWeb.registerWith] to handle binary protocol
/// write requests. All writes go through the plugin's binary* core methods,
/// which emit the same events as the MethodChannel path.
class WebBinaryHandler {
  WebBinaryHandler(this._plugin);

  final FlutterBluePlusWeb _plugin;

  BasicMessageChannel<ByteData>? _channel;

  /// Register the binary message handler.
  void register() {
    if (_channel != null) return;
    _channel = BasicMessageChannel<ByteData>(binaryChannelName, BinaryCodec());
    _channel!.setMessageHandler(_handleMessage);
  }

  /// Unregister the binary message handler.
  void unregister() {
    _channel?.setMessageHandler(null);
    _channel = null;
  }

  Future<ByteData> _handleMessage(ByteData? message) async {
    if (message == null) {
      return encodeResponse(success: false, errorCode: -1, errorString: 'null message');
    }
    try {
      return await _handleMessageInner(message);
    } catch (e) {
      return encodeResponse(success: false, errorCode: -1, errorString: e.toString());
    }
  }

  Future<ByteData> _handleMessageInner(ByteData data) async {
    if (data.lengthInBytes < 4) {
      return encodeResponse(success: false, errorCode: -1, errorString: 'invalid message');
    }
    final cmd = data.getUint8(0);
    final flags = data.getUint8(1);
    final instanceId = data.getUint16(2);
    int offset = 4;

    String? readString() {
      if (offset >= data.lengthInBytes) return null;
      final len = data.getUint8(offset);
      offset += 1;
      if (len == 0) return '';
      if (offset + len > data.lengthInBytes) return null;
      final s = String.fromCharCodes(data.buffer.asUint8List().sublist(offset, offset + len));
      offset += len;
      return s;
    }

    ByteData err(int code, String msg) =>
        encodeResponse(success: false, errorCode: code, errorString: msg);

    final remoteId = readString();
    if (remoteId == null) return err(-1, 'missing remoteId');
    final serviceUuid = readString();
    if (serviceUuid == null) return err(-1, 'missing serviceUuid');
    final characteristicUuid = readString();
    if (characteristicUuid == null) return err(-1, 'missing characteristicUuid');
    final primaryServiceUuid = readString() ?? '';
    final descriptorUuid = readString() ?? '';

    switch (cmd) {
      case BinaryCommand.writeCharacteristic: {
        final value = _readValue(data, offset);
        if (value == null) return err(-1, 'missing value');
        final result = await _plugin.binaryWriteCharacteristic(
          remoteId: remoteId,
          primaryServiceUuid: primaryServiceUuid.isEmpty ? null : Guid(primaryServiceUuid),
          serviceUuid: Guid(serviceUuid),
          characteristicUuid: Guid(characteristicUuid),
          instanceId: instanceId,
          withoutResponse: (flags & WriteFlags.withoutResponse) != 0,
          value: value,
        );
        return encodeResponse(
            success: result.success, errorCode: result.errorCode, errorString: result.errorString);
      }
      case BinaryCommand.writeDescriptor: {
        final value = _readValue(data, offset);
        if (value == null) return err(-1, 'missing value');
        final result = await _plugin.binaryWriteDescriptor(
          remoteId: remoteId,
          primaryServiceUuid: primaryServiceUuid.isEmpty ? null : Guid(primaryServiceUuid),
          serviceUuid: Guid(serviceUuid),
          characteristicUuid: Guid(characteristicUuid),
          instanceId: instanceId,
          descriptorUuid: Guid(descriptorUuid),
          value: value,
        );
        return encodeResponse(
            success: result.success, errorCode: result.errorCode, errorString: result.errorString);
      }
      case BinaryCommand.setNotifyValue: {
        final result = await _plugin.binarySetNotifyValue(
          remoteId: remoteId,
          primaryServiceUuid: primaryServiceUuid.isEmpty ? null : Guid(primaryServiceUuid),
          serviceUuid: Guid(serviceUuid),
          characteristicUuid: Guid(characteristicUuid),
          instanceId: instanceId,
          enable: (flags & NotifyFlags.enable) != 0,
        );
        return encodeResponse(
            success: result.success, errorCode: result.errorCode, errorString: result.errorString);
      }
      default:
        return err(-1, 'unknown cmd: $cmd');
    }
  }

  List<int>? _readValue(ByteData data, int offset) {
    if (offset + 2 > data.lengthInBytes) return null;
    final len = data.getUint16(offset);
    offset += 2;
    if (offset + len > data.lengthInBytes) return null;
    return data.buffer.asUint8List().sublist(offset, offset + len);
  }
}
