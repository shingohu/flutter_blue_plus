import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

final class FollowupPlatform extends FlutterBluePlusPlatform {
  final adapter = StreamController<BmBluetoothAdapterState>.broadcast();
  final turnOnEvents = StreamController<BmTurnOnResponse>.broadcast();
  final connections = StreamController<BmConnectionStateResponse>.broadcast();
  Completer<BmBluetoothAdapterState> adapterGate = Completer();
  final firstConnect = Completer<bool>();
  final earlyCancel = Completer<bool>();
  final finalCancel = Completer<bool>();
  int connectCalls = 0;
  int disconnectCalls = 0;
  bool rejectCleanup = false;
  bool autoConnectReply = false;
  @override
  Future<bool> isSupported(BmIsSupportedRequest request) async => true;
  @override
  Stream<BmBluetoothAdapterState> get onAdapterStateChanged => adapter.stream;
  @override
  Stream<BmTurnOnResponse> get onTurnOnResponse => turnOnEvents.stream;
  @override
  Stream<BmConnectionStateResponse> get onConnectionStateChanged => connections.stream;
  @override
  Future<BmBluetoothAdapterState> getAdapterState(BmBluetoothAdapterStateRequest request) => adapterGate.future;
  @override
  Future<bool> turnOn(BmTurnOnRequest request) async {
    turnOnEvents.add(BmTurnOnResponse(userAccepted: true));
    return true;
  }

  void state(DeviceIdentifier remote, BmConnectionStateEnum state) {
    connections.add(BmConnectionStateResponse(
        remoteId: remote, connectionState: state, disconnectReasonCode: null, disconnectReasonString: null));
  }

  @override
  Future<bool> connect(BmConnectRequest request) {
    connectCalls++;
    if (request.remoteId.str == 'blocked' && connectCalls == 1) return firstConnect.future;
    if (autoConnectReply) state(request.remoteId, BmConnectionStateEnum.connected);
    return Future.value(true);
  }

