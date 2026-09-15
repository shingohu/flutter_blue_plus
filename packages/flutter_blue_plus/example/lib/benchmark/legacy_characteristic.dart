import 'package:flutter_blue_plus/flutter_blue_plus.dart';
// Benchmark-only access to the plugin's platform dependency.
// ignore: depend_on_referenced_packages
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';

// Preserve the pre-optimization getter for comparisons with production.
class BenchmarkLegacyCharacteristic extends BluetoothCharacteristic {
  BenchmarkLegacyCharacteristic(
      {required super.remoteId,
      super.primaryServiceUuid,
      required super.serviceUuid,
      required super.characteristicUuid,
      super.instanceId});

  @override
  Stream<List<int>> get onValueReceived =>
      FlutterBluePlusPlatform.instance.onCharacteristicReceived
          .where((p) => p.remoteId == remoteId)
          .where((p) => p.primaryServiceUuid == primaryServiceUuid)
          .where((p) => p.serviceUuid == serviceUuid)
          .where((p) => p.characteristicUuid == characteristicUuid)
          .where((p) => p.instanceId == instanceId)
          .where((p) => p.success == true)
          .map((c) => c.value);
}
