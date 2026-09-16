// Executes the production managers after TypeScript transpilation with mocked
// OHOS APIs. This checks logic, not ArkTS compilation or real BLE performance.
// FBP_TYPESCRIPT may point to DevEco's bundled typescript/lib/typescript.js.
const assert = require('node:assert/strict');
const { test } = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.FBP_TYPESCRIPT || 'typescript');
const source = path.resolve(__dirname, '../ohos/src/main/ets/components/plugin');

function loadManagers() {
  const modules = new Map();
  const noop = () => {};
  class List extends Array {
    add(value) { this.push(value); }
    get(index) { return this[index]; }
  }
  const mocks = {
    '@kit.ConnectivityKit': {
      ble: { GattWriteType: { WRITE: 0, WRITE_NO_RESPONSE: 1 } },
      connection: { getPairState: () => 2, BondState: { BOND_STATE_BONDED: 2 } },
      constant: { ProfileConnectionState: { STATE_DISCONNECTED: 0, STATE_CONNECTED: 2 } },
    },
    '@kit.ArkTS': { List, buffer: require('node:buffer').Buffer },
    '@kit.BasicServicesKit': { deviceInfo: { sdkApiVersion: 20 } },
    '@kit.PerformanceAnalysisKit': {
      hilog: { LogLevel: { DEBUG: 3, INFO: 4, WARN: 5, ERROR: 6, FATAL: 7 },
        isLoggable: () => true,
        debug: noop, info: noop, warn: noop, error: noop, fatal: noop },
    },
    '@ohos.bluetooth.access': { default: { getState: () => 2, BluetoothState: { STATE_ON: 2 } } },
  };
  function load(name) {
    if (mocks[name]) return mocks[name];
    assert.ok(name.startsWith('./'), `Unmocked native import: ${name}`);
    if (modules.has(name)) return modules.get(name).exports;
    const filename = path.join(source, name + '.ets');
    const output = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
      fileName: filename.replace(/\.ets$/, '.ts'),
      compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS },
    }).outputText;
    const module = { exports: {} };
    modules.set(name, module);
    vm.runInThisContext(`(function(require, module, exports) {${output}\n})`, { filename })(load, module, module.exports);
    return module.exports;
  }
  return load;
}

function deferred() {
  let resolve;
  const promise = new Promise(r => { resolve = r; });
  return { promise, resolve };
}

function fixture() {
  const load = loadManagers();
  const Cache = load('./GattCacheHolder').default;
  const Notify = load('./BleNotifyManager').default;
  const Characteristic = load('./BleCharacteristicManager').default;
  const events = [];
  const cccd = { serviceUuid: '180f', characteristicUuid: '2a19', descriptorUuid: '2902',
    descriptorValue: new ArrayBuffer(2) };
  const characteristic = { serviceUuid: '180f', characteristicUuid: '2a19',
    characteristicValueHandle: 7, characteristicValue: new Uint8Array([42]).buffer,
    descriptors: [cccd], properties: { read: true, write: true, notify: true } };
  const services = [{ serviceUuid: '180f', isPrimary: true, characteristics: [characteristic] }];
  let serviceReads = 0;
  const callbacks = new Map();
  const gatt = {
    getServices: async () => { serviceReads++; return services; },
    readCharacteristicValue: async c => c,
    writeCharacteristicValue: async () => {},
    setCharacteristicChangeNotification: async () => {},
    writeDescriptorValue: async () => {},
    on: (event, callback) => callbacks.set(event, callback),
    off: (event, callback) => { assert.equal(callbacks.get(event), callback); callbacks.delete(event); },
  };
  const plugin = { isDetached: false, gattCache: new Cache(),
    connectionManager: { connectedDevices: new Map([['device', gatt]]) },
    channel: { invokeMethod: (name, data) => events.push({ name, data }) } };
  plugin.notifyManager = new Notify(plugin);
  plugin.characteristicManager = new Characteristic(plugin);
  return { load, plugin, gatt, events, characteristic, services, callbacks,
    serviceReads: () => serviceReads };
}

function result() {
  const replies = [];
  return { replies, success: value => replies.push(['success', value]),
    error: (...args) => replies.push(['error', ...args]) };
}
function request(extra = {}) {
  return { args: new Map(Object.entries({ remote_id: 'device', service_uuid: '180f',
    characteristic_uuid: '2a19', instance_id: 0, ...extra })) };
}

test('GATT operations serialize per device, allow other devices, and recover from rejection', async () => {
  const cache = fixture().plugin.gattCache;
  const gate = deferred();
  const order = [];
  const first = cache.runGatt('a', async () => { order.push('first'); await gate.promise; throw Error('failed'); });
  const failure = assert.rejects(first, /failed/);
  const second = cache.runGatt('a', async () => order.push('second'));
  await cache.runGatt('b', async () => order.push('other'));
  assert.deepEqual(order, ['first', 'other']);
  gate.resolve();
  await Promise.all([failure, second]);
  assert.deepEqual(order, ['first', 'other', 'second']);
  assert.equal(cache.gattLockMap.size, 0, 'completed queues must release device references');
});

test('cache cleanup cannot break a pending GATT queue', async () => {
  const cache = fixture().plugin.gattCache;
  const gate = deferred();
  const order = [];
  const first = cache.runGatt('a', async () => { order.push(1); await gate.promise; });
  await Promise.resolve();
  const second = cache.runGatt('a', async () => order.push(2));
  cache.clearForDevice('a');
  cache.clearAll();
  const third = cache.runGatt('a', async () => order.push(3));
  await Promise.resolve();
  assert.deepEqual(order, [1]);
  gate.resolve();
  await Promise.all([first, second, third]);
  assert.deepEqual(order, [1, 2, 3]);
  assert.equal(cache.gattLockMap.size, 0);
});

