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
import { ble } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import BleUtils from './BleUtils';
import BleGattShared, { ChrFound, GattWriteContext, GattWriteTarget } from './BleGattShared';
import FlutterBluePlusOhosPlugin from './FlutterBluePlusOhosPlugin';

/**
 * 蓝牙描述符（Descriptor）读写管理器。
 *
 * 从 BleGattManager 剥离的描述符读写逻辑：readDescriptor（读取描述符值并回传
 * OnDescriptorRead）、writeDescriptor（MTU 长度校验后写入并回传 OnDescriptorWritten）。
 *
 * 跨 Manager 访问：
 *  - 共享缓存 writeDescMap / mtuMap 经 plugin.gattCache 访问。
 *  - 已连接设备 GattClientDevice 经 plugin.connectionManager.connectedDevices 反查。
 *  - locateCharacteristic / getReadDescriptorFromArray / getPrimaryService / getInstanceId
 *   为 BleGattShared 静态工具。
 */
export default class BleDescriptorManager {
  /** 插件引用，用于访问 connectionManager/gattCache/channel。 */
  private plugin: FlutterBluePlusOhosPlugin;

  /**
   * 构造描述符读写管理器。
   * @param plugin - 宿主插件引用
   */
  constructor(plugin: FlutterBluePlusOhosPlugin) {
    this.plugin = plugin;
  }

  /**
   * 处理 readDescriptor：读取指定描述符值并通过 OnDescriptorRead 回传。
   * @param call - 方法调用，args 含
   *   remote_id/primary_service_uuid/service_uuid/
   *   characteristic_uuid/instance_id/descriptor_uuid
   * @param result - 结果回调
   */
  async readDescriptor(call: MethodCall, result: MethodResult): Promise<void> {
    let data: Map<string, string | number> = call.args;
    let remoteId: string = data.get('remote_id') as string;
    if (remoteId == null || remoteId == undefined || typeof remoteId !== 'string' || remoteId.length == 0) {
      BleUtils.log(hilog.LogLevel.ERROR, 'readDescriptor failed: invalid remote_id');
      result.error('readDescriptor', 'invalid remote_id', null);
      return;
    }
    let primaryServiceUuid: string = data.get('primary_service_uuid') as string;
    let serviceUuid: string = data.get('service_uuid') as string;
    let characteristicUuid: string = data.get('characteristic_uuid') as string;
    let instanceId: number = data.get('instance_id') as number;
    let descriptorUuid: string = data.get('descriptor_uuid') as string;
    let gatt: ble.GattClientDevice =
      this.plugin.connectionManager.connectedDevices.get(remoteId) as ble.GattClientDevice;
    if (gatt == null) {
      BleUtils.log(hilog.LogLevel.ERROR, 'readDescriptor failed: device is disconnected');
      result.error('readDescriptor', 'device is disconnected', null);
      return;
    }
    // 按设备串行执行 GATT 操作，避免 OHOS BLE 栈 2900011 "operation is busy" 错误。
    await this.plugin.gattCache.runGatt(remoteId, async () => {
      let services: ble.GattService[] | undefined =
        this.plugin.gattCache.deviceServicesMap.get(remoteId);
      if (services == null) {
        services = await gatt.getServices();
        this.plugin.gattCache.deviceServicesMap.set(remoteId, services);
      }
      let found: ChrFound | undefined =
        await BleGattShared.locateCharacteristic(primaryServiceUuid, serviceUuid, characteristicUuid, instanceId,
          services);
      if (found == null || found.error != null) {
        let err: string = found == null ? 'characteristic not found' : found.error as string;
        BleUtils.log(hilog.LogLevel.ERROR, `readDescriptor failed: ${err}`);
        result.error('readDescriptor', err, null);
        return;
      }
      let characteristic: ble.BLECharacteristic | null = found.characteristic ?? null;
      if (characteristic == null) {
        BleUtils.log(hilog.LogLevel.ERROR, 'readDescriptor failed: characteristic is null');
        result.error('readDescriptor', 'Characteristic not found', null);
        return;
      }
      let descriptor: ble.BLEDescriptor | null =
        BleGattShared.getReadDescriptorFromArray(descriptorUuid, characteristic.descriptors);
      if (descriptor == null) {
        let s: string =
          'descriptor not found on characteristic. (desc: ' + descriptorUuid + ' chr: ' + characteristicUuid + ')';
        BleUtils.log(hilog.LogLevel.ERROR, `readDescriptor failed: ${s}`);
        result.error('readDescriptor', s, null);
        return;
      }
      let errorMessage: string = '';
      let errorCode: number = 0;
      let readDescriptor: ble.BLEDescriptor | null = null;
      // 「失败标记」语义：异常时置 true；
      // 因上方 catch 已 return，到达响应构造时必为 false（success=1）。
      let readDescriptorFlag: boolean = false;
      try {
        readDescriptor = await gatt.readDescriptorValue(descriptor);
      } catch (e) {
        let error = e as BusinessError;
        errorMessage = error.message;
        errorCode = error.code;
        readDescriptorFlag = true;
        BleUtils.log(hilog.LogLevel.ERROR,
          `readDescriptor failed: gatt.readDescriptor() returned false, ` +
          `errorCode=${errorCode}, errorMessage=${errorMessage}`);
        result.error('readDescriptor', 'gatt.readDescriptor() returned false', null);
        return;
      }
      let primaryService: ble.GattService | null = BleGattShared.getPrimaryService(services, characteristic);
      this.emitReadDescResponse(remoteId, characteristic, readDescriptor, primaryService, services,
        readDescriptorFlag, errorCode, errorMessage, result);
    });
  }

