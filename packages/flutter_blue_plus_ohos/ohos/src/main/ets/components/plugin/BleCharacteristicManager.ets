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

import { MethodCall, MethodResult } from '@ohos/flutter_ohos';
import { ble, connection } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import BleUtils from './BleUtils';
import BleGattShared, { ChrFound, GattWriteContext, GattWriteTarget } from './BleGattShared';
import FlutterBluePlusOhosPlugin from './FlutterBluePlusOhosPlugin';

/**
 * 蓝牙特征（Characteristic）读写管理器。
 *
 * 从 BleGattManager 剥离的特征读写逻辑：readCharacteristic（含鉴权失败 2901006 后配对重试）、
 * writeCharacteristic（属性/负载校验后写入并回传）。
 *
 * 跨 Manager 访问：
 *  - 共享缓存 writeChrMap / deviceServicesMap 经 plugin.gattCache 访问。
 *  - 已连接设备 GattClientDevice 经 plugin.connectionManager.connectedDevices 反查。
 *  - readCharacteristic 完成后需回传读到的特征值，经 plugin.notifyManager.onCharacteristicReceived 调用
 *    （回调实现在 BleNotifyManager）。
 *    BLECharacteristicChange 监听已在连接时按设备注册，本类不负责。
 *  - getMaxPayload / locateCharacteristic / getPrimaryService / getInstanceId 等为 BleGattShared 静态工具。
 */
export default class BleCharacteristicManager {
  /** 插件引用，用于访问 connectionManager/gattManager/gattCache/channel。 */
  private plugin: FlutterBluePlusOhosPlugin;

  /**
   * 构造特征读写管理器。
   * @param plugin - 宿主插件引用
   */
  constructor(plugin: FlutterBluePlusOhosPlugin) {
    this.plugin = plugin;
  }

  /**
   * 处理 readCharacteristic：读取指定特征值，鉴权失败（2901006）时尝试配对后重试。
   * @param call - 方法调用，args 含 remote_id/primary_service_uuid/service_uuid/characteristic_uuid/instance_id
   * @param result - 结果回调
   */
  async readCharacteristic(call: MethodCall, result: MethodResult): Promise<void> {
    let data: Map<string, string | number> = call.args;
    // 参数校验：remote_id 缺失/非字符串时直接回错，避免后续 connectedDevices.get(undefined) 返回
    // 误导性的 "device is disconnected"（与 disconnect/setNotifyValue 入口校验保持一致）。
    let rawRemoteId = data.get('remote_id');
    if (rawRemoteId == null || typeof rawRemoteId !== 'string' || (rawRemoteId as string).length == 0) {
      BleUtils.log(hilog.LogLevel.ERROR, 'readCharacteristic failed: invalid remote_id');
      result.error('readCharacteristic', 'invalid remote_id', null);
      return;
    }
    let remoteId: string = rawRemoteId as string;
    let primaryServiceUuid: string = data.get('primary_service_uuid') as string;
    let serviceUuid: string = data.get('service_uuid') as string;
    let characteristicUuid: string = data.get('characteristic_uuid') as string;
    let instanceId: number = data.get('instance_id') as number;
    BleUtils.log(hilog.LogLevel.DEBUG,
      `readCharacteristic: remoteId=${remoteId}, primaryServiceUuid=${primaryServiceUuid},` +
      ` serviceUuid=${serviceUuid}, characteristicUuid=${characteristicUuid}, instanceId=${instanceId}`);
    let gatt: ble.GattClientDevice =
      this.plugin.connectionManager.connectedDevices.get(remoteId) as ble.GattClientDevice;
    if (gatt == null) {
      BleUtils.log(hilog.LogLevel.ERROR, 'readCharacteristic failed: device is disconnected');
      result.error('readCharacteristic', 'device is disconnected', null);
      return;
    }
    // 按设备串行执行 GATT 操作，避免 OHOS BLE 栈 2900011 "operation is busy" 错误。
    await this.plugin.gattCache.runGatt(remoteId, async () => {
      // 记录当前配对状态用于诊断；
      // 无需特殊处理 BONDING（鉴权失败由 readCharacteristicWithBondRetry 兜底重试）。
      BleUtils.log(hilog.LogLevel.DEBUG, `readCharacteristic: bond state: ${connection.getPairState(remoteId)}`);
      // 优先使用 deviceServicesMap 缓存，cache miss 时才调 getServices()，
      // 对齐 writeCharacteristic 与 BleNotifyManager 的缓存策略。
      let services: ble.GattService[] | undefined =
        this.plugin.gattCache.deviceServicesMap.get(remoteId);
      if (services == null) {
        services = await gatt.getServices();
        this.plugin.gattCache.deviceServicesMap.set(remoteId, services);
      }
      BleUtils.log(hilog.LogLevel.DEBUG, `readCharacteristic: found ${services.length} services`);
      let characteristic: ble.BLECharacteristic | null =
        await this.resolveReadableCharacteristic(primaryServiceUuid, serviceUuid, characteristicUuid, instanceId,
          services, result);
      if (characteristic == null) {
        return;
      }
      let readCharacteristic: ble.BLECharacteristic | null = await this.readCharacteristicWithBondRetry(gatt,
        characteristic, remoteId, result);
      if (readCharacteristic == null) {
        // 重试已通过 result 回传错误
        return;
      }
      // readCharacteristic 已判空，赋给非空变量显式收窄类型（避免 as 强转）。
      let readChar: ble.BLECharacteristic = readCharacteristic;
      this.emitReadResult(remoteId, services, readChar, result);
    });
  }

