import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Implementation of the BLE permission helpers exposed by `flutter_blue_plus`.
///
/// The main package only forwards `checkPermission`, `requestPermission` and
/// `openPermission`; the remaining members (adapter state, location services,
/// hotspot probes) are internal to this package.
///
/// Provides methods to request and check BLE-related permissions,
/// manage Bluetooth adapter state, and handle platform-specific
/// requirements like location services on Android.
///
/// Usage:
/// ```dart
/// bool ok = await FlutterBluePlus.checkPermission();
/// bool granted = await FlutterBluePlus.requestPermission();
/// await FlutterBluePlus.openPermission();
/// ```
class FlutterBluePlusPermission {
  static const MethodChannel _channel = MethodChannel('flutter_blue_plus_permission');

  /// Singleton instance
  static final FlutterBluePlusPermission _instance = FlutterBluePlusPermission._();

  /// Returns the singleton instance of [FlutterBluePlusPermission].
  static FlutterBluePlusPermission get instance => _instance;

  /// Bluetooth adapter state notifier.
  /// Emits `true` when adapter is on, `false` when off, `null` when unknown.
  final ValueNotifier<bool?> bluetoothAdapterState = ValueNotifier(null);

  FlutterBluePlusPermission._() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == "onBluetoothAdapterStateChanged") {
        bluetoothAdapterState.value = call.arguments as bool?;
      }
    });
  }

  /// Open the Bluetooth adapter.
  /// - Android: opens via system API
  /// - iOS: navigates to Settings
  Future<bool> openBluetoothAdapter() async {
    return (await _channel.invokeMethod<bool>("openBluetoothAdapter")) ?? false;
  }

  /// Whether the Bluetooth adapter is currently enabled.
  Future<bool> get isBluetoothAdapterEnable async {
    return (await _channel.invokeMethod<bool>("isBluetoothAdapterEnable")) ?? false;
  }

  /// Check if all required permissions and settings are ready.
  Future<bool> isReady() async {
    return (await _channel.invokeMethod<bool>("isReady")) ?? false;
  }

  /// Check if location services need to be enabled.
  /// Android only (Android 6.0-9.0 / API 23-30).
  Future<bool> isNeedLocationService() async {
    if (!kIsWeb && Platform.isAndroid) {
      return (await _channel.invokeMethod<bool>("isNeedLocationService")) ?? false;
    }
    return false;
  }

  /// Whether GPS/location service is enabled.
  /// Android only (API 23-30 and HarmonyOS).
  Future<bool> get isLocationServiceEnable async {
    if (!kIsWeb && Platform.isAndroid) {
      return (await _channel.invokeMethod<bool>("isLocationServiceEnable")) ?? false;
    }
    throw UnsupportedError("isLocationServiceEnable is only supported on Android");
  }

  /// Open location service settings.
  /// Android only (API 23-30 and HarmonyOS).
  Future<bool> openLocationService() async {
    if (!kIsWeb && Platform.isAndroid) {
      return (await _channel.invokeMethod<bool>("openLocationService")) ?? false;
    }
    throw UnsupportedError("openLocationService is only supported on Android");
  }

  /// Request BLE-related permissions.
  /// Returns true if permissions are granted.
  Future<bool> requestPermission() async {
    return (await _channel.invokeMethod<bool>("requestPermission")) ?? false;
  }

  /// Check whether BLE-related permissions are granted.
  Future<bool> checkPermission() async {
    return (await _channel.invokeMethod<bool>("checkPermission")) ?? false;
  }

  /// Open app settings page to manually enable permissions.
  ///
  /// The result is the permission state observed after the user returns, not
  /// whether the settings page was opened: Android (app details page) and iOS
  /// (app settings page) complete only on `onActivityResult` /
  /// `applicationDidBecomeActive`; OHOS resolves when the system settings
  /// dialog closes. Note: on iOS, toggling Bluetooth permission will restart
  /// the app, so the returned future may never complete.
  Future<bool> openPermission() async {
    return (await _channel.invokeMethod<bool>("openPermission")) ?? false;
  }

  /// Whether Bluetooth tethering is enabled.
  /// Android only.
  Future<bool> isBluetoothTetheringEnable() async {
    if (!kIsWeb && Platform.isAndroid) {
      return (await _channel.invokeMethod<bool>("isBluetoothTetheringEnable")) ?? false;
    }
    throw UnsupportedError("isBluetoothTetheringEnable is only supported on Android");
  }

  /// Whether personal hotspot is enabled.
  /// iOS only.
  Future<bool> isPersonalHotspotEnabled() async {
    if (!kIsWeb && Platform.isIOS) {
      return (await _channel.invokeMethod<bool>("isPersonalHotspotEnabled")) ?? false;
    }
    throw UnsupportedError("isPersonalHotspotEnabled is only supported on iOS");
  }
}
