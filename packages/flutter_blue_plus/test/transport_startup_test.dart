// Public API startup must share platform reset and recover from failures.
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_blue_plus_android/flutter_blue_plus_android.dart';
import 'package:flutter_blue_plus_darwin/flutter_blue_plus_darwin.dart';
import 'package:flutter_blue_plus_ohos/flutter_blue_plus_ohos.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final factory in <FlutterBluePlusPlatform Function()>[
    FlutterBluePlusAndroid.new,
    FlutterBluePlusDarwin.new,
    FlutterBluePlusOhos.new
  ]) {
    test('concurrent public getters share one flutterRestart: $factory', () async {
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('flutter_blue_plus/methods');
      final gates = <Completer<int>>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'flutterRestart') {
          final gate = Completer<int>();
          gates.add(gate);
          return gate.future;
        }
        if (call.method == 'getAdapterName') return 'audit';
        return true;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      FlutterBluePlusPlatform.instance = factory();
      final first = FlutterBluePlus.isSupported;
      final second = FlutterBluePlus.adapterName;
      await Future<void>.delayed(Duration.zero);
      final restartCount = gates.length;
      for (final gate in gates) {
        gate.complete(0);
      }
      expect(await first, true);
      expect(await second, 'audit');
      expect(restartCount, 1);
      print(
        'AUDIT startup: two concurrent public getters issued $restartCount native restarts',
      );
    });
    test('failed startup can be retried: $factory', () async {
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('flutter_blue_plus/methods');
      var restarts = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'flutterRestart') {
          restarts++;
          if (restarts == 1) throw PlatformException(code: 'startupFailed');
          return 0;
        }
        return true;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      FlutterBluePlusPlatform.instance = factory();
      final a = expectLater(FlutterBluePlus.isSupported, throwsA(isA<PlatformException>()));
      final b = expectLater(FlutterBluePlus.isSupported, throwsA(isA<PlatformException>()));
      await Future.wait([a, b]);
      expect(restarts, 1);
      expect(await FlutterBluePlus.isSupported, true);
      expect(restarts, 2);
    });
  }
}
