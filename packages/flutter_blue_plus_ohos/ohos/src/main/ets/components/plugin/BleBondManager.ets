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
import { List } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import BleUtils from './BleUtils';
import FlutterBluePlusOhosPlugin from './FlutterBluePlusOhosPlugin';

/**
 * 蓝牙配对（Bond）管理器。
 *
 * 从 BleConnectionManager 剥离的配对状态与方法：持有 bondingDevices（BONDING 态创建的
 * GattClientDevice，用于 close）、bondStateChangeCallback，
 * 以及 createBond / removeBond / getBondState / getBondedDevices 四个 method handler。
 *
 * 跨 Manager 访问：
 *  - createBond 需读取已连接设备 GattClientDevice，经 plugin.connectionManager.connectedDevices 反向查询
 *    （与 BleGattManager 访问 connectedDevices 的方式一致）。
 *  - bondingDevices 内的 GattClientDevice 生命周期跨越连接断开事件，连接侧断开/清理时须调用
 *    {@link clearBondingState} 释放该设备的配对态资源
 *    （见调用方 disconnect/handleDisconnected/cleanup）。
 * 箭头函数回调保持成员属性形式，保证 ble/connection.on/off 传引用时 this 不丢失。
 */
export default class BleBondManager {
  /** 插件引用，用于访问 connectionManager.connectedDevices、channel。 */
  private plugin: FlutterBluePlusOhosPlugin;

  /** 配对中的设备（BONDING 态创建的 GattClient，用于 close）。 */
  public bondingDevices: Map<string, ble.GattClientDevice> = new Map();

  /**
   * 构造配对管理器。
   * @param plugin - 宿主插件引用
   */
  constructor(plugin: FlutterBluePlusOhosPlugin) {
    this.plugin = plugin;
  }

  /**
   * bondStateChange 回调，成员属性箭头函数，便于 on/off 精确传引用。
   *
   * BONDING 态创建 GattClientDevice 存入 bondingDevices（供后续配对相关操作及 close）；
   * 其他态 close 并移除（若仍存在）。配对状态变化回传 OnBondStateChanged。
   */
  public bondStateChangeCallback: (data: connection.BondStateParam) => void =
    (data: connection.BondStateParam) => {
      try {
        if (this.plugin.isDetached) {
          return;
        }
        if (data.state == connection.BondState.BOND_STATE_BONDING) {
          // BONDING 态：创建并缓存 GattClientDevice，其生命周期须跨越整个配对过程，
          // 以便进入 BONDED/INVALID 等态时显式 close 释放原生 BLE 资源
          // （按 deviceId 索引，支持多设备并发配对）。
          if (!this.bondingDevices.has(data.deviceId)) {
            let gatt: ble.GattClientDevice = ble.createGattClientDevice(data.deviceId);
            this.bondingDevices.set(data.deviceId, gatt);
          }
        } else {
          // 非 BONDING 态（BONDED/INVALID 等）：取出并关闭 BONDING 态缓存的 GattClientDevice，
          // 释放其占用的原生 BLE 资源后再从 map 移除
          // （close 失败仅记日志，仍保证 delete 执行，避免残留）。
          let gatt: ble.GattClientDevice | undefined = this.bondingDevices.get(data.deviceId);
          if (gatt != null) {
            try {
              gatt.close();
            } catch (e) {
              BleUtils.log(hilog.LogLevel.WARN,
                `bondStateChange: failed to close gatt for ${data.deviceId}: ${JSON.stringify(e)}`);
            }
          }
          this.bondingDevices.delete(data.deviceId);
        }
        let map: Map<string, string | number | null> = new Map();
        map.set('remote_id', data.deviceId);
        map.set('bond_state', BleUtils.bmBondStateEnum(data.state));
        // OHOS BondStateParam 回调仅含当前 state，不提供前一状态，prev_state 恒为 null
        // （平台限制）。
        map.set('prev_state', null);
        this.plugin.channel?.invokeMethod('OnBondStateChanged', map);
      } catch (e) {
        // 顶层兜底：系统 BLE 事件回调内异常必须被吞掉，否则可能中断后续回调触发，
        // 导致 Flutter 端停留在过时配对状态。
        BleUtils.log(hilog.LogLevel.ERROR,
          `bondStateChangeCallback: unhandled error for ${data?.deviceId}: ${JSON.stringify(e)}`);
      }
    };

