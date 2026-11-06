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
    expect(identical(FlutterBluePlusPermission.instance, FlutterBluePlusPermission.instance), isTrue);
    expect(FlutterBluePlusPermission.instance.bluetoothAdapterState.value, isNull);
  });

  test('routes method calls through the renamed channel', () async {
    final calls = <String>[];
    messenger.setMockMessageHandler(channelName, (ByteData? message) async {
      calls.add(codec.decodeMethodCall(message).method);
      return codec.encodeSuccessEnvelope(true);
    });

    expect(await FlutterBluePlusPermission.instance.requestPermission(), isTrue);
    expect(await FlutterBluePlusPermission.instance.checkPermission(), isTrue);
    expect(await FlutterBluePlusPermission.instance.openPermission(), isTrue);
    expect(calls, <String>['requestPermission', 'checkPermission', 'openPermission']);
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

    expect(await FlutterBluePlusPermission.instance.isReady(), isTrue);
    expect(legacyCalls, 0);
  });

  // flutter_test runs on the host VM, so the Android/iOS-only branches must
  // short-circuit before touching the channel (and before dart:io access on
  // web builds, where kIsWeb guards the Platform getters).
  test('platform-gated probes do not reach the channel on the host', () async {
    var calls = 0;
    messenger.setMockMessageHandler(channelName, (ByteData? message) async {
      calls++;
      return codec.encodeSuccessEnvelope(true);
    });

    expect(await FlutterBluePlusPermission.instance.isNeedLocationService(), isFalse);
    await expectLater(FlutterBluePlusPermission.instance.isLocationServiceEnable, throwsUnsupportedError);
    await expectLater(FlutterBluePlusPermission.instance.openLocationService(), throwsUnsupportedError);
    await expectLater(FlutterBluePlusPermission.instance.isBluetoothTetheringEnable(), throwsUnsupportedError);
    await expectLater(FlutterBluePlusPermission.instance.isPersonalHotspotEnabled(), throwsUnsupportedError);
    expect(calls, 0);
  });
}