  /**
   * 定位并校验可读特征：locateCharacteristic 查找 + READ 属性校验。
   * @returns 目标特征；失败时通过 result 回传错误并返回 null
   */
  private async resolveReadableCharacteristic(primaryServiceUuid: string, serviceUuid: string,
    characteristicUuid: string, instanceId: number, services: ble.GattService[],
    result: MethodResult): Promise<ble.BLECharacteristic | null> {
    let found: ChrFound | undefined =
      await BleGattShared.locateCharacteristic(primaryServiceUuid, serviceUuid,
        characteristicUuid, instanceId, services);
    if (found == null || found.error != null) {
      let err: string = found == null ? 'characteristic not found' : found.error as string;
      BleUtils.log(hilog.LogLevel.ERROR, `readCharacteristic failed: characteristic not found: ${err}`);
      result.error('readCharacteristic', err, null);
      return null;
    }
    // found.error 已判空，故 found 非空；
    // characteristic 理论上必有值，显式判空防御而非 as 强转掩盖 null。
    let characteristic: ble.BLECharacteristic | null = found.characteristic ?? null;
    if (characteristic == null) {
      BleUtils.log(hilog.LogLevel.ERROR, 'readCharacteristic failed: characteristic is null');
      result.error('readCharacteristic', 'Characteristic not found', null);
      return null;
    }
    if (!characteristic.properties?.read) {
      BleUtils.log(hilog.LogLevel.ERROR, 'readCharacteristic failed: characteristic is not readable');
      result.error('readCharacteristic',
        'The READ property is not supported by this BLE characteristic', null);
      return null;
    }
    return characteristic;
  }

  /**
   * 读取成功后：缓存服务树、回传读到的特征值并回 success。
   *
   * BLECharacteristicChange 监听已在连接成功时（BleConnectionManager.handleConnected）按设备注册，
   * 此处不再懒注册（对齐 Android：读操作无需关心监听注册）。
   * @param remoteId - 设备 ID
   * @param services - 已发现的服务树
   * @param readCharacteristic - 读取到的特征
   * @param result - 结果回调
   */
  private emitReadResult(remoteId: string, services: ble.GattService[],
    readCharacteristic: ble.BLECharacteristic, result: MethodResult): void {
    this.plugin.gattCache.deviceServicesMap.set(remoteId, services);
    this.plugin.notifyManager.onCharacteristicReceived(remoteId, services, readCharacteristic);
    BleUtils.log(hilog.LogLevel.DEBUG, 'readCharacteristic: operation completed successfully');
    result.success(true);
  }

