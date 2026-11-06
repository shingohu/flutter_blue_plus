# flutter_blue_plus_permission

BLE permission and Bluetooth adapter helpers for [`flutter_blue_plus`][1].

This plugin ships with `flutter_blue_plus` and is included automatically when
you depend on it. You do **not** need to add it to your `pubspec.yaml`; access
it through `FlutterBluePlus.permission`.

Supported platforms: Android, iOS, OpenHarmony (OHOS).

## Usage

```dart
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

// Ask for all BLE-related runtime permissions.
final granted = await FlutterBluePlus.permission.requestPermission();

// Check permissions and adapter state before scanning.
if (!await FlutterBluePlus.permission.isReady()) {
  await FlutterBluePlus.permission.openBluetoothAdapter();
}

// React to adapter state changes (true = on, false = off, null = unknown).
FlutterBluePlus.permission.bluetoothAdapterState.addListener(() {
  final state = FlutterBluePlus.permission.bluetoothAdapterState.value;
  // ...
});
```

## API

| Member | Description | Platform |
| --- | --- | --- |
| `requestPermission()` | Request all BLE-related permissions; returns whether they were granted | all |
| `checkPermission()` | Whether BLE permissions are currently granted | all |
| `openPermission()` | Open app settings for manual permission changes | all |
| `isReady()` | Whether all required permissions and adapter settings are satisfied | all |
| `openBluetoothAdapter()` | Enable the adapter (Android) or open Settings (iOS) | all |
| `isBluetoothAdapterEnable` | Whether the adapter is currently on | all |
| `bluetoothAdapterState` | `ValueNotifier<bool?>` emitting adapter state changes | all |
| `isNeedLocationService()` | Whether location services must be enabled for scanning | Android |
| `isLocationServiceEnable` | Whether location services are enabled | Android |
| `openLocationService()` | Open location service settings | Android |
| `isBluetoothTetheringEnable()` | Whether Bluetooth tethering is on | Android |
| `isPersonalHotspotEnabled()` | Whether the personal hotspot is on | iOS |

Android-only members throw `UnsupportedError` on other platforms, except
`isNeedLocationService()` which returns `false`. On iOS, toggling Bluetooth
permission in Settings restarts the app.

## License

BSD 3-Clause. See [LICENSE](./LICENSE).

[1]: https://github.com/shingohu/flutter_blue_plus
