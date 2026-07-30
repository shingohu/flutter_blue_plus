import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_blue_plus_ohos/flutter_blue_plus_ohos.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel methodChannel =
      MethodChannel('flutter_blue_plus/methods');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    methodChannel,
    (message) => null,
  );

  test('TestConnectedDevices', () async {
    var connectedDevices = FlutterBluePlus.connectedDevices.length;
    expect(connectedDevices, 0);
  });

  test('TestGetAdapterState', () async {
    var adapterStateNow = await FlutterBluePlus.adapterStateNow;
    var getAdapterState = await methodChannel.invokeMethod("getAdapterState");
    expect(adapterStateNow, BluetoothAdapterState.unknown);
    expect(getAdapterState, null);
  });

  test('TestConnectedCount', () async {
    var connectedCount = await methodChannel.invokeMethod("connectedCount");
    expect(connectedCount, null);
  });
  test('TestGuid', () async {
    final guid = Guid.empty();
    // 预期的字节数组
    final expectedBytes = List<int>.filled(16, 0);
    // 验证返回的 Guid 的字节数组是否与预期一致
    expect(guid.bytes, equals(expectedBytes));
  });
  test('Test FromBytes should create a Guid with valid byte lengths-16',
      () async {
    final bytes16 = List<int>.generate(16, (index) => index);
    final guid16 = Guid.fromBytes(bytes16);
    expect(guid16.bytes, equals(bytes16));
  });
  test('fromString should create a Guid with valid GUID strings', () async {
    // 测试空字符串
    final guidEmpty = Guid.fromString('');
    expect(guidEmpty.bytes, equals(List<int>.filled(16, 0)));
    // 测试有效的 GUID 字符串
    final validGuidStr = '123e4567-e89b-12d3-a456-426614174000';
    final guidValid = Guid.fromString(validGuidStr);
    final expectedBytes = [
      0x12,
      0x3e,
      0x45,
      0x67,
      0xe8,
      0x9b,
      0x12,
      0xd3,
      0xa4,
      0x56,
      0x42,
      0x66,
      0x14,
      0x17,
      0x40,
      0x00
    ];
    expect(guidValid.bytes, equals(expectedBytes));
  });

  test('fromString should create a Guid with valid GUID strings', () {
    // 测试空字符串
    final guidEmpty = Guid.fromString('');
    expect(guidEmpty.bytes, equals(List<int>.filled(16, 0)));

    // 测试有效的 16 字节 GUID 字符串
    final validGuidStr16 = '123e4567e89b12d3a456426614174000';
    final guidValid16 = Guid.fromString(validGuidStr16);
    final expectedBytes16 = [
      0x12,
      0x3e,
      0x45,
      0x67,
      0xe8,
      0x9b,
      0x12,
      0xd3,
      0xa4,
      0x56,
      0x42,
      0x66,
      0x14,
      0x17,
      0x40,
      0x00
    ];
    expect(guidValid16.bytes, equals(expectedBytes16));
  });

  test('str128 should return the correct string for different byte lengths',
      () {
    // 测试 2 字节的 GUID
    final guid2 = Guid.fromString('1234');
    expect(guid2.str128, equals('00001234-0000-1000-8000-00805f9b34fb'));

    // 测试 4 字节的 GUID
    final guid4 = Guid.fromString('12345678');
    expect(guid4.str128, equals('12345678-0000-1000-8000-00805f9b34fb'));

    // 测试 16 字节的 GUID
    final guid16 = Guid.fromString('123e4567e89b12d3a456426614174000');
    expect(guid16.str128, equals('123e4567-e89b-12d3-a456-426614174000'));
  });

  test('str should return the correct string for different byte lengths', () {
    // 测试 2 字节的 GUID
    final guid2 = Guid.fromString('1234');
    expect(guid2.str, equals('1234'));

    // 测试 4 字节的 GUID
    final guid4 = Guid.fromString('12345678');
    expect(guid4.str, equals('12345678'));

    // 测试 16 字节的 GUID
    final guid16 = Guid.fromString('123e4567e89b12d3a456426614174000');
    expect(guid16.str, equals('123e4567-e89b-12d3-a456-426614174000'));
  });
}