  /**
   * 读取特征值，鉴权/授权失败（错误码 2901006/2901007）时尝试 pairDevice 后重试一次。
   * 其他错误直接报错，与 Android/iOS 行为一致（不做重试）。
   * @returns 读取到的特征；失败时通过 result 回传错误并返回 null
   */
  private async readCharacteristicWithBondRetry(gatt: ble.GattClientDevice,
    characteristic: ble.BLECharacteristic, remoteId: string,
    result: MethodResult): Promise<ble.BLECharacteristic | null> {
    try {
      BleUtils.log(hilog.LogLevel.DEBUG, 'readCharacteristic: calling gatt.readCharacteristicValue()');
      let readCharacteristic = await gatt.readCharacteristicValue(characteristic);
      BleUtils.log(hilog.LogLevel.DEBUG, 'readCharacteristic: gatt.readCharacteristicValue() succeeded');
      return readCharacteristic;
    } catch (e) {
      let error = e as BusinessError;
      BleUtils.log(hilog.LogLevel.ERROR,
        `readCharacteristic failed: gatt.readCharacteristicValue() threw error: ${JSON.stringify(e)}`);
      // 2901006: 鉴权失败 / 2901007: 连接未授权 — 尝试配对后重试
      // 这是 OHOS 平台差异：Android/iOS 遇到鉴权错误时系统自动弹出配对请求，
      // OHOS 需要应用层手动调 pairDevice()
      if (error.code === 2901006 || error.code === 2901007) {
        return await this.retryReadAfterBond(gatt, characteristic, remoteId, error, result);
      }
      // 其他错误直接报错，不重试，对齐 Android/iOS 行为
      result.error('readCharacteristic',
        `gatt.readCharacteristic() failed with error: ${error.message || 'unknown error'}`,
        { errorCode: error.code, errorDetails: JSON.stringify(e) });
      return null;
    }
  }

  /**
   * 鉴权失败后发起 pairDevice 并重试一次读取。
   * @returns 读取到的特征；失败时通过 result 回传错误并返回 null
   */
  private async retryReadAfterBond(gatt: ble.GattClientDevice, characteristic: ble.BLECharacteristic,
    remoteId: string, error: BusinessError,
    result: MethodResult): Promise<ble.BLECharacteristic | null> {
    BleUtils.log(hilog.LogLevel.ERROR,
      `readCharacteristic failed: Connection not authorized (${error.code}). Attempting to bond device...`);
    try {
      // 鉴权失败(2901006)/未授权(2901007)补救：先 pairDevice 发起绑定，
      // 绑定成功(BOND_STATE_BONDED)后立即重读一次。
      await connection.pairDevice(remoteId);
      BleUtils.log(hilog.LogLevel.DEBUG, 'readCharacteristic: Device bonding initiated');
      let newBondState = connection.getPairState(remoteId);
      if (newBondState == connection.BondState.BOND_STATE_BONDED) {
        BleUtils.log(hilog.LogLevel.DEBUG, 'readCharacteristic: Device bonded successfully. Retrying read...');
        let readCharacteristic = await gatt.readCharacteristicValue(characteristic);
        BleUtils.log(hilog.LogLevel.DEBUG,
          'readCharacteristic: gatt.readCharacteristicValue() succeeded after bonding');
        return readCharacteristic;
      }
      BleUtils.log(hilog.LogLevel.ERROR,
        `readCharacteristic failed: Device bonding failed. errorCode=${error.code}`);
      result.error('readCharacteristic',
        `gatt.readCharacteristic() failed with error: Device bonding failed. Error code: ${error.code}`,
        { errorCode: error.code, errorDetails: JSON.stringify(error) });
      return null;
    } catch (bondError) {
      BleUtils.log(hilog.LogLevel.ERROR,
        `readCharacteristic failed: Device bonding failed: ${JSON.stringify(bondError)}`);
      result.error('readCharacteristic',
        `gatt.readCharacteristic() failed with error: ${error.message ||
          'unknown error'}. Failed to bond device.`,
        { errorCode: error.code, errorDetails: JSON.stringify(error) });
      return null;
    }
  }