test('notification bursts reuse discovered services and preserve payload and identity', async () => {
  const f = fixture();
  f.plugin.gattCache.deviceServicesMap.set('device', f.services);
  f.plugin.notifyManager.registerCharacteristicChangeCallback('device', f.gatt);
  f.plugin.notifyManager.registerCharacteristicChangeCallback('device', f.gatt);
  const callback = f.callbacks.get('BLECharacteristicChange');
  for (let i = 0; i < 100; i++) {
    await callback({ ...f.characteristic, characteristicValue: new Uint8Array([i]).buffer });
  }
  assert.equal(f.serviceReads(), 0);
  assert.equal(f.events.length, 100);
  f.events.forEach(({ name, data }, i) => {
    assert.equal(name, 'OnCharacteristicReceived');
    assert.equal(data.get('remote_id'), 'device');
    assert.equal(data.get('service_uuid'), '180f');
    assert.equal(data.get('characteristic_uuid'), '2a19');
    assert.equal(data.get('instance_id'), 0);
    assert.equal(data.has('primary_service_uuid'), false);
    assert.deepEqual(Array.from(data.get('value')), [i]);
  });
  f.plugin.isDetached = true;
  await callback(f.characteristic);
  assert.equal(f.events.length, 100);
  f.plugin.notifyManager.unregisterCharacteristicChangeCallback('device', f.gatt);
  assert.equal(f.callbacks.size, 0);
});

test('service reset invalidates notification cache and the next callback reloads it', async () => {
  const f = fixture();
  f.plugin.gattCache.deviceServicesMap.set('device', f.services);
  f.plugin.notifyManager.onCharacteristicReceived('device', f.services,
    { ...f.characteristic, serviceUuid: '1801', characteristicUuid: '2a05' });
  assert.equal(f.events[0].name, 'OnServicesReset');
  assert.equal(f.plugin.gattCache.deviceServicesMap.has('device'), false);
  f.plugin.notifyManager.registerCharacteristicChangeCallback('device', f.gatt);
  await f.callbacks.get('BLECharacteristicChange')(f.characteristic);
  assert.equal(f.serviceReads(), 1);
});

test('devices with identical service UUIDs receive notifications under their own remote ID', async () => {
  const f = fixture();
  let otherCallback;
  const otherGatt = { ...f.gatt, on: (_, callback) => { otherCallback = callback; } };
  f.plugin.connectionManager.connectedDevices.set('other', otherGatt);
  f.plugin.gattCache.deviceServicesMap.set('device', f.services);
  f.plugin.gattCache.deviceServicesMap.set('other', f.services);
  f.plugin.notifyManager.registerCharacteristicChangeCallback('device', f.gatt);
  f.plugin.notifyManager.registerCharacteristicChangeCallback('other', otherGatt);
  await otherCallback(f.characteristic);
  assert.equal(f.events.length, 1);
  assert.equal(f.events[0].data.get('remote_id'), 'other');
  assert.equal(f.serviceReads(), 0);
});

test('native dispatcher returns booleans expected by the Dart adapter', async () => {
  const f = fixture();
  const Dispatcher = f.load('./BleMethodDispatcher').default;
  const dispatcher = new Dispatcher(f.plugin);
  for (const method of ['isSupported', 'setOptions']) {
    const reply = result();
    await dispatcher.onMethodCall({ method, args: new Map() }, reply);
    assert.deepEqual(reply.replies, [['success', true]]);
  }
  let notImplemented = 0;
  await dispatcher.onMethodCall({ method: 'unknown' }, { notImplemented: () => notImplemented++ });
  assert.equal(notImplemented, 1);
});

test('missing CCCD retains the local explicit failure contract', async () => {
  const f = fixture();
  f.characteristic.descriptors = [];
  const reply = result();
  await f.plugin.notifyManager.setNotifyValue(request({ enable: true, force_indications: false }), reply);
  assert.equal(reply.replies.length, 1);
  assert.deepEqual(reply.replies[0], ['error', 'setNotifyValue', 'CCCD descriptor not found', null]);
  assert.equal(f.events.length, 0);
});

test('characteristic writes retain typed subview bytes, failure replies and queue recovery', async () => {
  const f = fixture();
  const value = new Uint8Array([99, 1, 2, 88]).subarray(1, 3);
  let writes = 0;
  f.gatt.writeCharacteristicValue = async c => {
    assert.deepEqual(Array.from(new Uint8Array(c.characteristicValue)), [1, 2]);
    if (++writes === 1) throw { code: 2900099, message: 'injected error' };
  };
  const args = request({ value, write_type: 0, allow_long_write: 0 });
  const failure = result();
  await f.plugin.characteristicManager.writeCharacteristic(args, failure);
  assert.equal(failure.replies[0][0], 'error');
  assert.equal(writes, 1, 'generic GATT errors must not be retried');
  assert.equal(f.events.length, 0);
  const success = result();
  await f.plugin.characteristicManager.writeCharacteristic(args, success);
  assert.deepEqual(success.replies, [['success', true]]);
  assert.equal(f.serviceReads(), 1, 'second write reuses services');
  assert.deepEqual(Array.from(f.events[0].data.get('value')), [1, 2]);
  assert.equal(f.plugin.gattCache.writeChrMap.size, 0);
});