  /**
   * 设备断开/清理时调用：关闭并移除该设备在 BONDING 态创建的 GattClientDevice，
   * 清空其 PIN 缓存，避免原生 BLE 资源泄漏。幂等。
   *
   * 连接侧（BleConnectionManager.disconnect / handleDisconnected / disconnectAllDevices / cleanup）
   * 必须在断开该设备时调用此方法，以闭环释放 bondingDevices 中的资源。
   * @param deviceId - 设备 ID
   */
  clearBondingState(deviceId: string): void {
    let bondingGatt: ble.GattClientDevice | undefined = this.bondingDevices.get(deviceId);
    if (bondingGatt != null) {
      try {
        bondingGatt.close();
      } catch (e) {
        BleUtils.log(hilog.LogLevel.WARN,
          `clearBondingState: close failed for ${deviceId}: ${JSON.stringify(e)}`);
      }
    }
    this.bondingDevices.delete(deviceId);
  }

  /**
   * 清空所有配对态资源。cleanup 全局清理时调用。
   */
  clearAll(): void {
    this.bondingDevices.forEach((gatt: ble.GattClientDevice) => {
      try {
        gatt.close();
      } catch (e) {
        BleUtils.log(hilog.LogLevel.WARN, `clearAll: close gatt failed: ${JSON.stringify(e)}`);
      }
    });
    this.bondingDevices.clear();
  }

  /**
   * 处理 getBondedDevices：返回系统已配对设备列表（含设备名）。
   * 不访问任何连接状态字段，仅依赖 connection.getPairedDevices + 局部 gatt + BleUtils。
   * @param call - 方法调用
   * @param result - 结果回调
   */
  async getBondedDevices(call: MethodCall, result: MethodResult): Promise<void> {
    let devices: string[] = connection.getPairedDevices();
    let deviceList: List<Map<string, object | string>> = new List();
    for (let device of devices) {
      let gatt: ble.GattClientDevice | null = null;
      try {
        gatt = ble.createGattClientDevice(device);
        let name: string = await gatt.getDeviceName();
        deviceList.add(BleUtils.bmBluetoothDevice(device, name));
      } catch (e) {
        let error = e as BusinessError;
        BleUtils.log(hilog.LogLevel.ERROR,
          `getBondedDevices: failed to read name for ${device}, code=${error?.code}, msg=${error?.message}`);
        deviceList.add(BleUtils.bmBluetoothDevice(device, ''));
      } finally {
        if (gatt != null) {
          try {
            gatt.close();
          } catch (closeErr) {
            BleUtils.log(hilog.LogLevel.WARN,
              `getBondedDevices: close failed for ${device}: ${JSON.stringify(closeErr)}`);
          }
        }
      }
    }
    let response: Map<string, object | string> = new Map<string, object | string>();
    response.set('devices', deviceList);
    result.success(response);
  }

  /**
   * 处理 getBondState：返回指定设备的配对状态。不访问连接状态字段。
   *
   * 平台限制：OHOS connection.getPairState 仅返回当前配对状态，不提供前一状态，
   * 故 prev_state 恒为 null（无法像 Android/iOS 那样返回 prevBondState）。详见 README.OpenHarmony §4。
   * @param call - 方法调用，args 为 remoteId
   * @param result - 结果回调
   */
  async getBondState(call: MethodCall, result: MethodResult): Promise<void> {
    let remoteId: string = call.args as string;
    // 参数校验：remoteId 必须为非空字符串，避免非法参数导致 getPairState 抛异常。
    if (remoteId == null || remoteId == undefined || typeof remoteId !== 'string' || remoteId.length == 0) {
      BleUtils.log(hilog.LogLevel.ERROR, 'getBondState failed: invalid remoteId');
      result.error('getBondState', 'invalid remoteId', null);
      return;
    }
    let res: connection.BondState = connection.getPairState(remoteId);
    let response: Map<string, string | number | null> = new Map();
    response.set('remote_id', remoteId);
    response.set('bond_state', BleUtils.bmBondStateEnum(res));
    // OHOS 仅提供当前状态，无前一状态字段，prev_state 恒为 null（平台限制）。
    response.set('prev_state', null);
    result.success(response);
  }