  /**
   * 组装并回传 OnDescriptorRead。
   * success 依失败标记取 0/1（到达此处时 catch 路径已 return，正常为 1）。
   * @param remoteId - 设备 ID
   * @param characteristic - 定位到的特征（用于 instance_id）
   * @param readDescriptor - 读取到的描述符（含值与响应侧 UUID）
   * @param primaryService - 主服务（可能为 null）
   * @param services - GATT 服务树（用于 instance_id 计算）
   * @param failed - 失败标记（异常时 true）
   * @param errorCode - 错误码
   * @param errorMessage - 错误信息
   * @param result - 结果回调
   */
  private emitReadDescResponse(remoteId: string, characteristic: ble.BLECharacteristic,
    readDescriptor: ble.BLEDescriptor, primaryService: ble.GattService | null, services: ble.GattService[],
    failed: boolean, errorCode: number, errorMessage: string, result: MethodResult): void {
    let response: Map<string, string | number | object> = new Map<string, string | number | object>();
    if (primaryService != null) {
      response.set('primary_service_uuid', BleUtils.uuidStr(primaryService.serviceUuid));
    }
    response.set('remote_id', remoteId);
    response.set('service_uuid', BleUtils.uuidStr(readDescriptor.serviceUuid));
    response.set('instance_id', BleGattShared.getInstanceId(characteristic, services));
    response.set('characteristic_uuid', BleUtils.uuidStr(readDescriptor.characteristicUuid));
    response.set('descriptor_uuid', BleUtils.uuidStr(readDescriptor.descriptorUuid));
    response.set('value', new Uint8Array(readDescriptor.descriptorValue));
    response.set('success', failed ? 0 : 1);
    response.set('error_code', errorCode);
    response.set('error_string', errorMessage);
    this.plugin.channel?.invokeMethod('OnDescriptorRead', response);
    result.success(true);
  }

