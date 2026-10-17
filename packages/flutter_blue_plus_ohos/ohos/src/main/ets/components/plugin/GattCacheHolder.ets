/*
 * Copyright (C) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 ("the License");
 *
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { ble } from '@kit.ConnectivityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import BleUtils from './BleUtils';

export class GattSession {
  public active: boolean = true;
  public notificationLoad: Promise<ble.GattService[]> | undefined = undefined;
  public servicesRevision: number = 0;
  public remoteId: string;
  public gatt: ble.GattClientDevice;
  private connected: Map<string, ble.GattClientDevice>;
  constructor(remoteId: string, gatt: ble.GattClientDevice,
    connected: Map<string, ble.GattClientDevice>) {
    this.remoteId = remoteId;
    this.gatt = gatt;
    this.connected = connected;
  }

  assertCurrent(revision?: number): void {
    if (!this.active || this.connected.get(this.remoteId) !== this.gatt) {
      throw new Error('GATT connection changed; discard the obsolete operation');
    }
    if (revision !== undefined && revision !== this.servicesRevision) {
      throw new Error('Services changed; discard the obsolete operation');
    }
  }
}

/**
 * GATT 共享缓存层。
 *
 * 集中持有跨功能组共享的 4 个缓存 Map，供 BleGattManager(facade)/BleCharacteristicManager/
 * BleDescriptorManager/BleNotifyManager/BleMtuManager 经 plugin.gattCache 统一访问，
 * 使各业务 Manager 可独立拆分而无需互相持有引用。
 *
 * 提供聚合清理接口 clearForDevice / clearAll，供 BleConnectionManager 在断开/清理时调用，
 * 避免连接侧穿透到 4 个 Map 逐个操作。
 *
 * 字段语义：
 *  - mtuMap：deviceId → MTU（BleMtuManager 写、getMaxPayload/writeDescriptor 读）。
 *  - writeChrMap：写特征缓存值（key=remoteId:psu:su:cu:instanceId），Characteristic 组独占。
 *  - writeDescMap：写描述符缓存值（key=remoteId:psu:su:
 *    cu:instanceId:du），Notify 组与 Descriptor 组共享。
 *  - deviceServicesMap：deviceId → 已发现服务树（Notify 回调懒加载、readCharacteristic 刷新）。
 */
export default class GattCacheHolder {
  /** 每个设备的 MTU（默认 23）。 */
  public mtuMap: Map<string, number> = new Map();
  /** 待写入特征的缓存值（key=remoteId:psu:su:cu:instanceId），用于回传写入数据。 */
  public writeChrMap: Map<string, Uint8Array> = new Map();
  /** 待写入描述符的缓存值（key=remoteId:psu:su:cu:instanceId:du）。 */
  public writeDescMap: Map<string, Uint8Array> = new Map();
  /** 每个设备已发现的服务缓存，onCharacteristicChange 时按 deviceId 取用。 */
  public deviceServicesMap: Map<string, ble.GattService[]> = new Map();
  /**
   * 每个设备的 GATT 操作串行锁（deviceId → 当前正在执行的 Promise）。
   *
   * OHOS BLE 栈同一设备的 GATT 操作不支持并发，并发时返回 2900011 "The operation is busy"。
   * 此锁通过 Promise 链实现按设备串行化：新操作 await 前一个操作的 Promise，
   * 不同设备的操作互不阻塞。
   */
  public gattLockMap: Map<string, Promise<void>> = new Map();
  private sessions: Map<string, GattSession> = new Map();

  sessionFor(remoteId: string, gatt: ble.GattClientDevice,
    connected: Map<string, ble.GattClientDevice>): GattSession {
    let session = this.sessions.get(remoteId);
    if (session == null || session.gatt !== gatt || !session.active) {
      if (session != null) session.active = false;
      // A new GATT object belongs to a new connection. Old queued operations
      // keep their own tails and are fenced by the invalidated session.
      if (session != null && session.gatt !== gatt) {
        this.clearForDevice(remoteId);
        this.gattLockMap.delete(remoteId);
      }
      session = new GattSession(remoteId, gatt, connected);
      this.sessions.set(remoteId, session);
    }
    session.assertCurrent();
    return session;
  }

