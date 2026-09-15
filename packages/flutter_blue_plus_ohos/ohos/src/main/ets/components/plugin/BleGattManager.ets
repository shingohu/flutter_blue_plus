/*
 * Copyright (C) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
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
import { List } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import BleUtils from './BleUtils';
import BleGattShared from './BleGattShared';
import FlutterBluePlusOhosPlugin from './FlutterBluePlusOhosPlugin';

/**
 * 蓝牙 GATT 管理器。
 *
 * 集中管理 GATT 服务发现、RSSI/设备名读取、clearGattCache/getPhySupport，
 * 以及 onCharacteristicReceived/onDiscoveredServices 回调（facade，业务读写委托子 Manager）。
 * MTU 协商逻辑（registerMtuCallback/emitMtuChanged/requestMtu）已剥离至 BleMtuManager；
 * 通知订阅与 BLECharacteristicChange 回调已剥离至 BleNotifyManager。
 * 跨 Manager 访问通过 plugin 中介（this.plugin.connectionManager.connectedDevices 等）。
 */
export default class BleGattManager {
  /** 插件引用，用于访问 isDetached/channel/connectionManager/gattCache/notifyManager。 */
  private plugin: FlutterBluePlusOhosPlugin;

  /**
   * 构造 GATT 管理器。
   * @param plugin - 宿主插件引用
   */
  constructor(plugin: FlutterBluePlusOhosPlugin) {
    this.plugin = plugin;
  }