  /**
   * 处理 writeCharacteristic：按写入类型写特征值，
   * 校验属性与负载长度后写入并回传 OnCharacteristicWritten。
   * @param call - 方法调用，args 含
   *   remote_id/primary_service_uuid/service_uuid/characteristic_uuid/instance_id/
   *   value/write_type/allow_long_write
   * @param result - 结果回调
   */
  async writeCharacteristic(call: MethodCall, result: MethodResult): Promise<void> {
    let data: Map<string, string | number | Uint8Array> = call.args;
    // 参数校验：remote_id 缺失/非字符串/空串、value 缺失时直接回错，
    // 避免后续 as 强转或 gatt 调用崩溃
    // （remote_id 校验与 readCharacteristic/disconnect 入口保持一致）。
    let rawRemoteId = data.get('remote_id');
    let rawValue = data.get('value');
    if (rawRemoteId == null || typeof rawRemoteId !== 'string' || (rawRemoteId as string).length == 0) {
      BleUtils.log(hilog.LogLevel.ERROR, 'writeCharacteristic failed: invalid remote_id');
      result.error('writeCharacteristic', 'invalid remote_id', null);
      return;
    }
    if (rawValue == null) {
      BleUtils.log(hilog.LogLevel.ERROR, 'writeCharacteristic failed: missing value');
      result.error('writeCharacteristic', 'missing required argument (value)', null);
      return;
    }
    let remoteId: string = rawRemoteId as string;
    let primaryServiceUuid: string = data.get('primary_service_uuid') as string;
    let serviceUuid: string = data.get('service_uuid') as string;
    let characteristicUuid: string = data.get('characteristic_uuid') as string;
    let instanceId: number = data.get('instance_id') as number;
    let value: Uint8Array = rawValue as Uint8Array;
    let writeTypeInt: number = data.get('write_type') as number;
    let allowLongWrite: boolean = (data.get('allow_long_write') as number) != 0;
    // Flutter 侧约定 write_type=0 为带响应(WRITE)，否则为无响应(WRITE_NO_RESPONSE)。
    let writeType: number = writeTypeInt == 0 ? ble.GattWriteType.WRITE : ble.GattWriteType.WRITE_NO_RESPONSE;
    let gatt: ble.GattClientDevice =
      this.plugin.connectionManager.connectedDevices.get(remoteId) as ble.GattClientDevice;
    if (gatt == null) {
      BleUtils.log(hilog.LogLevel.ERROR, 'writeCharacteristic failed: device is disconnected');
      result.error('writeCharacteristic', 'device is disconnected', null);
      return;
    }
    let target = new GattWriteTarget(remoteId, primaryServiceUuid, serviceUuid, characteristicUuid, instanceId);
    // 按设备串行执行 GATT 操作，避免 OHOS BLE 栈 2900011 "operation is busy" 错误。
    await this.plugin.gattCache.runGatt(remoteId, async () => {
      // 优先使用 deviceServicesMap 缓存，减少与 BLE 栈的异步交互次数。
      // OHOS 的 gatt.getServices() 是异步操作，每次调用可能增加与其它 GATT 操作的并发冲突概率，
      // 导致 writeCharacteristicValue 间歇性返回 2900099。
      // 对比 Android：gatt.getServices() 是同步的本地缓存读取，不会产生此问题。
      // 缓存策略对齐 BleNotifyManager 的 BLECharacteristicChange 回调：cache miss 时才调 getServices()。
      let gattServices: ble.GattService[] | undefined =
        this.plugin.gattCache.deviceServicesMap.get(remoteId);
      if (gattServices == null) {
        gattServices = await gatt.getServices();
        BleUtils.log(hilog.LogLevel.DEBUG, `writeCharacteristic: getServices() returned ${gattServices.length} services`);
        this.plugin.gattCache.deviceServicesMap.set(remoteId, gattServices);
      } else {
        BleUtils.log(hilog.LogLevel.DEBUG,
          `writeCharacteristic: using cached services (${gattServices.length} services)`);
      }
      let characteristic: ble.BLECharacteristic | null =
        await this.resolveWriteCharacteristic(target, gattServices, result);
      if (characteristic == null) {
        return;
      }
      if (!this.checkWriteProperty(characteristic, writeType, result)) {
        return;
      }
      if (!this.validateWritePayload(value, writeTypeInt, allowLongWrite, remoteId, result)) {
        return;
      }
      let ctx = new GattWriteContext(gatt, characteristic, gattServices, target, result);
      await this.executeWriteCharacteristic(ctx, value, writeType);
    });
  }

