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
import HexUtil from './HexUtil';

/**
 * 蓝牙通知（Notify/Indicate）管理器。
 *
 * 从 BleGattManager 剥离的通知订阅逻辑：setNotifyValue
 * （开启/关闭特征通知并写 CCCD 描述符）、
 * 以及通知数据回调 BLECharacteristicChange（按设备注册的闭包）与 onCharacteristicReceived
 * （读取/通知共用，组装特征值并回传 OnCharacteristicReceived）。
 *
 * 跨 Manager 访问：
 *  - 共享缓存 deviceServicesMap / writeDescMap 经 plugin.gattCache 访问。
 *  - 已连接设备经 plugin.connectionManager.connectedDevices 反查。
 *  - locateCharacteristic / getDescriptorFromArray / getPrimaryService /
 *    getInstanceId 为 BleGattShared 静态工具。
 *  - onCharacteristicReceived 被 BleCharacteristicManager.readCharacteristic 调用
 *    （读完成回传特征值），故保持 public。
 *
 * BLECharacteristicChange 注册策略（对齐 Android BluetoothGattCallback）：
 *  - 在 handleConnected 时即按设备注册一个绑定 deviceId 的闭包（notifyCallbackMap），而非仅在
 *    readCharacteristic 里懒注册 → 即使 App 只 setNotifyValue 不先 read 也能收到通知（修 S5）。
 *  - 闭包内直接用捕获的 deviceId，不再遍历所有已连设备按 UUID 反查 →
 *    多设备相同 UUID 不再串台（修 S3）。
 */
export default class BleNotifyManager {
  /** 启用通知的 CCCD 写入值。 */
  public static readonly ENABLE_NOTIFICATION_VALUE: Uint8Array = new Uint8Array([0x01, 0x00]);
  /** 启用指示（indication）的 CCCD 写入值。 */
  public static readonly ENABLE_INDICATION_VALUE: Uint8Array = new Uint8Array([0x02, 0x00]);
  /** 关闭通知/指示的 CCCD 写入值。 */
  public static readonly DISABLE_NOTIFICATION_VALUE: Uint8Array = new Uint8Array([0x00, 0x00]);

  /** 插件引用，用于访问 connectionManager/gattCache/channel。 */
  private plugin: FlutterBluePlusOhosPlugin;

  /**
   * 每个已连接设备对应的 BLECharacteristicChange 回调（deviceId -> 闭包）。
   *
   * OHOS 的 BLECharacteristicChange 回调签名仅为 (characteristic: BLECharacteristic)，
   * 不含 deviceId（平台限制）。
   * 但回调是按 GattClientDevice 实例注册的，因此为每个设备创建一个，
   * **绑定 deviceId 的闭包**并注册，
   * 回调时直接用捕获的 deviceId 调用 onCharacteristicReceived —— 既无需遍历反查（修 S3），
   * 也保证连接时即注册、不依赖 readCharacteristic（修 S5）。
   */
  public notifyCallbackMap: Map<string, (characteristic: ble.BLECharacteristic) => Promise<void>> = new Map();

  /**
   * 构造通知管理器。
   * @param plugin - 宿主插件引用
   */
  constructor(plugin: FlutterBluePlusOhosPlugin) {
    this.plugin = plugin;
  }