  /**
   * 处理 writeDescriptor：写入指定描述符值（含 MTU 长度校验）并通过 OnDescriptorWritten 回传。
   * @param call - 方法调用，args 含
   *   remote_id/primary_service_uuid/service_uuid/
   *   characteristic_uuid/instance_id/descriptor_uuid/value
   * @param result - 结果回调
   */
  async writeDescriptor(call: MethodCall, result: MethodResult): Promise<void> {
    let data: Map<string, object | string | number> = call.args;
    let remoteId = data.get('remote_id') as string;
    if (remoteId == null || remoteId == undefined || typeof remoteId !== 'string' || remoteId.length == 0) {
      BleUtils.log(hilog.LogLevel.ERROR, 'writeDescriptor failed: invalid remote_id');
      result.error('writeDescriptor', 'invalid remote_id', null);
      return;
    }
    let primaryServiceUuid = data.get('primary_service_uuid') as string;
    let serviceUuid = data.get('service_uuid') as string;
    let characteristicUuid = data.get('characteristic_uuid') as string;
    let instanceId = data.get('instance_id') as number;
    let descriptorUuid = data.get('descriptor_uuid') as string;
    let value = data.get('value') as Uint8Array;
    let gatt: ble.GattClientDevice =
      this.plugin.connectionManager.connectedDevices.get(remoteId) as ble.GattClientDevice;
    if (gatt == null) {
      BleUtils.log(hilog.LogLevel.ERROR, 'writeDescriptor failed: device is disconnected');
      result.error('writeDescriptor', 'device is disconnected', null);
      return;
    }
    // 按设备串行执行 GATT 操作，避免 OHOS BLE 栈 2900011 "operation is busy" 错误。
    await this.plugin.gattCache.runGatt(remoteId, async () => {
      let gattService: ble.GattService[] | undefined =
        this.plugin.gattCache.deviceServicesMap.get(remoteId);
      if (gattService == null) {
        gattService = await gatt.getServices();
        this.plugin.gattCache.deviceServicesMap.set(remoteId, gattService);
      }
      let found: ChrFound | undefined =
        await BleGattShared.locateCharacteristic(primaryServiceUuid, serviceUuid, characteristicUuid, instanceId,
          gattService);
    if (found == null || found.error != null) {
      let err: string = found == null ? 'characteristic not found' : found.error as string;
      BleUtils.log(hilog.LogLevel.ERROR, `writeDescriptor failed: ${err}`);
      result.error('writeDescriptor', err, null);
      return;
    }
    let characteristic: ble.BLECharacteristic | null = found.characteristic ?? null;
    if (characteristic == null) {
      BleUtils.log(hilog.LogLevel.ERROR, 'writeDescriptor failed: characteristic is null');
      result.error('writeDescriptor', 'Characteristic not found', null);
      return;
    }
    let descriptor: ble.BLEDescriptor | null =
      BleGattShared.getReadDescriptorFromArray(descriptorUuid, characteristic.descriptors);
    if (descriptor == null) {
      let s: string =
        'descriptor not found on characteristic. (desc: ' + descriptorUuid + ' chr: ' + characteristicUuid + ')';
      BleUtils.log(hilog.LogLevel.ERROR, `writeDescriptor failed: ${s}`);
      result.error('writeDescriptor', s, null);
      return;
    }
    // MTU 长度校验：描述符负载不得超过 MTU-3（扣除 3 字节 ATT 操作头），超长直接回错。
    // mtuMap 缺项（未协商 MTU / clearForDevice 清理后）时兜底为默认值 23，
    // 避免 undefined-3=NaN 致校验恒放行。
    let mtu: number = this.plugin.gattCache.mtuMap.get(remoteId) as number;
    if (mtu == null) {
      mtu = 23;
    }
    if ((mtu - 3) < value.length) {
      let s: string = 'data longer than mtu allows. dataLength: ' + value.length + '> max: ' + (mtu - 3);
      BleUtils.log(hilog.LogLevel.ERROR, `writeDescriptor failed: ${s}`);
      result.error('writeDescriptor', s, null);
      return;
    }
    let target = new GattWriteTarget(remoteId, primaryServiceUuid, serviceUuid, characteristicUuid, instanceId);
    let ctx = new GattWriteContext(gatt, characteristic, gattService, target, result);
    await this.executeWriteDescriptor(ctx, descriptor, value, descriptorUuid);
    }); // runGatt
  }

