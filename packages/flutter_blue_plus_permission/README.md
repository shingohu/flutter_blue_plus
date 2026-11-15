# flutter_blue_plus_permission

BLE permission and Bluetooth adapter helpers for [`flutter_blue_plus`][1].

This plugin ships with `flutter_blue_plus` as an implementation detail. You do
**not** need to add it to your `pubspec.yaml`: use the three helpers exposed
by the main package — `FlutterBluePlus.checkPermission()`,
`FlutterBluePlus.requestPermission()` and `FlutterBluePlus.openPermissionSetting()`.

Supported platforms: Android, iOS, OpenHarmony (OHOS).

## Usage

```dart
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

// Ask for all BLE-related runtime permissions.
final granted = await FlutterBluePlus.requestPermission();

// Check permissions before scanning.
final ok = await FlutterBluePlus.checkPermission();

// Let the user enable a permanently denied permission in system settings.
if (!ok) {
  await FlutterBluePlus.openPermissionSetting();
}
```

## Implementation API (internal)

The table below documents `FlutterBluePlusPermission.instance`, the
implementation class. The singleton and its members are **not** part of the
public `flutter_blue_plus` API — the main package exposes its own static
`checkPermission()`, `requestPermission()` and `openPermissionSetting()` wrappers.

| Member | Description | Platform |
| --- | --- | --- |
| `requestPermission()` | Request all BLE-related permissions; returns whether they were granted | all |
| `checkPermission()` | Whether BLE permissions are currently granted | all |
| `openPermissionSetting()` | Open app settings for manual permission changes; on Android/iOS resolves only after the user returns | all |
| `isReady()` | Whether all required permissions and adapter settings are satisfied | all |
| `openBluetoothAdapter()` | Enable via system API (Android/OHOS) or open Settings (iOS) | all |
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

## iOS authorization boundaries

Only `CBManagerAuthorization.allowedAlways` grants access on iOS 13+.
`denied` and `restricted` both return `false`; `notDetermined` waits for
CoreBluetooth's system decision. An authorized app may still have Bluetooth
powered off: permission and adapter readiness are separate checks.

Run `python3 test/ios_authorization/run.py` from this package on macOS to
compile the production permission decisions against a fake OS boundary.
The check uses actual CoreBluetooth enum types and covers resolved and pending
requests, including restricted access and later OS callbacks. It does not
access Bluetooth hardware or replace real-device system-dialog testing.

## License

BSD 3-Clause. See [LICENSE](./LICENSE).

[1]: https://github.com/shingohu/flutter_blue_plus