  /**
   * 为指定设备构造 BLECharacteristicChange 回调闭包（绑定 deviceId）并注册到 gatt。
   * 在 handleConnected 时调用（对齐 Android：连接即注册，不依赖 read/notify）。
   * @param deviceId - 设备 ID
   * @param gatt - 该设备的 GattClientDevice
   */
  public registerCharacteristicChangeCallback(deviceId: string, gatt: ble.GattClientDevice): void {
    // 复用已存在的闭包，避免重复注册导致回调多次执行。
    if (this.notifyCallbackMap.has(deviceId)) {
      return;
    }
    // BLECharacteristicChange 回调签名不含 deviceId（平台限制），故在此构造闭包捕获 deviceId，
    // 直接派发给 onCharacteristicReceived —— 无需遍历所有已连设备按 UUID 反查，
    // 多设备相同 UUID 不串台。
    let callback = async (characteristicChangeReq: ble.BLECharacteristic) => {
      try {
        if (this.plugin.isDetached) {
          return;
        }
        // 注意：此回调由 BLE 栈异步触发，若 deviceServicesMap 缓存 miss 时调
        // gatt.getServices()，可能与 runGatt 保护的 GATT 操作并发触发 2900011。
        // 但正常流程 connect → discoverServices 已缓存服务，此处几乎不会 miss；
        // 即使 miss 并发，catch 兜底吞掉异常，仅丢失本条通知数据，不影响后续。
        let services = this.plugin.gattCache.deviceServicesMap.get(deviceId);
        if (services == null) {
          // 设备未发现服务缓存（理论上下游应已 discoverServices）时现场取一次，
          // 保证 onCharacteristicReceived 能定位 primary service。
          services = await gatt.getServices();
          this.plugin.gattCache.deviceServicesMap.set(deviceId, services);
        }
        this.onCharacteristicReceived(deviceId, services, characteristicChangeReq);
      } catch (e) {
        // 顶层兜底：通知数据到达回调异常必须吞掉，避免中断后续特征通知事件。
        BleUtils.log(hilog.LogLevel.ERROR,
          `onCharacteristicChange: unhandled error for ${deviceId}: ${JSON.stringify(e)}`);
      }
    };
    this.notifyCallbackMap.set(deviceId, callback);
    gatt.on('BLECharacteristicChange', callback);
  }

  /**
   * 注销指定设备的 BLECharacteristicChange 回调并从映射表移除。幂等。
   * @param deviceId - 设备 ID
   * @param gatt - 该设备的 GattClientDevice
   */
  public unregisterCharacteristicChangeCallback(deviceId: string, gatt: ble.GattClientDevice): void {
    let callback = this.notifyCallbackMap.get(deviceId);
    if (callback != null) {
      try {
        gatt.off('BLECharacteristicChange', callback);
      } catch (e) {
        BleUtils.log(hilog.LogLevel.WARN,
          `unregisterCharacteristicChangeCallback: off BLECharacteristicChange` +
            ` failed for ${deviceId}: ${JSON.stringify(e)}`);
      }
      this.notifyCallbackMap.delete(deviceId);
    }
  }

  /**
   * 处理 setNotifyValue：开启/关闭特征通知，并写入 CCCD 描述符。
   * @param call - 方法调用，args 含
   *   remote_id/service_uuid/characteristic_uuid/instance_id/force_indications/enable
   * @param result - 结果回调
   */
  async setNotifyValue(call: MethodCall, result: MethodResult): Promise<void> {
    let data: Map<string, string | number | boolean> = call.args;
    let remoteId: string = data.get('remote_id') as string;
    if (remoteId == null || remoteId == undefined || typeof remoteId !== 'string' || remoteId.length == 0) {
      BleUtils.log(hilog.LogLevel.ERROR, 'setNotifyValue failed: invalid remote_id');
      result.error('setNotifyValue', 'invalid remote_id', null);
      return;
    }
    let primaryServiceUuid: string = data.get('primary_service_uuid') as string;
    let serviceUuid: string = data.get('service_uuid') as string;
    let characteristicUuid: string = data.get('characteristic_uuid') as string;
    let instanceId = data.get('instance_id') as number;
    let forceIndications: boolean = data.get('force_indications') as boolean;
    let enable: boolean = data.get('enable') as boolean;
    let gatt: ble.GattClientDevice =
      this.plugin.connectionManager.connectedDevices.get(remoteId) as ble.GattClientDevice;
    if (gatt == null) {
      BleUtils.log(hilog.LogLevel.ERROR,
        'setNotifyValue failed for remoteId=' + remoteId + ': device is not connected');
      result.error('setNotifyValue', 'device is disconnected', null);
      return;
    }
    // 按设备串行执行 GATT 操作，避免 OHOS BLE 栈 2900011 "operation is busy" 错误。
    await this.plugin.gattCache.runGatt(remoteId, async () => {
      // 优先使用 deviceServicesMap 缓存，对齐 readCharacteristic/writeCharacteristic 的策略。
      let gattServices: ble.GattService[] | undefined =
        this.plugin.gattCache.deviceServicesMap.get(remoteId);
      if (gattServices == null) {
        gattServices = await gatt.getServices();
        this.plugin.gattCache.deviceServicesMap.set(remoteId, gattServices);
      }
      if (gattServices == null || gattServices == undefined) {
        BleUtils.log(hilog.LogLevel.ERROR,
          'setNotifyValue failed for remoteId=' + remoteId + ': no services discovered');
        result.error('setNotifyValue', 'no service ', null);
        return;
      }
      let found: ChrFound | undefined =
        await BleGattShared.locateCharacteristic(primaryServiceUuid, serviceUuid,
          characteristicUuid, instanceId, gattServices);
      if (found == null || found.error != null) {
        let err: string = found == null ? 'characteristic not found' : found.error as string;
        BleUtils.log(hilog.LogLevel.ERROR, 'setNotifyValue failed for remoteId=' + remoteId + ': ' + err);
        result.error('setNotifyValue', err, null);
        return;
      }
      let characteristic: ble.BLECharacteristic | null = found.characteristic ?? null;
      if (characteristic == null) {
        BleUtils.log(hilog.LogLevel.ERROR, 'setNotifyValue failed for remoteId=' + remoteId + ': characteristic is null');
        result.error('setNotifyValue', 'Characteristic not found', null);
        return;
      }
      let target = new GattWriteTarget(remoteId, primaryServiceUuid, serviceUuid, characteristicUuid, instanceId);
      let ctx = new GattWriteContext(gatt, characteristic, gattServices, target, result);
      await this.applyNotifyAndWriteCccd(ctx, forceIndications, enable);
    });
  }

