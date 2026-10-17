// Regression coverage for the transport audit findings.
// Reuses the repository's production-.ets loader; no OHOS radio is simulated.
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const assert = require('node:assert/strict');
const { test } = require('node:test');
const fixturePath = path.resolve(__dirname,
  './native_integration.test.cjs');
const helper = new Module(fixturePath, module);
helper.filename = fixturePath;
helper.paths = Module._nodeModulePaths(path.dirname(fixturePath));
helper._compile(fs.readFileSync(fixturePath, 'utf8').split("test('GATT operations")[0] +
  '\nmodule.exports = { fixture, deferred, request, result };', fixturePath);
const { fixture, deferred, request, result } = helper.exports;

test('cache-miss notification bursts share one serialized service query', async () => {
  const f = fixture();
  const gate = deferred();
  let calls = 0;
  f.gatt.getServices = async () => { calls++; return gate.promise; };
  f.plugin.notifyManager.registerCharacteristicChangeCallback('device', f.gatt);
  const callback = f.callbacks.get('BLECharacteristicChange');
  const pending = Array.from({ length: 20 }, () => callback(f.characteristic));
  await new Promise(setImmediate);
  assert.equal(calls, 1);
  gate.resolve(f.services);
  await Promise.all(pending);
  assert.equal(f.events.length, 20);
});

test('cache-miss notifications wait for busy GATT operations without dropping data', async () => {
  const f = fixture();
  const gate = deferred();
  let busy = false;
  const op = f.plugin.gattCache.runGatt('device', async () => {
    busy = true;
    await gate.promise;
    busy = false;
  });
  await Promise.resolve();
  let overlaps = 0;
  f.gatt.getServices = async () => {
    if (busy) { overlaps++; throw { code: 2900011 }; }
    return f.services;
  };
  f.plugin.notifyManager.registerCharacteristicChangeCallback('device', f.gatt);
  const pending = f.callbacks.get('BLECharacteristicChange')(f.characteristic);
  await new Promise(setImmediate);
  assert.equal(overlaps, 0);
  assert.equal(f.events.length, 0);
  gate.resolve();
  await Promise.all([op, pending]);
  assert.equal(f.events.length, 1);
});

test('old notification queries cannot repopulate caches or emit events after reconnect', async () => {
  const f = fixture();
  const gate = deferred();
  f.gatt.getServices = () => gate.promise;
  f.plugin.notifyManager.registerCharacteristicChangeCallback('device', f.gatt);
  const pending = f.callbacks.get('BLECharacteristicChange')(f.characteristic);
  await new Promise(setImmediate);
  f.plugin.notifyManager.unregisterCharacteristicChangeCallback('device', f.gatt);
  f.plugin.gattCache.clearForDevice('device');
  f.plugin.connectionManager.connectedDevices.set('device', { newSession: true });
  gate.resolve(f.services);
  await pending;
  assert.equal(f.plugin.gattCache.deviceServicesMap.has('device'), false);
  assert.equal(f.events.length, 0);
});

test('queued reads reject obsolete sessions before submitting native reads', async () => {
  const f = fixture();
  const gate = deferred();
  const first = f.plugin.gattCache.runGatt('device', () => gate.promise);
  let oldReads = 0;
  f.gatt.readCharacteristicValue = async c => { oldReads++; return c; };
  const reply = result();
  const pending = f.plugin.characteristicManager.readCharacteristic(request(), reply);
  const rejected = assert.rejects(pending, /connection changed/);
  f.plugin.gattCache.clearForDevice('device');
  f.plugin.connectionManager.connectedDevices.set('device', { newSession: true });
  gate.resolve();
  await Promise.all([first, rejected]);
  assert.equal(oldReads, 0);
  assert.deepEqual(reply.replies, []);
});

