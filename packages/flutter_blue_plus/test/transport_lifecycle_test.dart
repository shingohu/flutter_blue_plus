// Regression tests for operation cancellation and native invocation deadlines.
import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

class Counted<T> {
  final controller = StreamController<T>.broadcast();
  int active = 0;
  late final Stream<T> stream = Stream<T>.multi((out) {
    active++;
    final sub = controller.stream.listen(
      out.addSync,
      onError: out.addErrorSync,
    );
    out.onCancel = () {
      active--;
      return sub.cancel();
    };
  }, isBroadcast: true);
}

final class AuditPlatform extends FlutterBluePlusPlatform {
  final received = Counted<BmCharacteristicData>();
  final connection = Counted<BmConnectionStateResponse>();
  final adapter = Counted<BmBluetoothAdapterState>();
  final written = Counted<BmCharacteristicData>();
  final descriptorRead = Counted<BmDescriptorData>();
  final descriptorWritten = Counted<BmDescriptorData>();
  bool failAdapterListen = false;
  bool reject = true;
  bool autoReply = false;
  int reads = 0;
  @override
  Stream<BmCharacteristicData> get onCharacteristicWritten => written.stream;
  @override
  Stream<BmDescriptorData> get onDescriptorRead => descriptorRead.stream;
  @override
  Stream<BmDescriptorData> get onDescriptorWritten => descriptorWritten.stream;
  @override
  Future<bool> writeCharacteristic(
          BmWriteCharacteristicRequest request) async =>
      throw StateError('write rejected');
  @override
  Future<bool> readDescriptor(BmReadDescriptorRequest request) async =>
      throw StateError('descriptor rejected');
  @override
  Future<bool> writeDescriptor(BmWriteDescriptorRequest request) async =>
      throw StateError('descriptor write rejected');

  Completer<bool>? nativeGate;
  @override
  Stream<BmCharacteristicData> get onCharacteristicReceived => received.stream;
  @override
  Stream<BmConnectionStateResponse> get onConnectionStateChanged =>
      connection.stream;
  @override
  Stream<BmBluetoothAdapterState> get onAdapterStateChanged {
    if (failAdapterListen) throw StateError('adapter stream failed');
    return adapter.stream;
  }

