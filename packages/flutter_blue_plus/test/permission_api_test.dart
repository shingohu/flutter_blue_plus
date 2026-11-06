// The main package only forwards three permission calls to the implementation
// plugin. Guard the channel and method names here: a mismatch fails silently
// at runtime on device.
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channelName = 'flutter_blue_plus_permission';
  const codec = StandardMethodCodec();

  late TestDefaultBinaryMessenger messenger;

  setUp(() {
    messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMessageHandler(channelName, null);
  });

  tearDown(() {
    messenger.setMockMessageHandler(channelName, null);
  });

  test('checkPermission forwards to the permission channel', () async {
    final calls = <String>[];
    messenger.setMockMessageHandler(channelName, (ByteData? message) async {
      calls.add(codec.decodeMethodCall(message).method);
      return codec.encodeSuccessEnvelope(true);
    });

    expect(await FlutterBluePlus.checkPermission(), isTrue);
    expect(calls, <String>['checkPermission']);
  });

  test('requestPermission forwards to the permission channel', () async {
    final calls = <String>[];
    messenger.setMockMessageHandler(channelName, (ByteData? message) async {
      calls.add(codec.decodeMethodCall(message).method);
      return codec.encodeSuccessEnvelope(false);
    });

    expect(await FlutterBluePlus.requestPermission(), isFalse);
    expect(calls, <String>['requestPermission']);
  });

  test('openPermission forwards to the permission channel', () async {
    final calls = <String>[];
    messenger.setMockMessageHandler(channelName, (ByteData? message) async {
      calls.add(codec.decodeMethodCall(message).method);
      return codec.encodeSuccessEnvelope(true);
    });

    expect(await FlutterBluePlus.openPermission(), isTrue);
    expect(calls, <String>['openPermission']);
  });
}