test('duplicate service UUIDs have distinct routes and invalid instances fail', async () => {
  const f = fixture();
  const Shared = f.load('./BleGattShared').default;
  const other = { ...f.characteristic, characteristicValueHandle: 17 };
  const services = [f.services[0], { ...f.services[0], characteristics: [other] }];
  const ids = [f.characteristic, other].map(c => Shared.getInstanceId(c, services));
  assert.deepEqual(ids, [7, 17]);
  const found = await Shared.locateCharacteristic(null, '180f', '2a19', ids[1], services);
  assert.equal(found.characteristic, other);
  const invalid = await Shared.locateCharacteristic(null, '180f', '2a19', 999, services);
  assert.equal(invalid.characteristic, null);
  const ambiguous = await Shared.locateCharacteristic(null, '180f', '2a19', 0, services);
  assert.equal(ambiguous.characteristic, null);
});

test('included service routing preserves its owner and duplicate characteristic handles', async () => {
  const f = fixture();
  const Shared = f.load('./BleGattShared').default;
  const included = { ...f.services[0], isPrimary: false };
  const root = { serviceUuid: '1810', isPrimary: true, characteristics: [], includeServices: [included] };
  assert.equal(Shared.getPrimaryService([root], { ...f.characteristic }), root);
  const found = await Shared.locateCharacteristic('1810', '180f', '2a19', 0, [root]);
  assert.equal(found.characteristic, f.characteristic);
  const other = { ...f.characteristic, characteristicValueHandle: 17 };
  included.characteristics.push(other);
  assert.equal(Shared.getInstanceId(other, [root]), 17);
  const duplicate = await Shared.locateCharacteristic('1810', '180f', '2a19', 17, [root]);
  assert.equal(duplicate.characteristic, other);
});

test('a new GATT session is not blocked by an unresolved obsolete native operation', async () => {
  const f = fixture();
  const cache = f.plugin.gattCache;
  const oldSession = cache.sessionFor('device', f.gatt, f.plugin.connectionManager.connectedDevices);
  const gate = deferred();
  const old = cache.runGatt('device', () => gate.promise, oldSession);
  const rejected = assert.rejects(old, /connection changed/);
  await new Promise(setImmediate);
  cache.clearForDevice('device');
  const nextGatt = { ...f.gatt };
  f.plugin.connectionManager.connectedDevices.set('device', nextGatt);
  const session = cache.sessionFor('device', nextGatt, f.plugin.connectionManager.connectedDevices);
  let ran = false;
  await cache.runGatt('device', async () => { ran = true; }, session);
  assert.equal(ran, true);
  gate.resolve();
  await rejected;
});

test('Service Changed fences a service query already in flight', async () => {
  const f = fixture();
  const gate = deferred();
  f.gatt.getServices = () => gate.promise;
  f.plugin.notifyManager.registerCharacteristicChangeCallback('device', f.gatt);
  const callback = f.callbacks.get('BLECharacteristicChange');
  const pending = callback(f.characteristic);
  await new Promise(setImmediate);
  await callback({ ...f.characteristic, serviceUuid: '1801', characteristicUuid: '2a05' });
  gate.resolve(f.services);
  await pending;
  assert.equal(f.plugin.gattCache.deviceServicesMap.has('device'), false);
  assert.equal(f.events.filter(e => e.name === 'OnServicesReset').length, 1);
});

