import Foundation
import CoreBluetooth
import Darwin

var failures = [String]()
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { failures.append(message) }
}
for (state, granted) in [(CBManagerAuthorization.denied, false), (.restricted, false), (.allowedAlways, true)] {
    CBCentralManager.authorization = state
    let manager = FlutterBluePlusPermissionManager()
    expect(manager.hasPermission() == granted, "read status \(state) must be \(granted)")
    var results = [Bool]()
    manager.requestPermission { results.append($0) }
    expect(results == [granted], "request resolved status \(state) must complete once with \(granted), got \(results)")
    CBCentralManager.latest?.emit(.allowedAlways, .poweredOn)
    expect(results == [granted], "later OS events must not repeat a completed callback")
}
for (state, adapter, granted) in [(CBManagerAuthorization.denied, CBManagerState.unauthorized, false), (.restricted, .unauthorized, false), (.allowedAlways, .poweredOff, true)] {
    CBCentralManager.authorization = .notDetermined
    let manager = FlutterBluePlusPermissionManager()
    var results = [Bool]()
    manager.requestPermission { results.append($0) }
    expect(results.isEmpty, "undetermined status must await the OS")
    CBCentralManager.latest?.emit(.notDetermined, .unknown)
    expect(results.isEmpty, "unknown adapter state does not authorize access")
    CBCentralManager.latest?.emit(state, adapter)
    expect(results == [granted], "OS decision \(state) must complete once with \(granted), got \(results)")
    CBCentralManager.latest?.emit(.allowedAlways, .poweredOn)
    expect(results == [granted], "a later state must not resurrect the completed request")
}
if failures.isEmpty { print("PASS: 6 authorization/read/request scenarios; no Bluetooth hardware accessed") }
else { failures.forEach { print("FAIL: \($0)") }; exit(1) }