  /**
   * 定位写入目标特征：locateCharacteristic 查找 + null 校验。
   * @param target - 设备/特征身份（含 UUID/instanceId）
   * @param gattServices - GATT 服务树
   * @param result - 结果回调
   * @returns 目标特征；失败时通过 result 回传错误并返回 null
   */
  private async resolveWriteCharacteristic(target: GattWriteTarget, gattServices: ble.GattService[],
    result: MethodResult): Promise<ble.BLECharacteristic | null> {
    let found: ChrFound | undefined =
      await BleGattShared.locateCharacteristic(target.primaryServiceUuid, target.serviceUuid,
        target.characteristicUuid, target.instanceId, gattServices);
    if (found == null || found.error != null) {
      let err: string = found == null ? 'characteristic not found' : found.error as string;
      BleUtils.log(hilog.LogLevel.ERROR, `writeCharacteristic failed: ${err}`);
      result.error('writeCharacteristic', err, null);
      return null;
    }
    let characteristic: ble.BLECharacteristic | null = found.characteristic;
    if (characteristic == null) {
      BleUtils.log(hilog.LogLevel.ERROR, 'writeCharacteristic failed: characteristic not found');
      result.error('writeCharacteristic', 'Characteristic not found', null);
      return null;
    }
    return characteristic;
  }

  /**
   * 校验特征是否支持目标写入类型（WRITE 或 WRITE_NO_RESPONSE）。
   * @returns true 通过；false 时已通过 result 回传错误
   */
  private checkWriteProperty(characteristic: ble.BLECharacteristic, writeType: number,
    result: MethodResult): boolean {
    if (writeType == ble.GattWriteType.WRITE) {
      if (!characteristic?.properties?.write) {
        BleUtils.log(hilog.LogLevel.ERROR, 'writeCharacteristic failed: WRITE property not supported');
        result.error('writeCharacteristic',
          'The WRITE property is not supported by this BLE characteristic', null);
        return false;
      }
    } else {
      if (!characteristic?.properties?.writeNoResponse) {
        BleUtils.log(hilog.LogLevel.ERROR,
          'writeCharacteristic failed: WRITE_NO_RESPONSE property not supported');
        result.error('writeCharacteristic',
          'The WRITE_NO_RESPONSE property is not supported by this BLE characteristic', null);
        return false;
      }
    }
    return true;
  }

  /**
   * 最大负载校验：无响应写入或禁止长写入时上限为 MTU-3（扣除 3 字节 ATT 操作头），
   * 带响应且允许长写入时上限为 GATT 最大属性长度 512 字节；超长回错。
   * @returns true 通过；false 时已通过 result 回传错误
   */
  private validateWritePayload(value: Uint8Array, writeTypeInt: number, allowLongWrite: boolean,
    remoteId: string, result: MethodResult): boolean {
    let writeType: number = writeTypeInt == 0 ? ble.GattWriteType.WRITE : ble.GattWriteType.WRITE_NO_RESPONSE;
    let maxLen: number =
      BleGattShared.getMaxPayload(this.plugin.gattCache.mtuMap, remoteId, writeType, allowLongWrite);
    let dataLen: number = value.length as number;
    if (dataLen <= maxLen) {
      return true;
    }
    let writeTypeDesc: string = writeTypeInt == 0 ? 'withResponse' : 'withoutResponse';
    let longWriteFlag: string = writeTypeInt == 0 ? (allowLongWrite ? ', allowLongWrite' : ', noLongWrite') : '';
    let str: string = 'data longer than allowed. dataLen: ' + dataLen + ' > max: ' + maxLen +
      ' (' + writeTypeDesc + longWriteFlag + ')';
    BleUtils.log(hilog.LogLevel.ERROR, `writeCharacteristic failed: ${str}`);
    result.error('writeCharacteristic', str, null);
    return false;
  }

