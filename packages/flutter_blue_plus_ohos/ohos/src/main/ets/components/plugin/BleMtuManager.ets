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
import FlutterBluePlusOhosPlugin from './FlutterBluePlusOhosPlugin';

/**
 * 蓝牙 MTU 管理器。
 *
 * 从 BleGattManager 剥离的 MTU 协商逻辑：mtuCallbackMap（每设备 BLEMtuChange 回调闭包）、
 * registerMtuCallback / unregisterMtuCallback（按设备注册/注销，避免多设备并发 MTU 串台）、
 * emitMtuChanged（协商完成回传 OnMtuChanged）、requestMtu（method handler）。
 *
 * 跨 Manager 访问：
 *  - MTU 缓存 mtuMap 是跨组共享字段（BleConnectionManager 连接成功时初始化=23、断开时清理；
 *    getMaxPayload/writeDescriptor 也读），故仍由 BleGattManager 持有，本类经
 *    this.plugin.gattCache.mtuMap 反向读写（与 BleBondManager 访问 connectedDevices 模式一致）。
 *  - requestMtu 需已连接设备的 GattClientDevice，经 plugin.connectionManager.connectedDevices 反查。
 */
export default class BleMtuManager {
  /** 插件引用，用于访问 connectionManager.connectedDevices、channel、gattManager.mtuMap。 */
  private plugin: FlutterBluePlusOhosPlugin;

  /**
   * 每个已连接设备对应的 BLEMtuChange 回调（deviceId -> 闭包）。
   *
   * OHOS 的 BLEMtuChange 回调签名仅为 (mtu: number)，不含 deviceId（平台限制）。
   * 但 BLEMtuChange 是按 GattClientDevice 实例注册的，因此为每个设备创建一个
   * 绑定了 deviceId 的闭包并注册，回调时即可精确写入对应设备的 MTU，
   * 避免多设备并发时 MTU 数据写入错误设备条目。
   */
  public mtuCallbackMap: Map<string, (mtu: number) => void> = new Map();

  /**
   * 构造 MTU 管理器。
   * @param plugin - 宿主插件引用
   */
  constructor(plugin: FlutterBluePlusOhosPlugin) {
    this.plugin = plugin;
  }

  /**
   * 为指定设备构造 BLEMtuChange 回调闭包（绑定 deviceId）并注册到 gatt。
   * @param deviceId - 设备 ID
   * @param gatt - 该设备的 GattClientDevice
   */
  public registerMtuCallback(deviceId: string, gatt: ble.GattClientDevice): void {
    // 复用已存在的闭包，避免重复注册导致回调多次执行。
    if (this.mtuCallbackMap.has(deviceId)) {
      return;
    }
    // BLEMtuChange 回调签名仅 (mtu: number)、不含 deviceId（平台限制），
    // 故在此构造闭包捕获 deviceId 再透传给 emitMtuChanged，
    // 保证多设备并发协商时各设备 MTU 写入各自条目而非混淆。
    let callback = (mtu: number) => {
      this.emitMtuChanged(deviceId, mtu);
    };
    this.mtuCallbackMap.set(deviceId, callback);
    gatt.on('BLEMtuChange', callback);
  }

  /**
   * 注销指定设备的 BLEMtuChange 回调并从映射表移除。幂等。
   * @param deviceId - 设备 ID
   * @param gatt - 该设备的 GattClientDevice
   */
  public unregisterMtuCallback(deviceId: string, gatt: ble.GattClientDevice): void {
    let callback = this.mtuCallbackMap.get(deviceId);
    if (callback != null) {
      try {
        gatt.off('BLEMtuChange', callback);
      } catch (e) {
        BleUtils.log(hilog.LogLevel.WARN,
          `unregisterMtuCallback: off BLEMtuChange failed for ${deviceId}: ${JSON.stringify(e)}`);
      }
      this.mtuCallbackMap.delete(deviceId);
    }
  }

  /**
   * 处理 MTU 协商完成：更新对应设备的 MTU 缓存并回传 OnMtuChanged。
   * 顶层 try-catch 防止回调异常中断后续 BLE 事件。
   * @param deviceId - 设备 ID
   * @param mtu - 协商后的 MTU 值
   */
  private emitMtuChanged(deviceId: string, mtu: number): void {
    try {
      if (this.plugin.isDetached) {
        return;
      }
      // 按 deviceId 写入 MTU 缓存（mtuMap 为跨组共享，由 gattManager 持有）：
      // 闭包已绑定 deviceId，多设备互不干扰。
      this.plugin.gattCache.mtuMap.set(deviceId, mtu);
      let response: Map<string, string | number> = new Map<string, string | number>();
      response.set('remote_id', deviceId);
      response.set('mtu', mtu);
      response.set('success', 1);
      response.set('error_code', 0);
      response.set('error_string', 'GATT_SUCCESS');
      this.plugin.channel?.invokeMethod('OnMtuChanged', response);
    } catch (e) {
      BleUtils.log(hilog.LogLevel.ERROR,
        `emitMtuChanged: unhandled error for ${deviceId}: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 处理 requestMtu：发起 MTU 协商。
   *
   * 对齐 Android `requestMtu`：仅调用 setBLEMtuSize 发起协商并 result.success(true)，
   * **不在本方法内预置 mtuMap 或回传 OnMtuChanged**。真实协商后的 MTU 由连接时注册的
   * BLEMtuChange 回调（emitMtuChanged）统一送达。
   *
   * 若在此预发"请求值"：Dart 侧 requestMtu 用 `onMtuChanged...first` 取值，会抢先取到
   * 请求值（往往大于实际协商值），
   * 导致 getMaxPayload/writeDescriptor 校验放行而实际越界写入失败。
   * @param call - 方法调用，args 含 remote_id/mtu
   * @param result - 结果回调
   */
  async requestMtu(call: MethodCall, result: MethodResult): Promise<void> {
    let data: Map<string, string | number> = call.args;
    let remoteId: string = data.get('remote_id') as string;
    if (remoteId == null || remoteId == undefined || typeof remoteId !== 'string' || remoteId.length == 0) {
      BleUtils.log(hilog.LogLevel.ERROR, 'requestMtu failed: invalid remote_id');
      result.error('requestMtu', 'invalid remote_id', null);
      return;
    }
    let mtu: number = data.get('mtu') as number;
    let gatt: ble.GattClientDevice =
      this.plugin.connectionManager.connectedDevices.get(remoteId) as ble.GattClientDevice;
    if (gatt == null) {
      BleUtils.log(hilog.LogLevel.ERROR,
        'requestMtu failed for remoteId=' + remoteId + ': device is not connected');
      result.error('requestMtu', 'gatt.requestMtu() returned false', null);
      return;
    }
    try {
      gatt.setBLEMtuSize(mtu);
    } catch (e) {
      let error = e as BusinessError;
      BleUtils.log(hilog.LogLevel.ERROR,
        `requestMtu failed for remoteId=${remoteId}: setBLEMtuSize failed, ` +
          `errCode=${error.code}, errMsg=${error.message}`);
      result.error('requestMtu', 'gatt.requestMtu() returned false', null);
      return;
    }
    // 不预置 mtuMap / 不预发 OnMtuChanged：真实 MTU 由 BLEMtuChange 回调送达，
    // 避免 Dart 取到偏大的请求值。
    result.success(true);
  }

  /** 清空所有 MTU 回调映射。cleanup 全局清理时调用。 */
  clearAll(): void {
    this.mtuCallbackMap.clear();
  }
}
