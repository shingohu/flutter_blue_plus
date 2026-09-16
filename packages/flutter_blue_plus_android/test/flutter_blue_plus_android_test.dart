import 'package:flutter/services.dart';
import 'package:flutter_blue_plus_android/flutter_blue_plus_android.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('registers the method call handler lazily and only once', () async {
    const channel = MethodChannel('flutter_blue_plus/methods');
    const codec = StandardMethodCodec();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var constructorHandlerCalls = 0;
    var replacementHandlerCalls = 0;

    messenger.setMockMethodCallHandler(channel, (call) async {
      return call.method == 'flutterRestart' ? 0 : true;
    });
    messenger.setMessageHandler(channel.name, (message) async {
      constructorHandlerCalls++;
      return codec.encodeSuccessEnvelope(null);
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMessageHandler(channel.name, null);
    });

    final plugin = FlutterBluePlusAndroid();
    await messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(const MethodCall('UnknownCallback')),
      null,
    );
    expect(constructorHandlerCalls, 1);

    await plugin.isSupported(BmIsSupportedRequest());
    await messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(const MethodCall('UnknownCallback')),
      null,
    );
    expect(constructorHandlerCalls, 1);

    messenger.setMessageHandler(channel.name, (message) async {
      replacementHandlerCalls++;
      return codec.encodeSuccessEnvelope(null);
    });
    await plugin.isSupported(BmIsSupportedRequest());
    await messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(const MethodCall('UnknownCallback')),
      null,
    );
    expect(replacementHandlerCalls, 1);
  });
}