  /**
   * 处理 createBond：对已连接设备发起配对，已配对/配对中则直接返回。
   *
   * 需读取已连接设备 GattClientDevice 发起配对，经 plugin.connectionManager.connectedDevices 反向查询
   * （跨 Manager 唯一锚点）。createBond() 异常返回，保持原行为。
   * @param call - 方法调用，args 含 remote_id/pin
   * @param result - 结果回调
   */
  async createBond(call: MethodCall, result: MethodResult): Promise<void> {
    let data: Map<string, object | string | Uint8Array> = call.args;
    let remoteId: string = data.get('remote_id') as string;
    if (remoteId == null || remoteId == undefined || typeof remoteId !== 'string' || remoteId.length == 0) {
      // 参数校验：remoteId 必须为非空字符串，
      // 避免后续 connectedDevices.get(undefined) 误判为已断开。
      BleUtils.log(hilog.LogLevel.ERROR, 'createBond failed: invalid remote_id');
      result.error('createBond', 'invalid remote_id', null);
      return;
    }
    // OHOS pairDevice 不接受外部 PIN（系统级配对弹窗处理），故 pin 参数在此忽略。
    let gatt: ble.GattClientDevice =
      this.plugin.connectionManager.connectedDevices.get(remoteId) as ble.GattClientDevice;
    if (gatt == null) {
      BleUtils.log(hilog.LogLevel.ERROR, 'createBond failed: device is disconnected');
      result.error('createBond', 'device is disconnected', null);
      return;
    }
    let res: connection.BondState = connection.getPairState(remoteId);
    // 已配对，无需重复发起。
    if (res == connection.BondState.BOND_STATE_BONDED) {
      result.success(false);
      return;
    }
    // 配对进行中，复用当前流程。
    if (res == connection.BondState.BOND_STATE_BONDING) {
      result.success(true);
      return;
    }
    try {
      connection.pairDevice(remoteId);
    } catch (e) {
      BleUtils.log(hilog.LogLevel.ERROR,
        `createBond failed: device.createBond() returned false, error=${JSON.stringify(e)}`);
      result.error('createBond', 'device.createBond() returned false', null);
      return;
    }
    result.success(true);
  }

  /**
   * 处理 removeBond：取消设备配对（解绑）。
   *
   * 平台限制：OHOS SDK 未开放代码取消蓝牙配对的能力——@ohos.bluetooth.connection 仅提供
   * pairDevice / getPairState / getPairedDevices，没有 unpair / cancel 等接口，
   * 应用无法通过代码解绑设备。
   *
   * 处理方式：与 iOS（返回 "android only"）保持一致的「明确告知不支持」语义，
   * 通过 result.error
   * 返回而非静默成功，避免上层误认为解绑已执行。
   * @param call - 方法调用，args 为 remoteId
   * @param result - 结果回调
   */
  async removeBond(call: MethodCall, result: MethodResult): Promise<void> {
    let remoteId: string = call.args as string;
    if (remoteId == null || remoteId == undefined || typeof remoteId !== 'string' || remoteId.length == 0) {
      result.error('removeBond', 'invalid remoteId', null);
      return;
    }
    // OHOS SDK 未提供取消配对接口，
    // 以 error 明确告知不支持（对齐 iOS 的「android only」语义）。
    BleUtils.log(hilog.LogLevel.WARN,
      `removeBond: not supported on OHOS (no unpair API in SDK), ${remoteId} not removed`);
    result.error('removeBond', 'removeBond is not supported on OHOS: the SDK exposes no unpair API.', null);
  }
}