test('an obsolete write completion cannot delete the new session write payload', async () => {
  const f = fixture();
  const oldGate = deferred(), nextGate = deferred();
  f.gatt.writeCharacteristicValue = () => oldGate.promise;
  const oldReply = result();
  const old = f.plugin.characteristicManager.writeCharacteristic(
    request({ value: new Uint8Array([1]), write_type: 0, allow_long_write: 0 }), oldReply);
  const rejected = assert.rejects(old, /connection changed/);
  await new Promise(setImmediate);
  f.plugin.gattCache.clearForDevice('device');
  const nextGatt = { ...f.gatt, writeCharacteristicValue: () => nextGate.promise };
  f.plugin.connectionManager.connectedDevices.set('device', nextGatt);
  const nextReply = result();
  const next = f.plugin.characteristicManager.writeCharacteristic(
    request({ value: new Uint8Array([2]), write_type: 0, allow_long_write: 0 }), nextReply);
  await new Promise(setImmediate);
  oldGate.resolve();
  await rejected;
  assert.equal(f.plugin.gattCache.writeChrMap.size, 1);
  assert.deepEqual([...f.plugin.gattCache.writeChrMap.values()][0], new Uint8Array([2]));
  nextGate.resolve();
  await next;
  assert.deepEqual(nextReply.replies, [['success', true]]);
  assert.equal(f.events.length, 1);
  assert.deepEqual(f.events[0].data.get('value'), new Uint8Array([2]));
});

for (const failed of [false, true]) {
  test(`obsolete RSSI ${failed ? 'failure' : 'success'} cannot enter the new connection response stream`, async () => {
    const f = fixture();
    const Gatt = f.load('./BleGattManager').default;
    const gate = deferred();
    f.gatt.getRssiValue = async () => {
      await gate.promise;
      if (failed) throw { code: 2900099, message: 'old request failed' };
      return -50;
    };
    const reply = result();
    const pending = new Gatt(f.plugin).readRssi({ args: 'device' }, reply);
    const rejected = assert.rejects(pending, /connection changed/);
    await new Promise(setImmediate);
    f.plugin.gattCache.clearForDevice('device');
    f.plugin.connectionManager.connectedDevices.set('device', { newSession: true });
    gate.resolve();
    await rejected;
    assert.deepEqual(reply.replies, []);
    assert.equal(f.events.length, 0);
  });
}

for (const kind of ['read', 'write', 'descriptor-read', 'descriptor-write', 'notify-register', 'notify-cccd', 'discover']) {
  test(`Service Changed fences an in-flight ${kind} completion and the next operation recovers`, async () => {
    const f = fixture();
    f.plugin.gattCache.deviceServicesMap.set('device', f.services);
    f.plugin.notifyManager.registerCharacteristicChangeCallback('device', f.gatt);
    const gate = deferred();
    const reply = result();
    let pending;
    const args = request({ value: new Uint8Array([1]), write_type: 0, allow_long_write: 0,
      descriptor_uuid: '2902', enable: true, force_indications: false });
    if (kind === 'read') {
      f.gatt.readCharacteristicValue = () => gate.promise;
      pending = f.plugin.characteristicManager.readCharacteristic(args, reply);
    } else if (kind === 'write') {
      f.gatt.writeCharacteristicValue = () => gate.promise;
      pending = f.plugin.characteristicManager.writeCharacteristic(args, reply);
    } else if (kind.startsWith('descriptor-')) {
      const Descriptor = f.load('./BleDescriptorManager').default;
      const manager = new Descriptor(f.plugin);
      if (kind === 'descriptor-read') {
        f.gatt.readDescriptorValue = () => gate.promise;
        pending = manager.readDescriptor(args, reply);
      } else {
        f.gatt.writeDescriptorValue = () => gate.promise;
        pending = manager.writeDescriptor(args, reply);
      }
    } else if (kind === 'discover') {
      const Gatt = f.load('./BleGattManager').default;
      f.gatt.getServices = () => gate.promise;
      pending = new Gatt(f.plugin).discoverServices({ args: 'device' }, reply);
    } else {
      if (kind === 'notify-register') f.gatt.setCharacteristicChangeNotification = () => gate.promise;
      else f.gatt.writeDescriptorValue = () => gate.promise;
      pending = f.plugin.notifyManager.setNotifyValue(args, reply);
    }
    const rejected = assert.rejects(pending, /Services changed/);
    await new Promise(setImmediate);
    await f.callbacks.get('BLECharacteristicChange')({ ...f.characteristic,
      serviceUuid: '1801', characteristicUuid: '2a05' });
    gate.resolve(kind === 'descriptor-read' ? f.characteristic.descriptors[0] :
      kind === 'discover' ? f.services : f.characteristic);
    await rejected;
    assert.equal(f.plugin.gattCache.deviceServicesMap.has('device'), false);
    assert.equal(f.plugin.gattCache.writeChrMap.size, 0);
    assert.equal(f.plugin.gattCache.writeDescMap.size, 0);
    assert.deepEqual(reply.replies, []);
    assert.equal(f.events.filter(e => e.name !== 'OnServicesReset' &&
      e.data.get('service_uuid') !== '1801').length, 0);
    f.gatt.getServices = async () => f.services;
    f.gatt.readCharacteristicValue = async c => c;
    const next = result();
    await f.plugin.characteristicManager.readCharacteristic(request(), next);
    assert.deepEqual(next.replies, [['success', true]]);
  });
}

