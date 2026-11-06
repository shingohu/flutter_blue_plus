// Copyright 2026, shingo.
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_blue_plus_permission/flutter_blue_plus_permission.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channelName = 'flutter_blue_plus_permission';
  const legacyChannelName = 'ble_permission';
  const codec = StandardMethodCodec();

  late TestDefaultBinaryMessenger messenger;

  setUp(() {
    messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMessageHandler(channelName, null);
    messenger.setMockMessageHandler(legacyChannelName, null);
  });

  tearDown(() {
    messenger.setMockMessageHandler(channelName, null);
    messenger.setMockMessageHandler(legacyChannelName, null);
  });

  test('exposes a singleton with an unknown initial adapter state', () {
    expect(identical(BlePermission.instance, BlePermission.instance), isTrue);
    expect(BlePermission.instance.bluetoothAdapterState.value, isNull);
  });

  test('routes method calls through the renamed channel', () async {
    final calls = <String>[];
    messenger.setMockMessageHandler(channelName, (ByteData? message) async {
      calls.add(codec.decodeMethodCall(message).method);
      return codec.encodeSuccessEnvelope(true);
    });

    expect(await BlePermission.instance.requestPermission(), isTrue);
    expect(await BlePermission.instance.checkPermission(), isTrue);
    expect(calls, <String>['requestPermission', 'checkPermission']);
  });

  // The MethodChannel name must stay in sync with the Android, iOS and OHOS
  // implementations. A mismatch fails silently at runtime, so guard it here.
  test('never falls back to the legacy ble_permission channel', () async {
    var legacyCalls = 0;
    messenger.setMockMessageHandler(legacyChannelName, (ByteData? message) async {
      legacyCalls++;
      return codec.encodeSuccessEnvelope(false);
    });
    messenger.setMockMessageHandler(channelName, (ByteData? message) async {
      return codec.encodeSuccessEnvelope(true);
    });

    expect(await BlePermission.instance.isReady(), isTrue);
    expect(legacyCalls, 0);
  });
}