  /**
   * 执行描述符写入并回传 OnDescriptorWritten。
   * 缓存写入值（writeDescMap）以便回传时取回，写入失败回传 result.error。
   */
  private async executeWriteDescriptor(ctx: GattWriteContext, descriptor: ble.BLEDescriptor,
    value: Uint8Array, descriptorUuid: string): Promise<void> {
    // 缓存写入值，回传 OnDescriptorWritten 时按相同键取回实际写入的字节。
    let key: string = this.buildWriteDescKey(ctx, descriptorUuid);
    this.plugin.gattCache.writeDescMap.set(key, value);
    let writeValue: ArrayBuffer = BleUtils.typedArrayToBuffer(value as Uint8Array);
    descriptor.descriptorValue = writeValue;
    try {
      await ctx.gatt.writeDescriptorValue(descriptor);
    } catch (e) {
      let error = e as BusinessError;
      BleUtils.log(hilog.LogLevel.ERROR,
        `writeDescriptor failed: gatt.writeDescriptor() returned false, ` +
        `errorCode=${error.code}, errorMessage=${error.message}`);
      // 写入失败：清理刚缓存的写入值，避免 writeDescMap 残留（clearForDevice 不清此 Map）。
      this.plugin.gattCache.writeDescMap.delete(key);
      ctx.result.error('writeDescriptor', 'gatt.writeDescriptor() returned false', null);
      return;
    }
    this.emitWriteDescResponse(ctx, descriptor);
  }

  /**
   * 构造写描述符缓存键（remoteId:psu:su:cu:instanceId:descriptorUuid）。
   * primaryServiceUuid 为 null 时归一化为 ''，须与 emitWriteDescResponse 的 key1 重建逻辑保持一致。
   * @param ctx - GATT 写操作上下文
   * @param descriptorUuid - 描述符 UUID（请求侧原值）
   * @returns 缓存键
   */
  private buildWriteDescKey(ctx: GattWriteContext, descriptorUuid: string): string {
    let primaryServiceUuid: string = ctx.primaryServiceUuid == null ? '' : ctx.primaryServiceUuid;
    return ctx.remoteId + ':' + primaryServiceUuid + ':' + ctx.serviceUuid + ':' +
      ctx.characteristicUuid + ':' + ctx.instanceId + ':' + descriptorUuid;
  }

  /**
   * 写入成功后：按响应侧归一化键取回缓存值、组装并回传 OnDescriptorWritten。
   * 仅在写入成功路径调用，故 success 固定 1 / error_code 固定 0。
   * @param ctx - GATT 写操作上下文
   * @param descriptor - 写入的目标描述符（用于响应侧 UUID）
   */
  private emitWriteDescResponse(ctx: GattWriteContext, descriptor: ble.BLEDescriptor): void {
    let primaryService = BleGattShared.getPrimaryService(ctx.gattServices, ctx.characteristic);
    let respPrimaryServiceUuid: string =
      primaryService != null ? BleUtils.uuidStr(primaryService.serviceUuid) : '';
    let respServiceUuid: string = BleUtils.uuidStr(descriptor.serviceUuid);
    let respCharacteristicUuid: string = BleUtils.uuidStr(descriptor.characteristicUuid) as string;
    let respInstanceId: number = BleGattShared.getInstanceId(ctx.characteristic, ctx.gattServices);
    let respDescriptorUuid: string = BleUtils.uuidStr(descriptor.descriptorUuid);
    // key1 须与 set 时构造的 key 逐段一致，方能命中缓存并清理。
    let key1: string =
      `${ctx.remoteId}:${respPrimaryServiceUuid}:${respServiceUuid}:` +
      `${respCharacteristicUuid}:${respInstanceId}:${respDescriptorUuid}`;
    let value1: Uint8Array | undefined = this.plugin.gattCache.writeDescMap.get(key1);
    this.plugin.gattCache.writeDescMap.delete(key1);
    if (value1 == null) {
      value1 = new Uint8Array(0);
    }
    let response: Map<string, object | string | number> = new Map();
    response.set('remote_id', ctx.remoteId);
    if (primaryService != null) {
      response.set('primary_service_uuid', respPrimaryServiceUuid);
    }
    response.set('service_uuid', respServiceUuid);
    response.set('characteristic_uuid', respCharacteristicUuid);
    response.set('descriptor_uuid', respDescriptorUuid);
    response.set('instance_id', respInstanceId);
    response.set('value', value1);
    response.set('success', 1);
    response.set('error_code', 0);
    response.set('error_string', '');
    this.plugin.channel?.invokeMethod('OnDescriptorWritten', response);
    ctx.result.success(true);
  }
}