test('notifications after Service Changed do not join an obsolete pending service query', async () => {
  const f = fixture();
  const gate = deferred();
  let calls = 0;
  f.gatt.getServices = () => ++calls === 1 ? gate.promise : Promise.resolve(f.services);
  f.plugin.notifyManager.registerCharacteristicChangeCallback('device', f.gatt);
  const callback = f.callbacks.get('BLECharacteristicChange');
  const old = callback(f.characteristic);
  await new Promise(setImmediate);
  await callback({ ...f.characteristic, serviceUuid: '1801', characteristicUuid: '2a05' });
  const next = callback({ ...f.characteristic, characteristicValue: new Uint8Array([99]).buffer });
  gate.resolve(f.services);
  await Promise.all([old, next]);
  assert.equal(calls, 2);
  const values = f.events.filter(e => e.name === 'OnCharacteristicReceived' && e.data.get('service_uuid') === '180f');
  assert.equal(values.length, 1);
  assert.deepEqual(values[0].data.get('value'), new Uint8Array([99]));
});

test('no-handle cloned notifications reject competing primary and included service owners', () => {
  const f = fixture();
  f.load('@kit.BasicServicesKit').deviceInfo.sdkApiVersion = 17;
  const Shared = f.load('./BleGattShared').default;
  const included = { ...f.services[0], isPrimary: false, characteristics: [{ ...f.characteristic }] };
  const root = { serviceUuid: '1810', isPrimary: true, characteristics: [], includeServices: [included] };
  const clone = { ...f.characteristic };
  for (const tree of [[f.services[0], root], [root, f.services[0]]]) {
    assert.throws(() => Shared.getPrimaryService(tree, clone), /Ambiguous service owner/);
  }
  assert.equal(Shared.getPrimaryService([root], clone), root);
  assert.equal(Shared.getPrimaryService([f.services[0]], clone), null);
  // Distinct characteristic UUIDs make the owner provable even if service UUIDs match.
  const unrelated = { ...root, includeServices: [{ ...included,
    characteristics: [{ ...f.characteristic, characteristicUuid: '2a1a' }] }] };
  assert.equal(Shared.getPrimaryService([f.services[0], unrelated], clone), null);
});

test('notification identity rejects absent characteristics and obsolete duplicate handles', () => {
  const f = fixture();
  const Shared = f.load('./BleGattShared').default;
  const other = { ...f.characteristic, characteristicValueHandle: 17 };
  const services = [f.services[0], { ...f.services[0], characteristics: [other] }];
  assert.throws(() => Shared.getInstanceId({ ...f.characteristic, characteristicValueHandle: 99 }, services),
    /Obsolete characteristic handle/);
  assert.throws(() => Shared.getInstanceId({ ...f.characteristic, characteristicUuid: '2a1a' }, services),
    /not in current services/);
  assert.equal(Shared.getInstanceId({ ...other }, services), 17);
});
