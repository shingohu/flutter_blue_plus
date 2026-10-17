import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

class CountingIdentifier extends DeviceIdentifier {
  static int comparisons = 0;
  CountingIdentifier(super.str);
  @override
  bool operator ==(Object other) {
    comparisons++;
    return super == other;
  }

  @override
  int get hashCode => super.hashCode;
}

final class FanoutPlatform extends FlutterBluePlusPlatform {
  final received = StreamController<BmCharacteristicData>.broadcast();
  @override
  Stream<BmCharacteristicData> get onCharacteristicReceived => received.stream;
}

void main() {
  test(
    'production public notification streams filter once per active listener',
    () async {
      for (final count in [10, 100, 500]) {
        final platform = FanoutPlatform();
        FlutterBluePlusPlatform.instance = platform;
        final remote = CountingIdentifier('audit');
        final subscriptions = <StreamSubscription<List<int>>>[];
        var delivered = 0;
        for (var i = 0; i < count; i++) {
          final c = BluetoothCharacteristic(
            remoteId: const DeviceIdentifier('audit'),
            serviceUuid: Guid('180f'),
            characteristicUuid: Guid((0x2a00 + i).toRadixString(16)),
          );
          subscriptions.add(
            c.onValueReceived.listen((_) {
              delivered++;
            }),
          );
        }
        CountingIdentifier.comparisons = 0;
        for (var i = 0; i < 100; i++) {
          platform.received.add(
            BmCharacteristicData(
              remoteId: remote,
              primaryServiceUuid: null,
              serviceUuid: Guid('180f'),
              characteristicUuid: Guid('2a00'),
              instanceId: 0,
              value: [i],
              success: true,
              errorCode: 0,
              errorString: '',
            ),
          );
        }
        await Future<void>.delayed(Duration.zero);
        expect(delivered, 100);
        expect(CountingIdentifier.comparisons, count * 100);
        print(
          'AUDIT fanout listeners=$count events=100 routePredicates=${CountingIdentifier.comparisons}',
        );
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
        await platform.received.close();
      }
    },
  );
}
