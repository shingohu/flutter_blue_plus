import 'package:flutter_blue_plus/flutter_blue_plus.dart';
// Benchmark-only access to the plugin's platform dependency.
// ignore: depend_on_referenced_packages
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';

// Candidate only; never installed into the production plugin.
class BenchmarkFusedCharacteristic extends BluetoothCharacteristic {
  BenchmarkFusedCharacteristic(
      {required super.remoteId,
      super.primaryServiceUuid,
      required super.serviceUuid,
      required super.characteristicUuid,
      super.instanceId});

  @override
  Stream<List<int>> get onValueReceived =>
      FlutterBluePlusPlatform.instance.onCharacteristicReceived
          .where((p) =>
              p.remoteId == remoteId &&
              p.primaryServiceUuid == primaryServiceUuid &&
              p.serviceUuid == serviceUuid &&
              p.characteristicUuid == characteristicUuid &&
              p.instanceId == instanceId &&
              p.success == true)
          .map((c) => c.value);
}