  @override
  Future<bool> isSupported(BmIsSupportedRequest request) async => true;
  @override
  Future<BmBluetoothAdapterState> getAdapterState(
    BmBluetoothAdapterStateRequest request,
  ) async =>
      BmBluetoothAdapterState(adapterState: BmAdapterStateEnum.on);
  @override
  Future<bool> readCharacteristic(BmReadCharacteristicRequest request) async {
    reads++;
    if (reject) throw StateError('native rejected request');
    if (nativeGate != null) return nativeGate!.future;
    if (autoReply) {
      received.controller.add(BmCharacteristicData(
          remoteId: request.remoteId,
          primaryServiceUuid: request.primaryServiceUuid,
          serviceUuid: request.serviceUuid,
          characteristicUuid: request.characteristicUuid,
          instanceId: request.instanceId,
          value: [reads],
          success: true,
          errorCode: 0,
          errorString: ''));
    }
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('rejected, timed-out and interrupted requests release all subscriptions',
      () async {
    final platform = AuditPlatform();
    FlutterBluePlusPlatform.instance = platform;
    await FlutterBluePlus.isSupported;
    final remote = DeviceIdentifier('audit');
    Future<void> state(BmConnectionStateEnum value) async {
      platform.connection.controller.add(BmConnectionStateResponse(
          remoteId: remote,
          connectionState: value,
          disconnectReasonCode: null,
          disconnectReasonString: null));
      await Future<void>.delayed(Duration.zero);
    }

    Future<void> reconnect() async {
      await state(BmConnectionStateEnum.disconnected);
      await state(BmConnectionStateEnum.connected);
    }

    await state(BmConnectionStateEnum.connected);
    final characteristic = BluetoothCharacteristic(
        remoteId: remote,
        serviceUuid: Guid('180f'),
        characteristicUuid: Guid('2a19'));
    final descriptor = BluetoothDescriptor(
        remoteId: remote,
        serviceUuid: Guid('180f'),
        characteristicUuid: Guid('2a19'),
        descriptorUuid: Guid('2901'));
    final writtenBase = platform.written.active;
    final descReadBase = platform.descriptorRead.active;
    final descWrittenBase = platform.descriptorWritten.active;
    final receivedBase = platform.received.active;
    final connectionBase = platform.connection.active;
    final adapterBase = platform.adapter.active;
    void checkClean() {
      expect(platform.received.active, receivedBase);
      expect(platform.written.active, writtenBase);
      expect(platform.descriptorRead.active, descReadBase);
      expect(platform.descriptorWritten.active, descWrittenBase);
      expect(platform.connection.active, connectionBase);
      expect(platform.adapter.active, adapterBase);
    }

    for (var i = 0; i < 20; i++) {
      await expectLater(characteristic.read(), throwsStateError);
    }
    for (var i = 0; i < 20; i++) {
      await expectLater(characteristic.write([1]), throwsStateError);
      await expectLater(descriptor.read(), throwsStateError);
      await expectLater(descriptor.write([1]), throwsStateError);
    }
    expect(await characteristic.setNotifyValue(false), true);
    await characteristic.device.connect(mtu: null);
    await characteristic.device.disconnect(androidDelay: 0);
    checkClean();
    platform.reject = false;
    for (var i = 0; i < 5; i++) {
      await expectLater(
          characteristic.read(timeout: const Duration(milliseconds: 2)),
          throwsA(isA<FlutterBluePlusException>()));
      checkClean();
      await expectLater(
          characteristic.read(),
          throwsA(predicate((Object e) =>
              e is FlutterBluePlusException &&
              e.description!.contains('disconnect and reconnect'))));
      checkClean();
      await reconnect();
    }
    platform.nativeGate = Completer<bool>();
    final blocked =
        characteristic.read(timeout: const Duration(milliseconds: 2));
    await expectLater(blocked.timeout(const Duration(seconds: 1)),
        throwsA(isA<FlutterBluePlusException>()));
    checkClean();
    platform.nativeGate!.completeError(StateError('late native rejection'));
    platform.nativeGate = null;
    await Future<void>.delayed(Duration.zero);
    await reconnect();
    platform.nativeGate = Completer<bool>();
    final interrupted = characteristic.read();
    final failure =
        expectLater(interrupted, throwsA(isA<FlutterBluePlusException>()));
    await Future<void>.delayed(Duration.zero);
    await state(BmConnectionStateEnum.disconnected);
    await failure;
    checkClean();
    platform.nativeGate!.complete(true);
    platform.nativeGate = null;
    await reconnect();
    platform.nativeGate = Completer<bool>();
    final adapterInterrupted = characteristic.read();
    final adapterFailure = expectLater(
        adapterInterrupted, throwsA(isA<FlutterBluePlusException>()));
    await Future<void>.delayed(Duration.zero);
    platform.adapter.controller
        .add(BmBluetoothAdapterState(adapterState: BmAdapterStateEnum.off));
    await adapterFailure;
    checkClean();
    platform.nativeGate!
        .completeError(StateError('native rejected after adapter shutdown'));
    platform.nativeGate = null;
    platform.adapter.controller
        .add(BmBluetoothAdapterState(adapterState: BmAdapterStateEnum.on));
    await reconnect();
    final result = characteristic.read();
    await Future<void>.delayed(Duration.zero);
    platform.received.controller.add(BmCharacteristicData(
        remoteId: remote,
        primaryServiceUuid: null,
        serviceUuid: Guid('180f'),
        characteristicUuid: Guid('2a19'),
        instanceId: 0,
        value: [42],
        success: true,
        errorCode: 0,
        errorString: ''));
    expect(await result, [42]);
    checkClean();
    // A queue timeout cancels just that waiter and does not release its owner's lock.
    platform.nativeGate = Completer<bool>();
    final owner = characteristic.read(timeout: const Duration(seconds: 2));
    await Future<void>.delayed(Duration.zero);
    final beforeQueued = platform.reads;
    await expectLater(
        characteristic.read(timeout: const Duration(milliseconds: 2)),
        throwsA(isA<FlutterBluePlusException>()));
    expect(platform.reads, beforeQueued);
    platform.autoReply = true;
    final next = characteristic.read();
    platform.received.controller.add(BmCharacteristicData(
        remoteId: remote,
        primaryServiceUuid: null,
        serviceUuid: Guid('180f'),
        characteristicUuid: Guid('2a19'),
        instanceId: 0,
        value: [99],
        success: true,
        errorCode: 0,
        errorString: ''));
    platform.nativeGate!.complete(true);
    platform.nativeGate = null;
    expect(await owner, [99]);
    await next;
    final start = platform.reads;
    final burst =
        await Future.wait(List.generate(200, (_) => characteristic.read()));
    expect(burst.map((value) => value.single),
        List.generate(200, (i) => start + i + 1));
    checkClean();
    platform.failAdapterListen = true;
    await expectLater(characteristic.read(), throwsStateError);
    platform.failAdapterListen = false;
    await characteristic.read();
    checkClean();
    // Idle mutex eviction must not relax the documented mode-change restriction.
    expect(
        () => FlutterBluePlus.setOperationQueueMode(OperationQueueMode.global),
        throwsStateError);
  });
}