  @override
  Future<bool> disconnect(BmDisconnectRequest request) async {
    disconnectCalls++;
    if (disconnectCalls == 1) return earlyCancel.future;
    if (disconnectCalls == 2) return finalCancel.future;
    if (rejectCleanup) throw StateError('cleanup rejected');
    state(request.remoteId, BmConnectionStateEnum.disconnected);
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('timeouts cancel independently and connect retries wait for native cancellation', () async {
    final platform = FollowupPlatform();
    FlutterBluePlusPlatform.instance = platform;
    await FlutterBluePlus.isSupported;
    await expectLater(
      FlutterBluePlus.turnOn(timeout: const Duration(milliseconds: 10)).timeout(const Duration(seconds: 1)),
      throwsA(isA<FlutterBluePlusException>()),
    );
    platform.adapterGate.completeError(StateError('late state query failure'));
    await Future<void>.delayed(Duration.zero);
    platform.adapterGate = Completer();
    final powerOn = FlutterBluePlus.turnOn(timeout: const Duration(seconds: 1));
    await Future<void>.delayed(Duration.zero);
    // An ON event can complete turnOn even if the state query remains pending.
    platform.adapter.add(BmBluetoothAdapterState(adapterState: BmAdapterStateEnum.on));
    await powerOn;
    platform.adapterGate.completeError(StateError('query rejected after ON event'));
    platform.adapter.add(BmBluetoothAdapterState(adapterState: BmAdapterStateEnum.off));
    await Future<void>.delayed(Duration.zero);
    platform.adapterGate = Completer()..complete(BmBluetoothAdapterState(adapterState: BmAdapterStateEnum.on));
    // An authoritative ON query also works when the cached state is still OFF.
    await FlutterBluePlus.turnOn(timeout: const Duration(milliseconds: 50));
    expect(FlutterBluePlus.adapterStateNow, BluetoothAdapterState.on);
    platform.adapter.add(BmBluetoothAdapterState(adapterState: BmAdapterStateEnum.off));
    await Future<void>.delayed(Duration.zero);
    platform.adapterGate = Completer();
    bool powered = false;
    final newerEvent = FlutterBluePlus.turnOn(timeout: const Duration(seconds: 1)).then((_) => powered = true);
    await Future<void>.delayed(Duration.zero);
    platform.adapter.add(BmBluetoothAdapterState(adapterState: BmAdapterStateEnum.off));
    await Future<void>.delayed(Duration.zero);
    platform.adapterGate.complete(BmBluetoothAdapterState(adapterState: BmAdapterStateEnum.on));
    await Future<void>.delayed(Duration.zero);
    expect(powered, false, reason: 'A query snapshot must not replace a newer OFF event');
    expect(FlutterBluePlus.adapterStateNow, BluetoothAdapterState.off);
    platform.adapter.add(BmBluetoothAdapterState(adapterState: BmAdapterStateEnum.on));
    await newerEvent;

    final device = BluetoothDevice(remoteId: DeviceIdentifier('blocked'));
    await expectLater(
        device.connect(mtu: null, timeout: const Duration(milliseconds: 10)), throwsA(isA<FlutterBluePlusException>()));
    expect(platform.disconnectCalls, 1);
    platform.state(device.remoteId, BmConnectionStateEnum.connected); // Late first-attempt event.
    await expectLater(
        device.connect(mtu: null, timeout: const Duration(milliseconds: 10)), throwsA(isA<FlutterBluePlusException>()));
    expect(platform.connectCalls, 1);
    // Even a stale connected state cannot unlock GATT while cancellation is pending.
    final characteristic =
        BluetoothCharacteristic(remoteId: device.remoteId, serviceUuid: Guid('180f'), characteristicUuid: Guid('2a19'));
    await expectLater(characteristic.read(), throwsA(isA<FlutterBluePlusException>()));
    await expectLater(device.disconnect(queue: false, androidDelay: 0, timeout: const Duration(milliseconds: 10)),
        throwsA(isA<FlutterBluePlusException>()));
    expect(platform.disconnectCalls, 1);
    // The pending barrier belongs only to this device.
    platform.autoConnectReply = true;
    await BluetoothDevice(remoteId: DeviceIdentifier('other')).connect(mtu: null);
    expect(platform.connectCalls, 2);

    final retry = device.connect(mtu: null);
    await Future<void>.delayed(Duration.zero);
    platform.firstConnect.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(platform.disconnectCalls, 1, reason: 'Early cancellation must settle before the final cancellation');
    platform.earlyCancel.complete(false);
    await Future<void>.delayed(Duration.zero);
    expect(platform.disconnectCalls, 2);
    expect(platform.connectCalls, 2);
    platform.finalCancel.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(platform.connectCalls, 2, reason: 'A native method reply is not a disconnection acknowledgement');
    platform.state(device.remoteId, BmConnectionStateEnum.disconnected);
    await retry;
    expect(platform.connectCalls, 3);

    // Native rejection during cleanup keeps the fence; an explicit disconnect can retry it.
    platform.autoConnectReply = false;
    final failed = BluetoothDevice(remoteId: DeviceIdentifier('failed-cleanup'));
    platform.rejectCleanup = true;
    await expectLater(
        failed.connect(mtu: null, timeout: const Duration(milliseconds: 10)), throwsA(isA<FlutterBluePlusException>()));
    await Future<void>.delayed(Duration.zero);
    final beforeRetry = platform.connectCalls;
    await expectLater(failed.connect(mtu: null), throwsStateError);
    expect(platform.connectCalls, beforeRetry);
    platform.rejectCleanup = false;
    await failed.disconnect(queue: false, androidDelay: 0);
    platform.autoConnectReply = true;
    await failed.connect(mtu: null);
    platform.adapter.add(BmBluetoothAdapterState(adapterState: BmAdapterStateEnum.off));
    await Future<void>.delayed(Duration.zero);
    final beforeDisconnect = platform.disconnectCalls;
    await failed.disconnect(queue: false, androidDelay: 0);
    expect(platform.disconnectCalls, beforeDisconnect + 1,
        reason: 'Cleanup must still reach native while adapter is OFF');
  });
}
