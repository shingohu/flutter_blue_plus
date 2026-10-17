import 'dart:async';
import 'package:bluez/bluez.dart';
import 'package:flutter_blue_plus_linux/flutter_blue_plus_linux.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeBlueZ extends BlueZClient {
  int connects = 0;
  int deviceListeners = 0;
  Completer<void> gate = Completer<void>();
  @override
  Future<void> connect() {
    connects++;
    return gate.future;
  }

  @override
  Stream<BlueZDevice> get deviceAdded => Stream.multi((out) {
        deviceListeners++;
      }, isBroadcast: true);
}

void main() {
  test('concurrent startup shares BlueZ connect and registers one listener', () async {
    final client = FakeBlueZ();
    final plugin = FlutterBluePlusLinux(client: client);
    final supported = plugin.isSupported(BmIsSupportedRequest());
    final name = plugin.getAdapterName(BmBluetoothAdapterNameRequest());
    expect(client.connects, 1);
    client.gate.complete();
    expect(await supported, false);
    expect((await name).adapterName, '');
    await Future<void>.delayed(Duration.zero);
    expect(client.deviceListeners, 1);
  });

  test('a failed shared startup can be retried once', () async {
    final client = FakeBlueZ();
    final plugin = FlutterBluePlusLinux(client: client);
    final a = expectLater(plugin.isSupported(BmIsSupportedRequest()), throwsStateError);
    final b = expectLater(plugin.getAdapterName(BmBluetoothAdapterNameRequest()), throwsStateError);
    client.gate.completeError(StateError('BlueZ unavailable'));
    await Future.wait([a, b]);
    client.gate = Completer<void>();
    final retry = plugin.isSupported(BmIsSupportedRequest());
    expect(client.connects, 2);
    client.gate.complete();
    expect(await retry, false);
    await Future<void>.delayed(Duration.zero);
    expect(client.deviceListeners, 1);
  });
}
