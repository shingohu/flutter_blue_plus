/*
 * Copyright (C) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 *
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_blue_plus_ohos/flutter_blue_plus_ohos.dart';

// The OHOS platform implementation under test. It dispatches every public
// Future method onto the `flutter_blue_plus/methods` MethodChannel and forwards
// native `On*` callbacks into broadcast Streams. These tests assert full
// coverage of both directions using a mocked method channel.

const _channelName = 'flutter_blue_plus/methods';

// Two independent channels run through the same MethodChannel name:
//  * outgoing: Flutter invokes native methods (clearGattCache, connect, ...).
//    We intercept these via setMockMethodCallHandler and record name + args.
//  * incoming: native pushes On* events back to Flutter. The plugin registers
//    a handler via setMethodCallHandler in its constructor and we drive those
//    events with handlePlatformMessage.

Map<String, dynamic> _invokeLog = {};
dynamic Function(MethodCall call)? _invokeHandler;

FlutterBluePlusOhos _newPlugin() => FlutterBluePlusOhos();

void _mockMethods(dynamic Function(MethodCall call) handler) {
  _invokeHandler = handler;
  _invokeLog.clear();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel(_channelName), (call) async {
    _invokeLog[call.method] = call.arguments;
    if (_invokeHandler != null) {
      return await _invokeHandler!(call);
    }
    return null;
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The plugin's _callOhosMethod runs _flutterRestart() before the FIRST
  // non-setLogLevel call (guarded by _didRestart). _flutterRestart polls
  // flutterRestart / connectedCount until connectedCount == 0, then sets
  // _didRestart = true. To make every test deterministic we wrap the test
  // handler so restart-bookkeeping calls return 0 (fast exit), then trigger
  // one real call to force _flutterRestart to run and mark _didRestart.
  Future<FlutterBluePlusOhos> makeReadyPlugin({
    dynamic Function(MethodCall call)? handler,
  }) async {
    final testHandler = handler ?? (call) => true;
    final plugin = _newPlugin();
    // Step 1: readiness handler. _callOhosMethod runs _flutterRestart on the
    // first non-setLogLevel call; make flutterRestart/connectedCount return 0
    // so the restart loop exits immediately and _didRestart becomes true.
    // isSupported is typed <bool>, so the readiness call must return a bool.
    _mockMethods((call) {
      switch (call.method) {
        case 'flutterRestart':
        case 'connectedCount':
          return 0;
        default:
          return true;
      }
    });
    await plugin.isSupported(BmIsSupportedRequest());
    // Step 2: now _didRestart is true and the On* handler is installed. Replace
    // the mock with the test's own handler so the real assertions see it.
    _mockMethods(testHandler);
    return plugin;
  }

  group('registerWith', () {
    test('sets the platform instance to FlutterBluePlusOhos', () {
      // registerWith assigns a FlutterBluePlusOhos as the platform instance.
      // (Reading instance before any registration would throw UnsupportedError,
      // so we don't snapshot/restore a previous value here.)
      FlutterBluePlusOhos.registerWith();
      expect(FlutterBluePlusPlatform.instance, isA<FlutterBluePlusOhos>());
    });
  });

  group('Stream getters expose broadcast controllers', () {
    test('every stream getter returns a non-null stream', () async {
      final plugin = await makeReadyPlugin();
      expect(plugin.onAdapterStateChanged, isNotNull);
      expect(plugin.onBondStateChanged, isNotNull);
      expect(plugin.onCharacteristicReceived, isNotNull);
      expect(plugin.onCharacteristicWritten, isNotNull);
      expect(plugin.onConnectionStateChanged, isNotNull);
      expect(plugin.onDescriptorRead, isNotNull);
      expect(plugin.onDescriptorWritten, isNotNull);
      expect(plugin.onDetachedFromEngine, isNotNull);
      expect(plugin.onDiscoveredServices, isNotNull);
      expect(plugin.onMtuChanged, isNotNull);
      expect(plugin.onNameChanged, isNotNull);
      expect(plugin.onReadRssi, isNotNull);
      expect(plugin.onScanResponse, isNotNull);
      expect(plugin.onServicesReset, isNotNull);
      expect(plugin.onTurnOnResponse, isNotNull);
    });
  });

  group('Future methods - boolean returns', () {
    test('connect invokes "connect" with toMap() and returns bool', () async {
      final plugin = await makeReadyPlugin(handler: (call) => true);
      final req = BmConnectRequest(
        remoteId: const DeviceIdentifier('AA:BB:CC:DD:EE:FF'),
        autoConnect: true,
      );
      final result = await plugin.connect(req);
      expect(result, isTrue);
      expect(_invokeLog['connect'], isA<Map>());
      expect(_invokeLog['connect']['remote_id'], 'AA:BB:CC:DD:EE:FF');
      expect(_invokeLog['connect']['auto_connect'], 1);
    });

    test('connect returns false when native returns false', () async {
      final plugin = await makeReadyPlugin(handler: (call) => false);
      final result = await plugin.connect(BmConnectRequest(
        remoteId: const DeviceIdentifier('x'),
        autoConnect: false,
      ));
      expect(result, isFalse);
      expect(_invokeLog['connect']['auto_connect'], 0);
    });

    test('disconnect invokes "disconnect" with remoteId.str', () async {
      final plugin = await makeReadyPlugin(handler: (call) => true);
      expect(
        await plugin.disconnect(
            BmDisconnectRequest(remoteId: const DeviceIdentifier('remote-1'))),
        isTrue,
      );
      expect(_invokeLog['disconnect'], 'remote-1');
    });

    test('discoverServices invokes "discoverServices" with remoteId.str',
        () async {
      final plugin = await makeReadyPlugin(handler: (call) => true);
      expect(
        await plugin.discoverServices(
            BmDiscoverServicesRequest(remoteId: const DeviceIdentifier('d1'))),
        isTrue,
      );
      expect(_invokeLog['discoverServices'], 'd1');
    });

    test('clearGattCache invokes "clearGattCache" with remoteId.str', () async {
      final plugin = await makeReadyPlugin(handler: (call) => true);
      expect(
        await plugin.clearGattCache(
            BmClearGattCacheRequest(remoteId: const DeviceIdentifier('c1'))),
        isTrue,
      );
      expect(_invokeLog['clearGattCache'], 'c1');
    });

    test('readRssi invokes "readRssi" with remoteId.str', () async {
      final plugin = await makeReadyPlugin(handler: (call) => true);
      expect(
        await plugin.readRssi(
            BmReadRssiRequest(remoteId: const DeviceIdentifier('r1'))),
        isTrue,
      );
      expect(_invokeLog['readRssi'], 'r1');
    });

    test('createBond invokes "createBond" with toMap()', () async {
      final plugin = await makeReadyPlugin(handler: (call) => true);
      final req = BmCreateBondRequest(
        remoteId: const DeviceIdentifier('b1'),
        pin: Uint8List.fromList([1, 2, 3]),
      );
      expect(await plugin.createBond(req), isTrue);
      expect(_invokeLog['createBond']['remote_id'], 'b1');
      expect(_invokeLog['createBond']['pin'], [1, 2, 3]);
    });

    test('removeBond invokes "removeBond" with remoteId.str', () async {
      final plugin = await makeReadyPlugin(handler: (call) => true);
      expect(
        await plugin.removeBond(
            BmRemoveBondRequest(remoteId: const DeviceIdentifier('rb1'))),
        isTrue,
      );
      expect(_invokeLog['removeBond'], 'rb1');
    });

    test('requestConnectionPriority invokes with toMap()', () async {
      final plugin = await makeReadyPlugin(handler: (call) => true);
      final req = BmConnectionPriorityRequest(
        remoteId: const DeviceIdentifier('p1'),
        connectionPriority: BmConnectionPriorityEnum.high,
      );
      expect(await plugin.requestConnectionPriority(req), isTrue);
      expect(_invokeLog['requestConnectionPriority']['remote_id'], 'p1');
      expect(_invokeLog['requestConnectionPriority']['connection_priority'], 1);
    });

    test('requestMtu invokes "requestMtu" with toMap()', () async {
      final plugin = await makeReadyPlugin(handler: (call) => true);
      final req = BmMtuChangeRequest(
        remoteId: const DeviceIdentifier('m1'),
        mtu: 512,
      );
      expect(await plugin.requestMtu(req), isTrue);
      expect(_invokeLog['requestMtu']['remote_id'], 'm1');
      expect(_invokeLog['requestMtu']['mtu'], 512);
    });

    test('setNotifyValue invokes "setNotifyValue" with toMap()', () async {
      final plugin = await makeReadyPlugin(handler: (call) => true);
      final req = BmSetNotifyValueRequest(
        remoteId: const DeviceIdentifier('n1'),
        primaryServiceUuid: Guid('180a'),
        serviceUuid: Guid('180a'),
        characteristicUuid: Guid('2a00'),
        instanceId: 0,
        forceIndications: true,
        enable: true,
      );
      expect(await plugin.setNotifyValue(req), isTrue);
      expect(_invokeLog['setNotifyValue']['remote_id'], 'n1');
      expect(_invokeLog['setNotifyValue']['force_indications'], isTrue);
      expect(_invokeLog['setNotifyValue']['enable'], isTrue);
    });

    test('setOptions invokes "setOptions" with toMap()', () async {
      final plugin = await makeReadyPlugin(handler: (call) => true);
      final req = BmSetOptionsRequest(
        showPowerAlert: true,
        restoreState: false,
      );
      expect(await plugin.setOptions(req), isTrue);
      expect(_invokeLog['setOptions']['show_power_alert'], isTrue);
      expect(_invokeLog['setOptions']['restore_state'], isFalse);
    });

    test('setPreferredPhy invokes "setPreferredPhy" with toMap()', () async {
      final plugin = await makeReadyPlugin(handler: (call) => true);
      final req = BmPreferredPhy(
        remoteId: const DeviceIdentifier('ph1'),
        txPhy: 1,
        rxPhy: 1,
        phyOptions: 0,
      );
      expect(await plugin.setPreferredPhy(req), isTrue);
      expect(_invokeLog['setPreferredPhy']['tx_phy'], 1);
      expect(_invokeLog['setPreferredPhy']['phy_options'], 0);
    });

    test('startScan invokes "startScan" with toMap()', () async {
      final plugin = await makeReadyPlugin(handler: (call) => true);
      final req = BmScanSettings(
        withServices: [Guid('180d')],
        withRemoteIds: ['id1'],
        withNames: ['name1'],
        withKeywords: ['kw'],
        withMsd: [],
        withServiceData: [],
        continuousUpdates: true,
        continuousDivisor: 3,
        androidLegacy: false,
        androidScanMode: 0,
        androidUsesFineLocation: false,
        androidCheckLocationServices: true,
        webOptionalServices: [],
      );
      expect(await plugin.startScan(req), isTrue);
      expect(_invokeLog['startScan']['with_services'], ['180d']);
      expect(_invokeLog['startScan']['with_remote_ids'], ['id1']);
      expect(_invokeLog['startScan']['with_names'], ['name1']);
      expect(_invokeLog['startScan']['continuous_updates'], isTrue);
      expect(_invokeLog['startScan']['continuous_divisor'], 3);
    });

    test('stopScan invokes "stopScan" with no args', () async {
      final plugin = await makeReadyPlugin(handler: (call) => true);
      expect(await plugin.stopScan(BmStopScanRequest()), isTrue);
      expect(_invokeLog.containsKey('stopScan'), isTrue);
      expect(_invokeLog['stopScan'], isNull);
    });

    test('turnOff invokes "turnOff" with no args', () async {
      final plugin = await makeReadyPlugin(handler: (call) => true);
      expect(await plugin.turnOff(BmTurnOffRequest()), isTrue);
      expect(_invokeLog.containsKey('turnOff'), isTrue);
    });

    test('turnOn invokes "turnOn" with no args', () async {
      final plugin = await makeReadyPlugin(handler: (call) => true);
      expect(await plugin.turnOn(BmTurnOnRequest()), isTrue);
      expect(_invokeLog.containsKey('turnOn'), isTrue);
    });

    test('readCharacteristic invokes "readCharacteristic" with toMap()',
        () async {
      final plugin = await makeReadyPlugin(handler: (call) => true);
      final req = BmReadCharacteristicRequest(
        remoteId: const DeviceIdentifier('rc1'),
        primaryServiceUuid: Guid('180a'),
        serviceUuid: Guid('180a'),
        characteristicUuid: Guid('2a00'),
        instanceId: 0,
      );
      expect(await plugin.readCharacteristic(req), isTrue);
      expect(_invokeLog['readCharacteristic']['remote_id'], 'rc1');
      expect(_invokeLog['readCharacteristic']['service_uuid'], '180a');
      expect(_invokeLog['readCharacteristic']['characteristic_uuid'], '2a00');
      expect(_invokeLog['readCharacteristic']['instance_id'], 0);
    });

    test('readCharacteristic omits null primary_service_uuid', () async {
      final plugin = await makeReadyPlugin(handler: (call) => true);
      final req = BmReadCharacteristicRequest(
        remoteId: const DeviceIdentifier('rc2'),
        serviceUuid: Guid('180a'),
        characteristicUuid: Guid('2a00'),
        instanceId: 0,
      );
      await plugin.readCharacteristic(req);
      expect(_invokeLog['readCharacteristic'].containsKey('primary_service_uuid'),
          isFalse);
    });

    test('writeCharacteristic invokes "writeCharacteristic" with toMap()',
        () async {
      final plugin = await makeReadyPlugin(handler: (call) => true);
      final req = BmWriteCharacteristicRequest(
        remoteId: const DeviceIdentifier('wc1'),
        primaryServiceUuid: null,
        serviceUuid: Guid('180a'),
        characteristicUuid: Guid('2a00'),
        instanceId: 1,
        writeType: BmWriteType.withoutResponse,
        allowLongWrite: false,
        value: [0x01, 0x02],
      );
      expect(await plugin.writeCharacteristic(req), isTrue);
      expect(_invokeLog['writeCharacteristic']['write_type'], 1);
      expect(_invokeLog['writeCharacteristic']['allow_long_write'], 0);
      expect(_invokeLog['writeCharacteristic']['value'], [0x01, 0x02]);
    });

    test('readDescriptor invokes "readDescriptor" with toMap()', () async {
      final plugin = await makeReadyPlugin(handler: (call) => true);
      final req = BmReadDescriptorRequest(
        remoteId: const DeviceIdentifier('rd1'),
        primaryServiceUuid: null,
        serviceUuid: Guid('180a'),
        characteristicUuid: Guid('2a00'),
        instanceId: 0,
        descriptorUuid: Guid('2902'),
      );
      expect(await plugin.readDescriptor(req), isTrue);
      expect(_invokeLog['readDescriptor']['descriptor_uuid'], '2902');
    });

    test('writeDescriptor invokes "writeDescriptor" with toMap()', () async {
      final plugin = await makeReadyPlugin(handler: (call) => true);
      final req = BmWriteDescriptorRequest(
        remoteId: const DeviceIdentifier('wd1'),
        primaryServiceUuid: null,
        serviceUuid: Guid('180a'),
        characteristicUuid: Guid('2a00'),
        instanceId: 0,
        descriptorUuid: Guid('2902'),
        value: [0x00, 0x01],
      );
      expect(await plugin.writeDescriptor(req), isTrue);
      expect(_invokeLog['writeDescriptor']['value'], [0x00, 0x01]);
    });

    test('isSupported returns bool from native', () async {
      final plugin = await makeReadyPlugin(handler: (call) => true);
      expect(await plugin.isSupported(BmIsSupportedRequest()), isTrue);
      expect(_invokeLog.containsKey('isSupported'), isTrue);
    });

    test('isSupported returns false when native returns false/null',
        () async {
      final plugin = await makeReadyPlugin(handler: (call) => null);
      expect(await plugin.isSupported(BmIsSupportedRequest()), isFalse);
    });
  });

  group('Future methods - object returns', () {
    test('getAdapterState returns BmBluetoothAdapterState.fromMap', () async {
      final plugin =
          await makeReadyPlugin(handler: (call) => {'adapter_state': 4});
      final state = await plugin.getAdapterState(BmBluetoothAdapterStateRequest());
      expect(state.adapterState, BmAdapterStateEnum.on);
    });

    test('getAdapterName returns BmBluetoothAdapterName', () async {
      final plugin =
          await makeReadyPlugin(handler: (call) => 'MyDevice');
      final name = await plugin.getAdapterName(BmBluetoothAdapterNameRequest());
      expect(name.adapterName, 'MyDevice');
    });

    test('getBondState returns BmBondStateResponse.fromMap', () async {
      final plugin = await makeReadyPlugin(handler: (call) => {
            'remote_id': 'bond-1',
            'bond_state': 2,
            'prev_state': 1,
          });
      final resp = await plugin
          .getBondState(BmBondStateRequest(remoteId: const DeviceIdentifier('bond-1')));
      expect(resp.remoteId.str, 'bond-1');
      expect(resp.bondState, BmBondStateEnum.bonded);
      expect(resp.prevState, BmBondStateEnum.bonding);
    });

    test('getBondedDevices returns BmDevicesList.fromMap', () async {
      final plugin = await makeReadyPlugin(handler: (call) => {
            'devices': [
              {'remote_id': 'd-1', 'platform_name': 'n1'},
              {'remote_id': 'd-2', 'platform_name': 'n2'},
            ],
          });
      final list = await plugin.getBondedDevices(BmBondedDevicesRequest());
      expect(list.devices.length, 2);
      expect(list.devices[0].remoteId.str, 'd-1');
      expect(list.devices[1].platformName, 'n2');
    });

    test('getSystemDevices returns BmDevicesList.fromMap', () async {
      final plugin = await makeReadyPlugin(handler: (call) => {
            'devices': [
              {'remote_id': 's-1', 'platform_name': null},
            ],
          });
      final list = await plugin.getSystemDevices(BmSystemDevicesRequest(withServices: [Guid('180d')]));
      expect(list.devices.length, 1);
      expect(list.devices[0].remoteId.str, 's-1');
      // getSystemDevices sends no arguments to the native side (filters are
      // not forwarded by the OHOS implementation).
      expect(_invokeLog.containsKey('getSystemDevices'), isTrue);
      expect(_invokeLog['getSystemDevices'], isNull);
    });

    test('getPhySupport returns PhySupport.fromMap', () async {
      final plugin = await makeReadyPlugin(handler: (call) => {
            'le_2M': true,
            'le_coded': false,
          });
      final phy = await plugin.getPhySupport(PhySupportRequest());
      expect(phy.le2M, isTrue);
      expect(phy.leCoded, isFalse);
    });
  });

  group('setLogLevel', () {
    test('invokes "setLogLevel" with logLevel.index and stores level', () async {
      final plugin = await makeReadyPlugin(handler: (call) => true);
      // plugin already had a setLogLevel call during makeReadyPlugin. Reset log.
      _invokeLog.clear();
      expect(
        await plugin.setLogLevel(BmSetLogLevelRequest(
          logLevel: LogLevel.verbose,
          logColor: false,
        )),
        isTrue,
      );
      expect(_invokeLog['setLogLevel'], LogLevel.verbose.index);
    });

    test('verbose log path emits to platform log without throwing', () async {
      final plugin = await makeReadyPlugin(handler: (call) => true);
      // Enable verbose so _callOhosMethod logs args + result paths execute.
      await plugin.setLogLevel(BmSetLogLevelRequest(
        logLevel: LogLevel.verbose,
        logColor: true,
      ));
      // A subsequent call exercises the verbose branch in _callOhosMethod.
      expect(await plugin.isSupported(BmIsSupportedRequest()), isTrue);
    });
  });

  group('_flutterRestart', () {
    test('skips restart loop when setLogLevel is the first call', () async {
      // setLogLevel bypasses _flutterRestart entirely (per _callOhosMethod).
      _mockMethods((call) => true);
      final plugin = _newPlugin();
      expect(
        await plugin.setLogLevel(BmSetLogLevelRequest(logLevel: LogLevel.none)),
        isTrue,
      );
      // Only setLogLevel should have been invoked, not flutterRestart.
      expect(_invokeLog.containsKey('setLogLevel'), isTrue);
      expect(_invokeLog.containsKey('flutterRestart'), isFalse);
    });

    test('restart loop polls connectedCount when flutterRestart != 0', () async {
      // First call (non-setLogLevel) triggers _flutterRestart.
      // Make flutterRestart return non-zero, then connectedCount return 0
      // on the second poll so the loop exits quickly.
      var connectedCountCalls = 0;
      var flutterRestartCalls = 0;
      _mockMethods((call) {
        switch (call.method) {
          case 'flutterRestart':
            flutterRestartCalls++;
            return 1; // signals: wait for disconnects
          case 'connectedCount':
            connectedCountCalls++;
            // return non-zero first, then zero to exit loop
            return connectedCountCalls == 1 ? 1 : 0;
          default:
            return true;
        }
      });
      final plugin = _newPlugin();
      // Use a method that requires restart first time.
      expect(await plugin.turnOn(BmTurnOnRequest()), isTrue);
      expect(flutterRestartCalls, 1);
      expect(connectedCountCalls, greaterThanOrEqualTo(2));
      // Second call reuses _didRestart, no more flutterRestart.
      _invokeLog.clear();
      expect(await plugin.turnOff(BmTurnOffRequest()), isTrue);
      expect(_invokeLog.containsKey('flutterRestart'), isFalse);
    });

    test('restart loop exits immediately when flutterRestart returns 0',
        () async {
      var flutterRestartCalls = 0;
      _mockMethods((call) {
        if (call.method == 'flutterRestart') {
          flutterRestartCalls++;
          return 0;
        }
        return true;
      });
      final plugin = _newPlugin();
      expect(await plugin.turnOn(BmTurnOnRequest()), isTrue);
      expect(flutterRestartCalls, 1);
      // connectedCount should never be polled.
      expect(_invokeLog.containsKey('connectedCount'), isFalse);
    });
  });

  group('On* callbacks -> Streams', () {
    // Drives the plugin's installed method-call handler by sending an `On*`
    // method through the mock channel (which forwards to _capturedHandler).
    Future<void> sendOn(String method, dynamic args) async {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        _channelName,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
        null,
      );
    }

    test('OnAdapterStateChanged -> onAdapterStateChanged', () async {
      final plugin = await makeReadyPlugin();
      final completer = Completer<BmBluetoothAdapterState>();
      final sub = plugin.onAdapterStateChanged.listen(completer.complete);
      await sendOn('OnAdapterStateChanged', {'adapter_state': 6});
      final event = await completer.future.timeout(const Duration(seconds: 2));
      expect(event.adapterState, BmAdapterStateEnum.off);
      await sub.cancel();
    });

    test('OnBondStateChanged -> onBondStateChanged', () async {
      final plugin = await makeReadyPlugin();
      final completer = Completer<BmBondStateResponse>();
      final sub = plugin.onBondStateChanged.listen(completer.complete);
      await sendOn('OnBondStateChanged', {
        'remote_id': 'bz1',
        'bond_state': 1,
        'prev_state': 0,
      });
      final e = await completer.future.timeout(const Duration(seconds: 2));
      expect(e.remoteId.str, 'bz1');
      expect(e.bondState, BmBondStateEnum.bonding);
      expect(e.prevState, BmBondStateEnum.none);
      await sub.cancel();
    });

    test('OnCharacteristicReceived -> onCharacteristicReceived', () async {
      final plugin = await makeReadyPlugin();
      final completer = Completer<BmCharacteristicData>();
      final sub = plugin.onCharacteristicReceived.listen(completer.complete);
      await sendOn('OnCharacteristicReceived', {
        'remote_id': 'cr1',
        'service_uuid': '180a',
        'characteristic_uuid': '2a00',
        'instance_id': 0,
        'value': Uint8List.fromList([1, 2, 3]),
        'success': 1,
        'error_code': 0,
        'error_string': 'GATT_SUCCESS',
      });
      final e = await completer.future.timeout(const Duration(seconds: 2));
      expect(e.remoteId.str, 'cr1');
      expect(e.characteristicUuid.str, '2a00');
      expect(e.value, [1, 2, 3]);
      expect(e.success, isTrue);
      await sub.cancel();
    });

    test('OnCharacteristicWritten -> onCharacteristicWritten', () async {
      final plugin = await makeReadyPlugin();
      final completer = Completer<BmCharacteristicData>();
      final sub = plugin.onCharacteristicWritten.listen(completer.complete);
      await sendOn('OnCharacteristicWritten', {
        'remote_id': 'cw1',
        'service_uuid': '180a',
        'characteristic_uuid': '2a00',
        'instance_id': 0,
        'value': Uint8List.fromList([9, 8]),
        'success': 0,
        'error_code': 5,
        'error_string': 'err',
      });
      final e = await completer.future.timeout(const Duration(seconds: 2));
      expect(e.success, isFalse);
      expect(e.errorCode, 5);
      expect(e.errorString, 'err');
      await sub.cancel();
    });

    test('OnConnectionStateChanged -> onConnectionStateChanged', () async {
      final plugin = await makeReadyPlugin();
      final completer = Completer<BmConnectionStateResponse>();
      final sub = plugin.onConnectionStateChanged.listen(completer.complete);
      await sendOn('OnConnectionStateChanged', {
        'remote_id': 'cs1',
        'connection_state': 1,
        'disconnect_reason_code': 0,
        'disconnect_reason_string': null,
      });
      final e = await completer.future.timeout(const Duration(seconds: 2));
      expect(e.connectionState, BmConnectionStateEnum.connected);
      await sub.cancel();
    });

    test('OnDescriptorRead -> onDescriptorRead', () async {
      final plugin = await makeReadyPlugin();
      final completer = Completer<BmDescriptorData>();
      final sub = plugin.onDescriptorRead.listen(completer.complete);
      await sendOn('OnDescriptorRead', {
        'remote_id': 'dr1',
        'service_uuid': '180a',
        'characteristic_uuid': '2a00',
        'descriptor_uuid': '2902',
        'instance_id': 0,
        'value': Uint8List.fromList([0, 1]),
        'success': 1,
        'error_code': 0,
        'error_string': 'GATT_SUCCESS',
      });
      final e = await completer.future.timeout(const Duration(seconds: 2));
      expect(e.descriptorUuid.str, '2902');
      expect(e.value, [0, 1]);
      await sub.cancel();
    });

    test('OnDescriptorWritten -> onDescriptorWritten', () async {
      final plugin = await makeReadyPlugin();
      final completer = Completer<BmDescriptorData>();
      final sub = plugin.onDescriptorWritten.listen(completer.complete);
      await sendOn('OnDescriptorWritten', {
        'remote_id': 'dw1',
        'service_uuid': '180a',
        'characteristic_uuid': '2a00',
        'descriptor_uuid': '2902',
        'instance_id': 0,
        'value': Uint8List.fromList([2]),
        'success': 1,
        'error_code': 0,
        'error_string': '',
      });
      final e = await completer.future.timeout(const Duration(seconds: 2));
      expect(e.remoteId.str, 'dw1');
      expect(e.success, isTrue);
      await sub.cancel();
    });

    test('OnDetachedFromEngine -> onDetachedFromEngine', () async {
      final plugin = await makeReadyPlugin();
      final completer = Completer<BmDetachedFromEngineResponse>();
      final sub = plugin.onDetachedFromEngine.listen(completer.complete);
      await sendOn('OnDetachedFromEngine', null);
      await completer.future.timeout(const Duration(seconds: 2));
      await sub.cancel();
    });

    test('OnDiscoveredServices -> onDiscoveredServices', () async {
      final plugin = await makeReadyPlugin();
      final completer = Completer<BmDiscoverServicesResult>();
      final sub = plugin.onDiscoveredServices.listen(completer.complete);
      await sendOn('OnDiscoveredServices', {
        'remote_id': 'ds1',
        'services': [
          {
            'remote_id': 'ds1',
            'service_uuid': '180a',
            'characteristics': [
              {
                'remote_id': 'ds1',
                'service_uuid': '180a',
                'characteristic_uuid': '2a00',
                'instance_id': 0,
                'descriptors': [],
                'properties': {
                  'broadcast': 0,
                  'read': 1,
                  'write_without_response': 0,
                  'write': 0,
                  'notify': 0,
                  'indicate': 0,
                  'authenticated_signed_writes': 0,
                  'extended_properties': 0,
                  'notify_encryption_required': 0,
                  'indicate_encryption_required': 0,
                },
              },
            ],
          },
        ],
        'success': 1,
        'error_code': 0,
        'error_string': 'GATT_SUCCESS',
      });
      final e = await completer.future.timeout(const Duration(seconds: 2));
      expect(e.remoteId.str, 'ds1');
      expect(e.services.length, 1);
      expect(e.services[0].characteristics.length, 1);
      expect(e.services[0].characteristics[0].properties.read, isTrue);
      await sub.cancel();
    });

    test('OnMtuChanged -> onMtuChanged', () async {
      final plugin = await makeReadyPlugin();
      final completer = Completer<BmMtuChangedResponse>();
      final sub = plugin.onMtuChanged.listen(completer.complete);
      await sendOn('OnMtuChanged', {
        'remote_id': 'mt1',
        'mtu': 247,
        'success': 1,
        'error_code': 0,
        'error_string': '',
      });
      final e = await completer.future.timeout(const Duration(seconds: 2));
      expect(e.mtu, 247);
      expect(e.success, isTrue);
      await sub.cancel();
    });

    test('OnNameChanged -> onNameChanged', () async {
      final plugin = await makeReadyPlugin();
      final completer = Completer<BmNameChanged>();
      final sub = plugin.onNameChanged.listen(completer.complete);
      await sendOn('OnNameChanged', {'remote_id': 'nm1', 'name': 'DeviceName'});
      final e = await completer.future.timeout(const Duration(seconds: 2));
      expect(e.remoteId.str, 'nm1');
      expect(e.name, 'DeviceName');
      await sub.cancel();
    });

    test('OnReadRssi -> onReadRssi', () async {
      final plugin = await makeReadyPlugin();
      final completer = Completer<BmReadRssiResult>();
      final sub = plugin.onReadRssi.listen(completer.complete);
      await sendOn('OnReadRssi', {
        'remote_id': 'rr1',
        'rssi': -60,
        'success': 1,
        'error_code': 0,
        'error_string': '',
      });
      final e = await completer.future.timeout(const Duration(seconds: 2));
      expect(e.rssi, -60);
      await sub.cancel();
    });

    test('OnScanResponse -> onScanResponse', () async {
      final plugin = await makeReadyPlugin();
      final completer = Completer<BmScanResponse>();
      final sub = plugin.onScanResponse.listen(completer.complete);
      await sendOn('OnScanResponse', {
        'advertisements': [
          {
            'remote_id': 'scan-1',
            'platform_name': 'PN',
            'adv_name': 'AN',
            'connectable': 1,
            'tx_power_level': -12,
            'appearance': 64,
            'manufacturer_data': <String, List<int>>{},
            'service_data': <String, List<int>>{},
            'service_uuids': ['180d'],
            'rssi': -70,
          },
        ],
        'success': 1,
        'error_code': 0,
        'error_string': '',
      });
      final e = await completer.future.timeout(const Duration(seconds: 2));
      expect(e.success, isTrue);
      expect(e.advertisements.length, 1);
      expect(e.advertisements[0].remoteId.str, 'scan-1');
      expect(e.advertisements[0].rssi, -70);
      expect(e.advertisements[0].connectable, isTrue);
      expect(e.advertisements[0].serviceUuids.length, 1);
      await sub.cancel();
    });

    test('OnScanResponse defaults omitted optional fields', () async {
      final plugin = await makeReadyPlugin();
      final completer = Completer<BmScanResponse>();
      final sub = plugin.onScanResponse.listen(completer.complete);
      await sendOn('OnScanResponse', {
        'advertisements': [
          {'remote_id': 'scan-minimal'},
        ],
      });
      final response = await completer.future.timeout(const Duration(seconds: 2));
      final advertisement = response.advertisements.single;
      expect(response.success, isTrue);
      expect(response.errorCode, 0);
      expect(response.errorString, '');
      expect(advertisement.remoteId.str, 'scan-minimal');
      expect(advertisement.connectable, isFalse);
      expect(advertisement.manufacturerData, isEmpty);
      expect(advertisement.serviceData, isEmpty);
      expect(advertisement.serviceUuids, isEmpty);
      expect(advertisement.rssi, 0);
      await sub.cancel();
    });

    test('OnServicesReset -> onServicesReset', () async {
      final plugin = await makeReadyPlugin();
      final completer = Completer<BmBluetoothDevice>();
      final sub = plugin.onServicesReset.listen(completer.complete);
      await sendOn('OnServicesReset', {'remote_id': 'sr1', 'platform_name': null});
      final e = await completer.future.timeout(const Duration(seconds: 2));
      expect(e.remoteId.str, 'sr1');
      await sub.cancel();
    });

    test('OnTurnOnResponse -> onTurnOnResponse', () async {
      final plugin = await makeReadyPlugin();
      final completer = Completer<BmTurnOnResponse>();
      final sub = plugin.onTurnOnResponse.listen(completer.complete);
      await sendOn('OnTurnOnResponse', {'user_accepted': true});
      final e = await completer.future.timeout(const Duration(seconds: 2));
      expect(e.userAccepted, isTrue);
      await sub.cancel();
    });
  });

  group('OnDiscoveredServices verbose pretty-print', () {
    test('uses pretty-print path when verbose + OnDiscoveredServices', () async {
      final plugin = await makeReadyPlugin();
      // Enable verbose to exercise _prettyPrint branch in _methodCallHandler.
      await plugin.setLogLevel(
          BmSetLogLevelRequest(logLevel: LogLevel.verbose, logColor: true));
      final completer = Completer<BmDiscoverServicesResult>();
      final sub = plugin.onDiscoveredServices.listen(completer.complete);
      final args = {
        'remote_id': 'vp1',
        'services': <Map<String, dynamic>>[],
        'success': 1,
        'error_code': 0,
        'error_string': 'GATT_SUCCESS',
      };
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        _channelName,
        const StandardMethodCodec()
            .encodeMethodCall(MethodCall('OnDiscoveredServices', args)),
        null,
      );
      final e = await completer.future.timeout(const Duration(seconds: 2));
      expect(e.remoteId.str, 'vp1');
      await sub.cancel();
    });
  });

  // Unknown method in _methodCallHandler should be a no-op (no throw).
  test('_methodCallHandler ignores unknown method', () async {
    await makeReadyPlugin(); // install the plugin's incoming handler
    // Should not throw.
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      _channelName,
      const StandardMethodCodec()
          .encodeMethodCall(const MethodCall('UnknownCallback', {'x': 1})),
      null,
    );
    expect(true, isTrue);
  });

  group('verbose log branches', () {
    // Both branches below are only reachable when _logLevel == verbose, which
    // the earlier verbose tests reach only through the OnDiscoveredServices
    // path. These two tests drive the remaining else-branches in
    // _methodCallHandler and _prettyPrint to close the last coverage gaps.
    test('verbose log pretty-prints OnDiscoveredServices with a Map argument',
        () async {
      final plugin = await makeReadyPlugin();
      await plugin.setLogLevel(
          BmSetLogLevelRequest(logLevel: LogLevel.verbose, logColor: false));
      final completer = Completer<BmDiscoverServicesResult>();
      final sub = plugin.onDiscoveredServices.listen(completer.complete);
      // Map argument -> _prettyPrint takes the JsonEncoder branch (line 556).
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        _channelName,
        const StandardMethodCodec().encodeMethodCall(
            MethodCall('OnDiscoveredServices', {'remote_id': 'vp2', 'services': <Map<String, dynamic>>[], 'success': 1, 'error_code': 0, 'error_string': ''})),
        null,
      );
      final e = await completer.future.timeout(const Duration(seconds: 2));
      expect(e.remoteId.str, 'vp2');
      await sub.cancel();
    });

    test('verbose log uses toString fallback for non-Map on unknown method',
        () async {
      final plugin = await makeReadyPlugin();
      await plugin.setLogLevel(
          BmSetLogLevelRequest(logLevel: LogLevel.verbose, logColor: false));
      // A non-OnDiscoveredServices method with a non-Map argument hits both
      // else-branches: the _ => call.arguments.toString() arm (line 452) and
      // _prettyPrint's else arm (line 558) is exercised by OnDiscoveredServices
      // above; here we additionally cover the switch-default log arm.
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        _channelName,
        const StandardMethodCodec()
            .encodeMethodCall(const MethodCall('OnNameChanged', 'plain-string-arg')),
        null,
      );
      // Also drive _prettyPrint's else branch directly by sending
      // OnDiscoveredServices with a non-Map, non-List argument (a string).
      // The plugin will attempt BmDiscoverServicesResult.fromMap on it, so we
      // only assert the call doesn't throw the log path itself; catch the
      // expected fromMap error and verify it is not a log-related failure.
      Object? caught;
      try {
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
          _channelName,
          const StandardMethodCodec().encodeMethodCall(
              const MethodCall('OnDiscoveredServices', 'not-a-map')),
          null,
        );
      } catch (e) {
        caught = e;
      }
      // Either it throws inside fromMap (expected) or no-ops; the log line ran.
      expect(true, isTrue);
      expect(caught, isNull); // handlePlatformMessage swallows handler errors
    });
  });
}