  /**
   * 使能特征通知并写入 CCCD 描述符。
   * setCharacteristicChangeNotification 注册失败必须回传并提前返回
   * （否则 CCCD 写入成功也无实际通知效果）；
   * 无 CCCD 时回传 success(false)；CCCD 值不支持时由 resolveNotifyDescriptorValue 回传错误。
   * @param ctx - GATT 写操作上下文
   * @param forceIndications - 是否强制指示
   * @param enable - true 开启 / false 关闭
   */
  private async applyNotifyAndWriteCccd(ctx: GattWriteContext, forceIndications: boolean,
    enable: boolean): Promise<void> {
    try {
      await ctx.gatt.setCharacteristicChangeNotification(ctx.characteristic, enable);
    } catch (e) {
      let error = e as BusinessError;
      BleUtils.log(hilog.LogLevel.ERROR,
        `setNotifyValue: failed to set characteristic notification for remoteId=${ctx.remoteId}: ${JSON.stringify(e)}`);
      // 注册失败必须回传并提前返回：否则后续 CCCD 写入即使成功也无实际通知效果
      // （原生监听未真正建立）。
      ctx.result.error('setNotifyValue', `failed to set notification: ${error?.message ?? 'unknown'}`, null);
      return;
    }
    let descriptor: ble.BLEDescriptor | null =
      BleGattShared.getDescriptorFromArray(BleUtils.CCCD, ctx.characteristic.descriptors);
    if (descriptor == null) {
      // Preserve the local contract: a missing CCCD must fail explicitly.
      BleUtils.log(hilog.LogLevel.ERROR,
        `setNotifyValue failed for remoteId=${ctx.remoteId}: CCCD descriptor not found`);
      ctx.result.error('setNotifyValue', 'CCCD descriptor not found', null);
      return;
    }
    let descriptorValue: Uint8Array | null = this.resolveNotifyDescriptorValue(ctx.characteristic, forceIndications,
      enable, ctx.remoteId, ctx.result);
    if (descriptorValue == null) {
      // resolveNotifyDescriptorValue 已通过 result 回传错误
      return;
    }
    await this.writeNotifyDescriptor(ctx, descriptor, descriptorValue);
  }

