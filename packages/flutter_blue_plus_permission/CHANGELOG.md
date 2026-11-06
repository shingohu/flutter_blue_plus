## Unreleased
* **[Breaking]** Rename the package and its `MethodChannel` from `ble_permission` to `flutter_blue_plus_permission`.
* **[Breaking]** Rename the Dart API `BlePermission` to `FlutterBluePlusPermission` and the native plugin classes `BLEPermissionPlugin` / `BLEPermissionManager` to `FlutterBluePlusPermissionPlugin` / `FlutterBluePlusPermissionManager`.
* **[Breaking]** Replace the `FlutterBluePlus.permission` getter with `FlutterBluePlus.checkPermission()`, `FlutterBluePlus.requestPermission()` and `FlutterBluePlus.openPermission()`. The adapter, location-service and hotspot helpers remain available only inside this implementation package.
* **[Fix]** Align the Android package, Gradle namespace and manifest with `com.shingo.flutter_blue_plus_permission`; document the three main-package permission entry points.
* **[Docs]** Replace the Flutter plugin template README and CHANGELOG; add a BSD 3-Clause LICENSE, linter config, metadata and basic tests.

## 0.0.1
* Initial release: BLE permission, Bluetooth adapter and location-service helpers for Android, iOS and OpenHarmony.