  /**
   * 执行特征写入并回传 OnCharacteristicWritten。
   * 缓存写入值（writeChrMap）以便回传时取回，写入失败回传 result.error。
   *
   * 写入失败直接报错，不重试，对齐 Android/iOS 行为。
   * 2900099 等错误由 runGatt 串行锁从源头减少并发冲突概率，
   * 仍失败则属于平台限制（如对 GATT 标准服务 0x1800/0x1801 写入），不应重试。
   */
  private async executeWriteCharacteristic(ctx: GattWriteContext,
    value: Uint8Array, writeType: number): Promise<void> {
    // 缓存写入值，回传 OnCharacteristicWritten 时按相同键取回实际写入的字节。
    let key: string = this.buildWriteChrKey(ctx);
    this.plugin.gattCache.writeChrMap.set(key, value);
    let writeValue: ArrayBuffer = BleUtils.typedArrayToBuffer(value);
    ctx.characteristic.characteristicValue = writeValue;
    try {
      await ctx.gatt.writeCharacteristicValue(ctx.characteristic, writeType);
    } catch (e) {
      let businessError = e as BusinessError;
      // 写入失败：清理刚缓存的写入值，避免 writeChrMap 残留（clearForDevice 不清此 Map）。
      this.plugin.gattCache.writeChrMap.delete(key);
      BleUtils.log(hilog.LogLevel.ERROR,
        `writeCharacteristic failed: errorCode=${businessError.code}, errmessage=${businessError.message}`);
      ctx.result.error('writeCharacteristic',
        `gatt.writeCharacteristic() failed with error: ${businessError.message || 'unknown error'}`,
        { errorCode: businessError.code, errorDetails: JSON.stringify(e) });
      return;
    }
    this.emitWriteChrResponse(ctx);
  }

  /**
   * 构造写特征缓存键（remoteId:psu:su:cu:instanceId）。
   * primaryServiceUuid 为 null 时归一化为 ''，须与 emitWriteChrResponse 的 key1 重建逻辑保持一致。
   * @param ctx - GATT 写操作上下文
   * @returns 缓存键
   */
  private buildWriteChrKey(ctx: GattWriteContext): string {
    let primaryServiceUuid: string = ctx.primaryServiceUuid == null ? '' : ctx.primaryServiceUuid;
    return ctx.remoteId + ':' + primaryServiceUuid + ':' + ctx.serviceUuid + ':' +
      ctx.characteristicUuid + ':' + ctx.instanceId;
  }

  /**
   * 写入成功后：按响应侧归一化键取回缓存值、组装并回传 OnCharacteristicWritten。
   * 仅在写入成功路径调用，故 success 固定 1 / error_code 固定 0。
   * @param ctx - GATT 写操作上下文
   */
  private emitWriteChrResponse(ctx: GattWriteContext): void {
    let primaryService = BleGattShared.getPrimaryService(ctx.gattServices, ctx.characteristic);
    let primaryServiceUuid1 = primaryService != null ? BleUtils.uuidStr(primaryService.serviceUuid) : '';
    let serviceUuid1 = BleUtils.uuidStr(ctx.characteristic.serviceUuid);
    let characteristicUuid1 = BleUtils.uuidStr(ctx.characteristic.characteristicUuid);
    let instanceId1 = BleGattShared.getInstanceId(ctx.characteristic, ctx.gattServices);
    // key1 须与 set 时构造的 key 逐段一致，方能命中缓存并清理。
    let key1: string = `${ctx.remoteId}:${primaryServiceUuid1}:${serviceUuid1}:${characteristicUuid1}:${instanceId1}`;
    let value1: Uint8Array | undefined = this.plugin.gattCache.writeChrMap.get(key1);
    this.plugin.gattCache.writeChrMap.delete(key1);
    if (value1 == null) {
      value1 = new Uint8Array(0);
    }
    let response: Map<string, string | number | Uint8Array> = new Map<string, string | number | Uint8Array>();
    response.set('remote_id', ctx.remoteId);
    if (primaryService != null) {
      response.set('primary_service_uuid', primaryServiceUuid1);
    }
    response.set('service_uuid', serviceUuid1);
    response.set('characteristic_uuid', characteristicUuid1);
    response.set('instance_id', instanceId1);
    response.set('value', value1);
    response.set('success', 1);
    response.set('error_code', 0);
    response.set('error_string', '');
    this.plugin.channel?.invokeMethod('OnCharacteristicWritten', response);
    ctx.result.success(true);
  }
}