  /**
   * 解析 CCCD 描述符写入值（enable=通知/指示；disable=全零）。
   * @returns 描述符值；若属性不支持则通过 result 回传错误并返回 null
   */
  private resolveNotifyDescriptorValue(characteristic: ble.BLECharacteristic, forceIndications: boolean,
    enable: boolean, remoteId: string, result: MethodResult): Uint8Array | null {
    if (!enable) {
      return BleNotifyManager.DISABLE_NOTIFICATION_VALUE;
    }
    let characteristicUuid: string = BleUtils.uuidStr(characteristic.characteristicUuid);
    let canNotify: boolean = characteristic.properties?.notify as boolean;
    let canIndicate: boolean = characteristic.properties?.indicate as boolean;
    if (!canIndicate && !canNotify) {
      BleUtils.log(hilog.LogLevel.ERROR,
        `setNotifyValue failed for remoteId=${remoteId}: neither NOTIFY nor INDICATE` +
          ` properties are supported for chr=${characteristicUuid}`);
      result.error('setNotifyValue',
        'neither NOTIFY nor INDICATE properties are supported by this BLE characteristic', null);
      return null;
    }
    if (forceIndications && !canIndicate) {
      BleUtils.log(hilog.LogLevel.ERROR,
        `setNotifyValue failed for remoteId=${remoteId}: INDICATE not supported` +
          ` for chr=${characteristicUuid}, force_indications requested`);
      result.error('setNotifyValue', 'INDICATE not supported by this BLE characteristic', null);
      return null;
    }
    let descriptorValue: Uint8Array | null = null;
    if (canIndicate) {
      descriptorValue = BleNotifyManager.ENABLE_INDICATION_VALUE;
    }
    if (canNotify) {
      descriptorValue = BleNotifyManager.ENABLE_NOTIFICATION_VALUE;
    }
    if (forceIndications) {
      descriptorValue = BleNotifyManager.ENABLE_INDICATION_VALUE;
    }
    return descriptorValue;
  }

  /**
   * 写入 CCCD 描述符并在完成后回传 OnDescriptorWritten。
   * 缓存写入值（writeDescMap）以便回传时取回，写入失败回传 result.error。
   * 采用 async/await + try-catch：await writeDescriptorValue 后的组装逻辑（emitNotifyDescResponse 内的
   * getPrimaryService 等）抛出的异常同样进入 catch，
   * 保证异常传播完整、不产生未捕获的 rejection。
   */
  private async writeNotifyDescriptor(ctx: GattWriteContext, descriptor: ble.BLEDescriptor,
    descriptorValue: Uint8Array): Promise<void> {
    // remember the data we are writing
    let key: string = this.buildWriteNotifyKey(ctx);
    this.plugin.gattCache.writeDescMap.set(key, descriptorValue as Uint8Array);
    // write descriptor
    if (descriptorValue) {
      let u8Array: Uint8Array = new Uint8Array(descriptorValue);
      descriptor.descriptorValue = BleUtils.typedArrayToBuffer(u8Array);
    }
    try {
      await ctx.gatt.writeDescriptorValue(descriptor);
      // 组装并回传：保留在 try 内，使 getPrimaryService 等异常进入 catch 并清理缓存。
      this.emitNotifyDescResponse(ctx, descriptor);
    } catch (e) {
      let error = e as BusinessError;
      BleUtils.log(hilog.LogLevel.ERROR,
        `setNotifyValue failed for remoteId=${ctx.remoteId}: writeDescriptorValue failed` +
          `, errCode=${error?.code}, errMsg=${error?.message}`);
      // 写入失败：清理刚缓存的写入值，避免 writeDescMap 残留（clearForDevice 不清此 Map）。
      this.plugin.gattCache.writeDescMap.delete(key);
      ctx.result.error('setNotifyValue', 'gatt.writeDescriptor() returned false', null);
    }
  }

  /**
   * 构造通知 CCCD 写入缓存键（remoteId:psu:su:cu:instanceId:CCCD）。
   * primaryServiceUuid 为 null 时归一化为 ''，须与 emitNotifyDescResponse 的 key1 重建逻辑保持一致。
   * @param ctx - GATT 写操作上下文
   * @returns 缓存键
   */
  private buildWriteNotifyKey(ctx: GattWriteContext): string {
    let primaryServiceUuid: string = ctx.primaryServiceUuid == null ? '' : ctx.primaryServiceUuid;
    return ctx.remoteId + ':' + primaryServiceUuid + ':' + ctx.serviceUuid + ':' +
      ctx.characteristicUuid + ':' + ctx.instanceId + ':' + BleUtils.CCCD;
  }