  // Call only while holding runGatt. Never await a queued notification load
  // here: it may be waiting behind the caller itself.
  async servicesFor(session: GattSession): Promise<ble.GattService[]> {
    session.assertCurrent();
    let services = this.deviceServicesMap.get(session.remoteId);
    if (services == null) {
      const revision = session.servicesRevision;
      services = await session.gatt.getServices();
      session.assertCurrent();
      if (revision !== session.servicesRevision) throw new Error('Services changed during discovery');
      this.deviceServicesMap.set(session.remoteId, services);
    }
    return services;
  }

  async notificationServices(session: GattSession): Promise<ble.GattService[]> {
    session.assertCurrent();
    if (session.notificationLoad == null) {
      session.notificationLoad = this.runGatt(session.remoteId, () => this.servicesFor(session), session);
    }
    const pending = session.notificationLoad;
    try {
      return await pending;
    } finally {
      if (session.notificationLoad === pending) session.notificationLoad = undefined;
    }
  }

  /**
   * 清理指定设备的缓存：mtuMap + deviceServicesMap。
   *
   * 同时失效连接代次并按完整设备前缀清理尚未完成的写入。
   * @param remoteId - 设备 ID
   */
  invalidateServices(remoteId: string): void {
    const session = this.sessions.get(remoteId);
    if (session != null) {
      session.servicesRevision++;
      // Notifications after the reset must load the new revision, rather than
      // join a query whose result has already become obsolete.
      session.notificationLoad = undefined;
    }
    this.deviceServicesMap.delete(remoteId);
    this.clearWritesForDevice(remoteId);
  }

  clearForDevice(remoteId: string): void {
    let session = this.sessions.get(remoteId);
    if (session != null) session.active = false;
    if (!this.gattLockMap.has(remoteId)) this.sessions.delete(remoteId);
    this.mtuMap.delete(remoteId);
    this.deviceServicesMap.delete(remoteId);
    this.clearWritesForDevice(remoteId);
    // 不删除 gattLockMap：已排队操作必须保留自己的队尾，不能绕过串行锁。
    // runGatt 在队尾完成后移除条目，新连接通过 sessionFor 隔离旧链。
  }

  private clearWritesForDevice(remoteId: string): void {
    const prefix = remoteId + ':';
    this.writeChrMap.forEach((_value, key) => {
      if (key.startsWith(prefix)) this.writeChrMap.delete(key);
    });
    this.writeDescMap.forEach((_value, key) => {
      if (key.startsWith(prefix)) this.writeDescMap.delete(key);
    });
  }

  /** 清空全部缓存。disconnectAllDevices / cleanup 全量清理时调用。 */
  clearAll(): void {
    this.sessions.forEach((session, remoteId) => {
      session.active = false;
      if (!this.gattLockMap.has(remoteId)) this.sessions.delete(remoteId);
    });
    this.mtuMap.clear();
    this.writeChrMap.clear();
    this.writeDescMap.clear();
    this.deviceServicesMap.clear();
    // Keep pending chains intact; runGatt removes each entry when its tail settles.
    // Clearing an active lock here would let a later operation bypass the queue.
  }

  /**
   * 按设备串行执行 GATT 操作：等前一个操作完成后再执行本次。
   * 不同设备的操作互不阻塞。
   *
   * 实现方式：每个设备维护一个 Promise 链，新操作 await 前一个操作的 Promise，
   * 完成后 resolve 当前 Promise，使后续操作可以继续。
   *
   * @param remoteId - 设备 ID
   * @param op - 待执行的异步操作（含 result 回调）
   * @returns op 的返回值
   */
  async runGatt<T>(remoteId: string, op: () => Promise<T>, session?: GattSession): Promise<T> {
    let prev: Promise<void> = this.gattLockMap.get(remoteId) ?? Promise.resolve();
    let resolve: () => void = () => {};
    let next: Promise<void> = new Promise<void>(r => { resolve = r; });
    this.gattLockMap.set(remoteId, next);
    BleUtils.log(hilog.LogLevel.DEBUG,
      `runGatt: queuing GATT op for ${remoteId}`);
    await prev;
    BleUtils.log(hilog.LogLevel.DEBUG, `runGatt: starting GATT op for ${remoteId}`);
    try {
      session?.assertCurrent();
      const value = await op();
      session?.assertCurrent();
      return value;
    } finally {
      resolve();
      if (this.gattLockMap.get(remoteId) === next) {
        this.gattLockMap.delete(remoteId);
        const current = this.sessions.get(remoteId);
        if (current != null && !current.active) this.sessions.delete(remoteId);
      }
      BleUtils.log(hilog.LogLevel.DEBUG, `runGatt: completed GATT op for ${remoteId}`);
    }
  }
}