  /**
   * 读取设备名（GAP service 0x1800 / Device Name 0x2A00）并回传 OnNameChanged。
   * @param remoteId - 设备 ID
   */
  async readDeviceName(remoteId: string): Promise<void> {
    try {
      let gattMaybe: ble.GattClientDevice | undefined = this.plugin.connectionManager.connectedDevices.get(remoteId);
      if (gattMaybe == null) {
        return;
      }
      let gatt: ble.GattClientDevice = gattMaybe;
      // 按设备串行执行 GATT 操作，避免与其它 GATT 操作并发冲突。
      await this.plugin.gattCache.runGatt(remoteId, async () => {
        let services: ble.GattService[] | undefined =
          this.plugin.gattCache.deviceServicesMap.get(remoteId);
        if (services == null) {
          services = await gatt.getServices();
          this.plugin.gattCache.deviceServicesMap.set(remoteId, services);
        }
        let gapService: ble.GattService | undefined;
        for (let service of services) {
          if (BleUtils.uuidStr(service.serviceUuid) == '1800') {
            gapService = service;
            break;
          }
        }
        if (gapService == null) {
          return;
        }
        let deviceNameChar: ble.BLECharacteristic | undefined;
        for (let characteristic of gapService.characteristics) {
          if (BleUtils.uuidStr(characteristic.characteristicUuid) == '2a00') {
            deviceNameChar = characteristic;
            break;
          }
        }
        if (deviceNameChar == null) {
          return;
        }
        let readCharacteristic: ble.BLECharacteristic = await gatt.readCharacteristicValue(deviceNameChar);
        let deviceName: string =
          BleUtils.utf8BytesToString(Array.from(new Uint8Array(readCharacteristic.characteristicValue)));
        let response: Map<string, string> = new Map();
        response.set('remote_id', remoteId);
        response.set('name', deviceName);
        this.plugin.channel?.invokeMethod('OnNameChanged', response);
      });
    } catch (e) {
      BleUtils.log(hilog.LogLevel.ERROR, `readDeviceName: Failed to read device name: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 处理 getPhySupport：返回设备 PHY 支持（LE 1M 默认支持，2M/Coded 暂报不支持）。
   * @param call - 方法调用
   * @param result - 结果回调
   */
  async getPhySupport(call: MethodCall, result: MethodResult): Promise<void> {
    try {
      // 平台限制：@ohos.bluetooth.ble 未提供运行时 PHY 能力查询 API
      // （无 isLe2mSupported 之类接口），
      // 故无法像 Android 那样查询系统实际支持的 PHY。此处按 BLE 5.0+ 基线返回 le_1m=true，
      // le_2m / le_coded 保守返回 false（不假设支持）。详见 README.OpenHarmony §4 平台限制表。
      let le1mSupported: boolean = true; // LE_1M is always supported in BLE 5.0+
      let le2mSupported: boolean = false; // OHOS 无查询 API，保守返回 false
      let leCodedSupported: boolean = false; // OHOS 无查询 API，保守返回 false
      let response: Map<string, boolean> = new Map();
      response.set('le_1m', le1mSupported);
      // key 必须用 'le_2M'（大写 M），
      // 与 Dart 端 PhySupport.fromMap 读取的 json['le_2M'] 大小写一致，
      // 否则 case-sensitive 查找会取不到值（当前因 le2m 恒为 false 而被巧合掩盖）。
      response.set('le_2M', le2mSupported);
      response.set('le_coded', leCodedSupported);
      result.success(response);
    } catch (e) {
      BleUtils.log(hilog.LogLevel.ERROR, `getPhySupport failed: ${(e as BusinessError).message}`);
      result.error('getPhySupport', (e as BusinessError).message, null);
    }
  }

  /**
   * 处理 clearGattCache：OHOS 无显式清缓存 API，设备在线时返回成功占位。
   * @param call - 方法调用，args 为 remoteId
   * @param result - 结果回调
   */
  async clearGattCache(call: MethodCall, result: MethodResult): Promise<void> {
    let remoteId: string = call.args as string;
    if (remoteId == null || remoteId == undefined || typeof remoteId !== 'string' || remoteId.length == 0) {
      result.error('clearGattCache', 'invalid remoteId', null);
      return;
    }
    let gatt: ble.GattClientDevice =
      this.plugin.connectionManager.connectedDevices.get(remoteId) as ble.GattClientDevice;
    if (gatt == null) {
      BleUtils.log(hilog.LogLevel.ERROR, 'clearGattCache failed: device is disconnected');
      result.error('clearGattCache', 'device is disconnected', null);
      return;
    }
    result.success(true);
  }

  /**
   * 处理 readRssi：读取已连接设备的 RSSI 值并通过 OnReadRssi 回传。
   * 错误码/消息从实际异常填充，避免 flag=false 与 errcode=0 矛盾。
   * @param call - 方法调用，args 为 remoteId
   * @param result - 结果回调
   */
  async readRssi(call: MethodCall, result: MethodResult): Promise<void> {
    let remoteId: string = call.args as string;
    if (remoteId == null || remoteId == undefined || typeof remoteId !== 'string' || remoteId.length == 0) {
      result.error('readRssi', 'invalid remoteId', null);
      return;
    }
    let gattMaybe: ble.GattClientDevice | undefined = this.plugin.connectionManager.connectedDevices.get(remoteId);
    if (gattMaybe == null || gattMaybe == undefined) {
      BleUtils.log(hilog.LogLevel.ERROR, 'readRssi failed for remoteId=' + remoteId + ': device is not connected');
      result.error('readRssi', 'device is disconnected', null);
      return;
    }
    let gatt: ble.GattClientDevice = gattMaybe;
    let readRssiFlag = true;
    let rssiValue: number = 0;
    let errorCode: number = 0;
    let errMsg: string = 'GATT_SUCCESS';
    // 按设备串行执行 GATT 操作，避免与其它 GATT 操作并发冲突。
    try {
      await this.plugin.gattCache.runGatt(remoteId, async () => {
        rssiValue = await gatt.getRssiValue();
      });
    } catch (e) {
      let error = e as BusinessError;
      readRssiFlag = false;
      errorCode = error?.code ?? 0;
      errMsg = error?.message ?? 'unknown error';
    }
    // RSSI=0 是合法读数（设备贴近时常见强信号），
    // 不可当失败；getRssiValue 失败会抛异常被上方 catch，不会返回 0。
    if (rssiValue == null || rssiValue == undefined) {
      BleUtils.log(hilog.LogLevel.ERROR,
        'readRssi failed for remoteId=' + remoteId + ': gatt.getRssiValue() returned invalid value');
      result.error('readRssi', 'gatt.readRemoteRssi() returned false', null);
      return;
    }
    result.success(true);
    let response: Map<string, string | number> = new Map();
    response.set('remote_id', remoteId);
    response.set('rssi', rssiValue);
    response.set('success', readRssiFlag ? 1 : 0);
    response.set('error_code', errorCode);
    response.set('error_string', errMsg);
    this.plugin.channel?.invokeMethod('OnReadRssi', response);
  }

  /**
   * 处理 discoverServices：发现已连接设备的 GATT 服务并回传 OnDiscoveredServices。
   * @param call - 方法调用，args 为 remoteId
   * @param result - 结果回调
   */
  async discoverServices(call: MethodCall, result: MethodResult): Promise<void> {
    let remoteId: string = call.args as string;
    if (remoteId == null || remoteId == undefined || typeof remoteId !== 'string' || remoteId.length == 0) {
      result.error('discoverServices', 'invalid remoteId', null);
      return;
    }
    let gattMaybe: ble.GattClientDevice | undefined = this.plugin.connectionManager.connectedDevices.get(remoteId);
    if (gattMaybe == null) {
      BleUtils.log(hilog.LogLevel.ERROR,
        'discoverServices failed for remoteId=' + remoteId + ': device is not connected');
      result.error('discoverServices', 'device is disconnected', null);
      return;
    }
    let gatt: ble.GattClientDevice = gattMaybe;
    // 按设备串行执行 GATT 操作，避免 OHOS BLE 栈 2900011 "operation is busy" 错误。
    // discoverServices 必须加锁：它调 gatt.getServices()，且完成后 Flutter 端会自动
    // 触发 setNotifyValue（如 1801/2a05 Service Changed），如果 discoverServices 还没完成，
    // setNotifyValue 就会与它冲突。
    await this.plugin.gattCache.runGatt(remoteId, async () => {
      let services: ble.GattService[];
      try {
        services = await gatt.getServices();
      } catch (e) {
        let error = e as BusinessError;
        BleUtils.log(hilog.LogLevel.ERROR,
          `discoverServices failed for remoteId=${remoteId}: gatt.getServices() threw, ` +
            `code=${error?.code}, msg=${error?.message}`);
        result.error('discoverServices', `gatt.getServices() failed: ${error?.message ?? 'unknown error'}`, null);
        return;
      }
      if (services == null || services.length == 0) {
        BleUtils.log(hilog.LogLevel.ERROR,
          'discoverServices failed for remoteId=' + remoteId + ': getServices() returned empty or null');
        result.error('discoverServices', 'gatt.discoverServices() returned false', null);
        return;
      }
      // 缓存发现的服务，后续 read/write/notify 可直接使用，避免重复调 getServices()
      this.plugin.gattCache.deviceServicesMap.set(remoteId, services);
      this.onDiscoveredServices(services, remoteId);
      result.success(true);
    });
  }

  /**
   * 服务发现完成后回传 OnDiscoveredServices（含 BmBluetoothService 树）。
   * @param gattServices - 已发现的 GATT 服务数组
   * @param remoteId - 设备 ID
   */
  onDiscoveredServices(gattServices: ble.GattService[], remoteId: string): void {
    let services: List<object> = new List<object>();
    gattServices.forEach(s => {
      services.add(BleGattShared.bmBluetoothService(s, null, remoteId, gattServices));
      s.includeServices?.forEach(s2 => {
        services.add(BleGattShared.bmBluetoothService(s2, s, remoteId, gattServices));
      });
    });
    let response: Map<string, object | string | number> = new Map();
    response.set('remote_id', remoteId as string);
    response.set('services', services);
    response.set('success', 1);
    response.set('error_code', 0);
    response.set('error_string', 'GATT_SUCCESS');
    this.plugin.channel?.invokeMethod('OnDiscoveredServices', response);
  }
}