  /**
   * 写入成功后：按响应侧归一化键取回缓存值、组装并回传 OnDescriptorWritten。
   * 仅在写入成功路径调用，故 success 固定 1 / error_code 固定 0。
   * @param ctx - GATT 写操作上下文
   * @param descriptor - 写入的目标描述符（用于响应侧 UUID）
   */
  private emitNotifyDescResponse(ctx: GattWriteContext, descriptor: ble.BLEDescriptor): void {
    let primaryService = BleGattShared.getPrimaryService(ctx.gattServices, ctx.characteristic);
    let respPrimaryServiceUuid: string =
      primaryService != null ? BleUtils.uuidStr(primaryService.serviceUuid) : '';
    let respServiceUuid: string = BleUtils.uuidStr(descriptor?.serviceUuid as string);
    let respCharacteristicUuid: string = BleUtils.uuidStr(descriptor?.characteristicUuid as string);
    let respInstanceId: number = BleGattShared.getInstanceId(ctx.characteristic, ctx.gattServices);
    let respDescriptorUuid: string = BleUtils.uuidStr(descriptor?.descriptorUuid as string);
    // what data did we write?
    let key1: string =
      `${ctx.remoteId}:${respPrimaryServiceUuid}:${respServiceUuid}:` +
      `${respCharacteristicUuid}:${respInstanceId}:${respDescriptorUuid}`;
    let value1: Uint8Array | undefined = this.plugin.gattCache.writeDescMap.get(key1);
    this.plugin.gattCache.writeDescMap.delete(key1);
    if (value1 == null) {
      value1 = new Uint8Array(0);
    }
    let response: Map<string, string | number | Uint8Array> = new Map<string, string | number | Uint8Array>();
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
    response.set('error_string', 'GATT_SUCCESS');
    this.plugin.channel?.invokeMethod('OnDescriptorWritten', response);
    ctx.result.success(true);
  }

  /**
   * 读取/通知回调中共用的特征值到达处理：组装 BmCharacteristicData
   * 并回传 OnCharacteristicReceived。
   * Generic Attribute service 0x1801 的 Service Changed 0x2A05 触发 OnServicesReset。
   * @param address - 设备 ID
   * @param services - 该设备的 GATT 服务数组
   * @param characteristic - 到达的特征
   */
  onCharacteristicReceived(address: string, services: ble.GattService[],
    characteristic: ble.BLECharacteristic): void {
    // Generic Attribute service 0x1801
    if (BleUtils.uuidStr(characteristic.serviceUuid) == '1801') {
      // Service Changed 0x2A05
      if (BleUtils.uuidStr(characteristic.characteristicUuid).toUpperCase() == '2A05') {
        // 设备服务结构发生变化，清除服务缓存以强制 discoverServices 重新获取。
        // 否则 read/write/setNotifyValue 仍使用旧缓存，可能定位到已不存在的特征。
        this.plugin.gattCache.deviceServicesMap.delete(address);
        let response: Map<string, string> = BleUtils.bmBluetoothDevice(address);
        this.plugin.channel?.invokeMethod('OnServicesReset', response);
      }
    }
    let primaryService: ble.GattService | null = BleGattShared.getPrimaryService(services, characteristic);
    let response: Map<string, string | number | Uint8Array> = new Map<string, string | number | Uint8Array>();
    response.set('remote_id', address);
    if (primaryService != null) {
      response.set('primary_service_uuid', BleUtils.uuidStr(primaryService.serviceUuid));
    }
    response.set('service_uuid', BleUtils.uuidStr(characteristic.serviceUuid));
    response.set('characteristic_uuid', BleUtils.uuidStr(characteristic.characteristicUuid));
    let instanceId: number = BleGattShared.getInstanceId(characteristic, services);
    response.set('instance_id', instanceId);
    response.set('value', new Uint8Array(characteristic.characteristicValue));
    response.set('success', 1);
    response.set('error_code', 0);
    response.set('error_string', 'GATT_SUCCESS');
    this.plugin.channel?.invokeMethod('OnCharacteristicReceived', response);
    // BLE 调试助手发送数据成功：打印接收到的特征值（测试用例日志）
    BleUtils.log(hilog.LogLevel.DEBUG, 'characteristic value: ' + HexUtil.formatHexString(new Uint8Array(characteristic.characteristicValue)));
  }

  /** 清空所有通知回调映射。cleanup 全局清理时调用
   * （gatt 的 off 由 cleanup 遍历 per-device 完成）。 */
  clearAll(): void {
    this.notifyCallbackMap.clear();
  }
}
