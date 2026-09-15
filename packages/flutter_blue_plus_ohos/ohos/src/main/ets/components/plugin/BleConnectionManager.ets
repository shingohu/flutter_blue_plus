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
import { ble, connection, constant } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import access from '@ohos.bluetooth.access';
import BleUtils from './BleUtils';
import TextUtils from './TextUtils';
import FlutterBluePlusOhosPlugin from './FlutterBluePlusOhosPlugin';

/**
 * 蓝牙连接管理器。
 *
 * 集中管理设备连接/断开/配对状态，持有 connectedDevices/currentlyConnectingDevices/
 * autoConnectedDevices 等连接状态，
 * 以及 bondStateChangeCallback/stateChangeCallback/connectStateChanged 回调
 * （成员属性箭头函数，保证 ble/connection.on/off 传引用时 this 不丢失）。
 * 跨 Manager 访问通过 plugin 中介（this.plugin.gattCache.mtuMap 等）。
 */
export default class BleConnectionManager {
  /** 插件引用，用于访问 isDetached/channel/gattManager。 */
  private plugin: FlutterBluePlusOhosPlugin;

  /** 已连接设备（remoteId -> GattClientDevice）。 */
  public connectedDevices: Map<string, ble.GattClientDevice> = new Map<string, ble.GattClientDevice>();
  /** 正在连接的设备。 */
  public currentlyConnectingDevices: Map<string, ble.GattClientDevice> = new Map();
  /** 自动重连设备集合。 */
  public autoConnectedDevices: Map<string, ble.GattClientDevice> = new Map();

  /** stateChange 回调，成员属性箭头函数，便于 handleFlutterRestart 注册前精确 off。 */
  public stateChangeCallback: (data: access.BluetoothState) => void =
    (data: access.BluetoothState) => {
      try {
        if (this.plugin.isDetached) {
          return;
        }
        this.onReceiveEvent(data);
      } catch (e) {
        // 顶层兜底：适配器状态变化回调异常必须吞掉，避免中断后续适配器状态事件。
        BleUtils.log(hilog.LogLevel.ERROR,
          `stateChangeCallback: unhandled error for state=${data}: ${JSON.stringify(e)}`);
      }
    };

  /**
   * 构造连接管理器。
   */
  constructor(plugin: FlutterBluePlusOhosPlugin) {
    this.plugin = plugin;
  }

  /**
   * ble.on('BLEConnectionStateChange') 回调：设备连接/断开状态变化。
   * 多设备并发场景必须用 state.deviceId（不能用单实例字段 remoteId）。
   * 保持成员属性箭头函数形式，ble.on/off 传引用时 this 不丢失。
   */
  public connectStateChanged = (state: ble.BLEConnectionChangeState) => {
    try {
      if (this.plugin.isDetached) {
        return;
      }
      if (state.state != constant.ProfileConnectionState.STATE_CONNECTED &&
        state.state != constant.ProfileConnectionState.STATE_DISCONNECTED) {
        return;
      }
      // 多设备并发场景: 必须用回调参数 state.deviceId, 不能用单实例字段 this.remoteId,
      // 否则 Device A 的回调会用被 Device B 覆盖后的 remoteId, 导致状态串台。
      let deviceId: string = state.deviceId as string;
      let gatt: ble.GattClientDevice | undefined =
        this.currentlyConnectingDevices.get(deviceId) ?? this.connectedDevices.get(deviceId);
      // 记录状态变化前该设备是否处于 connecting 态（须在 handle* 删除 Map 条目之前取值）。
      // 用于区分「连接中即断开 = 连接失败」与「已连接后自发断连」两种场景，
      // 进而决定 disconnect_reason_code/string（emitConnectionState）。
      let wasConnecting: boolean = this.currentlyConnectingDevices.has(deviceId);
      if (state.state == constant.ProfileConnectionState.STATE_CONNECTED) {
        this.handleConnected(deviceId, gatt);
      } else {
        this.handleDisconnected(deviceId, gatt);
      }
      this.emitConnectionState(deviceId, state.state, wasConnecting);
    } catch (e) {
      // 顶层兜底：连接状态变化回调异常必须吞掉，避免中断后续连接事件、
      // 导致 Flutter 端停留在 connecting 等过时状态。
      BleUtils.log(hilog.LogLevel.ERROR,
        `connectStateChanged: unhandled error for ${state?.deviceId}: ${JSON.stringify(e)}`);
    }
  };

  /**
   * 注销某设备的 per-device 监听（连接状态/特征变化/MTU 回调）。
   * disconnect/handleDisconnected/resolveDisconnectGatt 三处复用，保证清理路径一致。
   */
  private unregisterDeviceListeners(remoteId: string, gatt: ble.GattClientDevice): void {
    gatt.off('BLEConnectionStateChange', this.connectStateChanged);
    this.plugin.mtuManager.unregisterMtuCallback(remoteId, gatt);
    this.plugin.notifyManager.unregisterCharacteristicChangeCallback(remoteId, gatt);
  }

  /**
   * 连接成功处理：登记已连接设备、初始化 MTU、按设备注册 MTU 与通知回调、
   * 读取设备名。
   */
  private handleConnected(deviceId: string, gatt: ble.GattClientDevice | undefined): void {
    if (gatt != null) {
      this.connectedDevices.set(deviceId, gatt as ble.GattClientDevice);
    }
    this.currentlyConnectingDevices.delete(deviceId);
    this.plugin.gattCache.mtuMap.set(deviceId, 23);
    if (gatt != null) {
      // 按设备注册绑定 deviceId 的 MTU 回调闭包，避免多设备并发时 MTU 数据串台。
      this.plugin.mtuManager.registerMtuCallback(deviceId, gatt);
      // 按设备注册绑定 deviceId 的通知回调闭包
      // （对齐 Android：连接即注册，不依赖 read/notify），
      // 修 S5（只订阅不读也能收通知）与 S3（多设备相同 UUID 不串台）。
      this.plugin.notifyManager.registerCharacteristicChangeCallback(deviceId, gatt);
    }
    this.plugin.gattManager.readDeviceName(deviceId);
  }

  /**
   * 断开处理：注销监听、清理连接/配对状态、关闭 GattClientDevice（非自动重连设备）。
   * @param gatt - 该设备的 GattClientDevice（可能为 null）
   */
  private handleDisconnected(deviceId: string, gatt: ble.GattClientDevice | undefined): void {
    if (gatt != null) {
      this.unregisterDeviceListeners(deviceId, gatt);
    }
    this.connectedDevices.delete(deviceId);
    this.currentlyConnectingDevices.delete(deviceId);
    // 配对期间创建的 GattClientDevice 需在此 close
    // （配对态已迁移至 BleBondManager，由其负责清理），
    // 否则 BONDING 态断连时仅删 Map 条目会导致原生 BLE 资源泄漏。
    this.plugin.bondManager.clearBondingState(deviceId);
    // 断连设备的 MTU/服务缓存随设备失效，清理避免残留（含 deviceServicesMap）。
    this.plugin.gattCache.clearForDevice(deviceId);
    if (!this.autoConnectedDevices.has(deviceId) && gatt != null) {
      gatt.close();
    }
  }

  /**
   * 回传 OnConnectionStateChanged 到 Flutter 端。
   *
   * 平台限制：鸿蒙 BLEConnectionChangeState 回调仅含 deviceId / state，
   * 不含 cause（断开原因）字段，故无法像 Android 那样从 GATT 回调取真实 reason code。
   * 主动取消连接的场景由 emitDisconnectState 回传语义化值 23789258。
   * 详见 README.OpenHarmony §4 平台限制表。
   *
   * @param wasConnecting - 状态变化前设备是否处于 connecting 态。true 表示连接中即断开
   *   （连接失败，如拒绝配对/超时/远端拒绝），回传 code=1 + 'UNKNOWN_HCI_ERROR (1)'，
   *   false 表示已连接后自发断连，回传 code=0 + 'unknown'
   */
  private emitConnectionState(deviceId: string, state: number, wasConnecting: boolean): void {
    let response: Map<string, string | number> = new Map();
    response.set('remote_id', deviceId);
    response.set('connection_state', BleUtils.bmConnectionStateEnum(state));
    if (state != constant.ProfileConnectionState.STATE_CONNECTED) {
      if (wasConnecting) {
        // 连接中即断开 = 连接失败（拒绝配对/超时/远端拒绝）。
        // OHOS 回调无 cause 字段拿不到真实 HCI 原因码，回传 code=1 + 'UNKNOWN_HCI_ERROR (1)'
        response.set('disconnect_reason_code', 1);
        response.set('disconnect_reason_string', TextUtils.hciStatusString(1));
      } else {
        // 不能用 hciStatusString(0) → 'SUCCESS'，否则 Flutter 侧会显示
        // "Connect Error: SUCCESS" 这种语义矛盾的红色弹窗。
        // 对齐 emitDisconnectState 的做法：0 + 语义化描述。
        response.set('disconnect_reason_code', 0);
        response.set('disconnect_reason_string', 'unknown');
      }
    }
    this.plugin.channel?.invokeMethod('OnConnectionStateChanged', response);
  }

  /**
   * 处理 flutterRestart：应用热重启时停止扫描、注册状态监听并断开所有设备。
   */
  async flutterRestart(result: MethodResult): Promise<void> {
    result.success(this.connectedDevices.size);
    try {
      BleUtils.log(hilog.LogLevel.DEBUG, 'flutterRestart: calling stopScan');
      ble.stopBLEScan();
    } catch (e) {
      BleUtils.log(hilog.LogLevel.ERROR, 'flutterRestart: Failed to stop scan: ' + JSON.stringify(e));
    }
    // 先精确 off 旧监听再 on, 避免热重启累积匿名 lambda 导致回调多次执行。
    try {
      access.off('stateChange', this.stateChangeCallback);
    } catch (e) {
      BleUtils.log(hilog.LogLevel.WARN, `flutterRestart: off stateChange failed: ${JSON.stringify(e)}`);
    }
    access.on('stateChange', this.stateChangeCallback);
    this.disconnectAllDevices('flutterRestart');
  }

  /**
   * 处理 connectedCount：返回当前已连接设备数量。
   */
  async connectedCount(result: MethodResult): Promise<void> {
    BleUtils.log(hilog.LogLevel.DEBUG, 'connectedPeripherals count: ' + this.connectedDevices.size);
    if (this.connectedDevices.size == 0) {
      BleUtils.log(hilog.LogLevel.DEBUG, 'connectedPeripherals: Hot Restart complete, no devices connected');
    }
    result.success(this.connectedDevices.size);
  }

  /**
   * 处理 connect：创建 GATT 客户端并连接指定远程设备。
   * connect() 异常必须提前返回，
   * 避免未成功连接的 clientDevice 被误加入 currentlyConnectingDevices。
   */
  async connect(call: MethodCall, result: MethodResult): Promise<void> {
    let args: Map<string, string | boolean | number> = call.args;
    let remoteId: string = args?.get('remote_id') as string;
    if (!remoteId) {
      BleUtils.log(hilog.LogLevel.ERROR, 'connect failed: remote_id is null or empty');
      result.error('connect', 'remote_id is required', null);
      return;
    }
    // Dart 端 autoConnect 以 int(0/1) 发送（bluetooth_msgs.dart BmConnectRequest.toMap: autoConnect ? 1 : 0），
    // 显式 number→boolean 转换更类型安全，与 Android 实现一致
    // （原 as boolean 靠"1 为真"侥幸工作）。
    let autoConnect: boolean = ((args?.get('auto_connect') as number) ?? 0) != 0;
    if (!await this.plugin.permissionManager.ensurePermissions(result, 'connect')) {
      return;
    }
    if (!BleUtils.isAdapterOn()) {
      BleUtils.log(hilog.LogLevel.ERROR,
        'connect failed for remoteId=' + remoteId + ': bluetooth adapter is turned off');
      result.error('connect', 'bluetooth must be turned on', null);
      return;
    }
    // 重复连接守卫：已在连接流程中则直接返回，避免重复 createGattClientDevice。
    // 使用局部变量 remoteId 而非单实例字段 this.remoteId，
    // 避免多设备并发 connect 时互相覆盖。
    // success(true)=正在连接（Flutter 端继续等 connecting→connected），
    // success(false)=已连接（流程已完成）。
    if (this.currentlyConnectingDevices.get(remoteId) != null) {
      BleUtils.log(hilog.LogLevel.DEBUG, 'connect: already connecting to ' + remoteId);
      result.success(true);
      return;
    }
    if (this.connectedDevices.get(remoteId) != null) {
      BleUtils.log(hilog.LogLevel.DEBUG, 'connect: already connected to ' + remoteId);
      result.success(false);
      return;
    }
    let clientDevice: ble.GattClientDevice | null = this.createAndConnectDevice(remoteId, result);
    if (clientDevice == null) {
      return;
    }
    this.currentlyConnectingDevices.set(remoteId, clientDevice);
    if (autoConnect) {
      this.autoConnectedDevices.set(remoteId, clientDevice);
    } else {
      this.autoConnectedDevices.delete(remoteId);
    }
    result.success(true);
  }

  /**
   * 创建 GATT 客户端并连接（createGattClientDevice + connect + 注册回调）。
   * 创建/连接异常或返回 null 时通过 result 回传错误并返回 null。
   */
  private createAndConnectDevice(remoteId: string, result: MethodResult): ble.GattClientDevice | null {
    let clientDevice: ble.GattClientDevice | null = null;
    try {
      clientDevice = ble.createGattClientDevice(remoteId);
      clientDevice.connect();
      clientDevice.on('BLEConnectionStateChange', this.connectStateChanged);
    } catch (err) {
      BleUtils.log(hilog.LogLevel.ERROR,
        `connect: failed for remoteId=${remoteId}, errCode=${err?.code}, errMsg=${err?.message}`);
      // 修复资源泄漏：createGattClientDevice 成功但 connect/on 失败时，已创建的 GattClientDevice
      // 必须显式 close，否则每次连接失败都泄漏一个原生 BLE 客户端，
      // 累积可耗尽系统 BLE 连接数上限。
      if (clientDevice != null) {
        try {
          clientDevice.close();
        } catch (closeErr) {
          BleUtils.log(hilog.LogLevel.WARN,
            `connect: close failed for remoteId=${remoteId}: ${JSON.stringify(closeErr)}`);
        }
        clientDevice = null;
      }
      result.error('connect', `connection failed: ${err?.message ?? 'unknown'}`, null);
      return null;
    }
    if (clientDevice == null) {
      BleUtils.log(hilog.LogLevel.ERROR,
        `connect failed for remoteId=${remoteId}: ble.createGattClientDevice() returned null, ` +
        `check if bluetooth adapter is on`);
      result.error('connect', 'getBluetoothLeScanner() is null. Is the Adapter on?', null);
      return null;
    }
    return clientDevice;
  }

  /**
   * 处理 disconnect：断开/取消连接，清理监听并通过 OnConnectionStateChanged 回传。
   */
  async disconnect(call: MethodCall, result: MethodResult): Promise<void> {
    let remoteId: string = call.args as string;
    // 参数校验：remoteId 必须为非空字符串，避免 undefined 误判为已断开。
    if (remoteId == null || remoteId == undefined || typeof remoteId !== 'string' || remoteId.length == 0) {
      result.error('disconnect', 'invalid remoteId', null);
      return;
    }
    try {
      let gatt: ble.GattClientDevice | null = this.resolveDisconnectGatt(remoteId, result);
      if (gatt == null) {
        // resolveDisconnectGatt 已通过 result 回传（false 或错误），或已返回 null 表示无需处理
        return;
      }
      this.autoConnectedDevices.delete(remoteId);
      // remove event listeners first
      this.unregisterDeviceListeners(remoteId, gatt);
      // disconnect
      gatt.disconnect();
      // 连接中 → 视为取消；已连接 → 正常断开。统一回传 OnConnectionStateChanged。
      let wasConnecting: boolean = this.currentlyConnectingDevices.has(remoteId);
      if (wasConnecting) {
        this.currentlyConnectingDevices.delete(remoteId);
      } else {
        this.connectedDevices.delete(remoteId);
      }
      gatt.close();
      this.emitDisconnectState(remoteId, wasConnecting);
      this.plugin.gattCache.clearForDevice(remoteId);
      // 关闭配对期间可能创建的 GattClientDevice
      // （配对态已迁移至 BleBondManager，由其负责清理）。
      this.plugin.bondManager.clearBondingState(remoteId);
      result.success(true);
    } catch (e) {
      let error = e as BusinessError;
      BleUtils.log(hilog.LogLevel.ERROR,
        'disconnect failed for remoteId=' + remoteId + ': error=' + JSON.stringify(error));
      result.error('disconnect', error.message, null);
    }
  }

  /**
   * disconnect 时回传 OnConnectionStateChanged。
   * @param wasConnecting - true 表示原处于 connecting（回传 23789258「连接取消」）；
   * false 表示已连接（回传 0「正常断开」）
   */
  private emitDisconnectState(remoteId: string, wasConnecting: boolean): void {
    let response: Map<string, string | number> = new Map<string, string | number>();
    response.set('remote_id', remoteId);
    response.set('connection_state',
      BleUtils.bmConnectionStateEnum(constant.ProfileConnectionState.STATE_DISCONNECTED));
    response.set('disconnect_reason_code', wasConnecting ? 23789258 : 0);
    response.set('disconnect_reason_string', wasConnecting ? 'connection canceled' : 'disconnected normally');
    this.plugin.channel?.invokeMethod('OnConnectionStateChanged', response);
  }

  /**
   * 解析 disconnect 时应释放的 GattClientDevice：优先 connecting，其次 connected，
   * 最后 autoConnected（已断开仅清 autoconnect 并回传 false）。null 表示已处理或无设备。
   */
  private resolveDisconnectGatt(remoteId: string,
    result: MethodResult): ble.GattClientDevice | null {
    let gatt: ble.GattClientDevice | null = null;
    // 第一级：正在连接中 → 取出交由外层走「取消连接」流程。
    gatt = this.currentlyConnectingDevices.get(remoteId) as ble.GattClientDevice;
    if (gatt != null) {
      BleUtils.log(hilog.LogLevel.DEBUG, 'disconnect: cancelling connection in progress for ' + remoteId);
      return gatt;
    }
    // 第二级：已连接 → 取出交由外层走「正常断开」流程。
    gatt = this.connectedDevices.get(remoteId) as ble.GattClientDevice;
    if (gatt != null) {
      return gatt;
    }
    // 第三级：仅剩自动重连记录 → 设备实际已断开，
    // 关闭残留 GattClientDevice、清除自动重连标记后回传 false。
    gatt = this.autoConnectedDevices.get(remoteId) as ble.GattClientDevice;
    if (gatt != null) {
      BleUtils.log(hilog.LogLevel.DEBUG,
        'disconnect: already disconnected, disabling autoconnect for ' + remoteId);
      this.autoConnectedDevices.delete(remoteId);
      this.unregisterDeviceListeners(remoteId, gatt);
      gatt.disconnect();
      gatt.close();
      this.plugin.gattCache.clearForDevice(remoteId);
      this.plugin.bondManager.clearBondingState(remoteId);
      result.success(false);
      return null;
    }
    BleUtils.log(hilog.LogLevel.DEBUG, 'disconnect: already disconnected for ' + remoteId);
    result.success(false);
    return null;
  }

  /**
   * 断开所有设备：adapterTurnOff 直接清理 Map 并回传状态；
   * flutterRestart 走正常 disconnect()/close()。
   * 注意必须用循环变量 key 而非 this.remoteId；clear 移到循环外。
   */
  disconnectAllDevices(func: string): void {
    // merge connected & autoconnected
    let allDevices: Map<string, ble.GattClientDevice> = new Map();
    this.connectedDevices.forEach((value, key) => {
      allDevices.set(key, value);
    });
    this.autoConnectedDevices.forEach((value, key) => {
      allDevices.set(key, value);
    });
    // adapterTurnOff：适配器关闭时设备不会触发正常断开回调，
    // 须在此手动删 Map 并回传状态；
    // flutterRestart：走正常 disconnect()/close()，让 BLE 协议栈照常派发断开事件。
    allDevices.forEach((value, key) => {
      if (func == 'adapterTurnOff') {
        // state 恒为 DISCONNECTED：必须用循环变量 key 而非 this.remoteId,
        // 否则只删最后一个连接设备条目。
        let state: number = constant.ProfileConnectionState.STATE_DISCONNECTED;
        this.connectedDevices.delete(key);
        this.currentlyConnectingDevices.delete(key);
        // 关闭配对期间创建的 GattClientDevice（若存在），
        // 避免原生资源泄漏（配对态已迁移至 BleBondManager）。
        this.plugin.bondManager.clearBondingState(key);
        if (!this.autoConnectedDevices.has(key)) {
          value.close();
        }
        let response: Map<string, string | number> = new Map();
        response.set('remote_id', key);
        response.set('connection_state', BleUtils.bmConnectionStateEnum(state));
        response.set('disconnect_reason_code', 0);
        // 同 emitConnectionState：0 在断连场景非真实 HCI SUCCESS，赋语义化 'unknown'
        // 避免 Flutter 侧 "Connect Error: SUCCESS" 的语义矛盾。
        response.set('disconnect_reason_string', 'unknown');
        this.plugin.channel?.invokeMethod('OnConnectionStateChanged', response);
      } else {
        // flutterRestart：对齐 cleanup，逐设备 off 三类 per-device 监听后再 disconnect/close，
        // 避免旧回调引用残留（connectStateChanged/MTU/通知回调在 gatt.close 后仍被触发）。
        this.releaseGattDevice(value, key);
      }
    });
    // clear 操作移到循环外, 避免每次迭代都清空所有 Map(只在循环结束后统一清理一次)。
    this.connectedDevices.clear();
    this.currentlyConnectingDevices.clear();
    this.plugin.bondManager.clearAll();
    this.plugin.gattCache.clearAll();
    // 同步清空 MTU/通知回调映射（与 cleanup 一致），避免热重启后旧闭包引用残留。
    this.plugin.mtuManager.clearAll();
    this.plugin.notifyManager.clearAll();
    this.autoConnectedDevices.clear();
  }

  /**
   * 适配器状态变化处理：回传 OnAdapterStateChanged，
   * 并在 BLE_TURNING_OFF/STATE_OFF 时断开所有设备。
   */
  onReceiveEvent(data: access.BluetoothState): void {
    if (BleUtils.isAdapterOn()) {
      let map: Map<string, boolean> = new Map();
      map.set('user_accepted', true);
      this.plugin.channel?.invokeMethod('OnTurnOnResponse', map);
    }
    let map: Map<string, object | number> = new Map();
    map.set('adapter_state', BleUtils.bmAdapterStateEnum(data));
    this.plugin.channel?.invokeMethod('OnAdapterStateChanged', map);
    if (data == access.BluetoothState.STATE_BLE_TURNING_OFF ||
      data == access.BluetoothState.STATE_OFF) {
      this.disconnectAllDevices('adapterTurnOff');
    }
  }

  /**
   * 释放单个 GattClientDevice：off 监听 -> unregisterMtuCallback -> disconnect -> close，
   * 各步骤独立 try-catch。
   */
  private releaseGattDevice(gatt: ble.GattClientDevice, key: string): void {
    this.safeCleanupOp(() => gatt.off('BLEConnectionStateChange', this.connectStateChanged),
      'off BLEConnectionStateChange', key);
    this.safeCleanupOp(() => this.plugin.mtuManager.unregisterMtuCallback(key, gatt),
      'unregisterMtuCallback', key);
    this.safeCleanupOp(() => this.plugin.notifyManager.unregisterCharacteristicChangeCallback(key, gatt),
      'unregister BLECharacteristicChange', key);
    this.safeCleanupOp(() => gatt.disconnect(), 'disconnect', key);
    this.safeCleanupOp(() => gatt.close(), 'close', key);
  }

  /**
   * 执行一个释放步骤，异常仅记 WARN 日志（含设备 key），
   * 不向外抛，保证 cleanup 各步骤互不阻断。
   */
  private safeCleanupOp(op: () => void, label: string, key: string): void {
    try {
      op();
    } catch (e) {
      BleUtils.log(hilog.LogLevel.WARN, `cleanup: ${label} failed for ${key}: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 统一资源清理：停扫描、断开并关闭所有 GattClientDevice、
   * off 所有 per-device 监听、clear 所有 Map。
   * 幂等，可被 onDetachedFromEngine 调用。
   */
  cleanup(): void {
    BleUtils.log(hilog.LogLevel.INFO, 'cleanup: releasing all BLE resources');
    // 1) 停扫描
    try {
      ble.stopBLEScan();
    } catch (e) {
      BleUtils.log(hilog.LogLevel.WARN, `cleanup: stopBLEScan failed: ${JSON.stringify(e)}`);
    }
    try {
      ble.off('BLEDeviceFind', this.plugin.scanManager.onScanResult);
    } catch (e) {
      BleUtils.log(hilog.LogLevel.WARN, `cleanup: off BLEDeviceFind failed: ${JSON.stringify(e)}`);
    }
    // 2) 汇总所有需要释放的 GattClientDevice（按 remoteId 去重，含配对态设备）
    let allDevices: Map<string, ble.GattClientDevice> = new Map<string, ble.GattClientDevice>();
    this.connectedDevices.forEach((v, k) => { allDevices.set(k, v); });
    this.currentlyConnectingDevices.forEach((v, k) => { allDevices.set(k, v); });
    this.autoConnectedDevices.forEach((v, k) => { allDevices.set(k, v); });
    this.plugin.bondManager.bondingDevices.forEach((v, k) => { allDevices.set(k, v); });
    // 3) 每个设备：off 三类监听 -> disconnect -> close
    allDevices.forEach((gatt: ble.GattClientDevice, key: string) => {
      this.releaseGattDevice(gatt, key);
    });
    // 4) 清空所有 Map
    this.connectedDevices.clear();
    this.currentlyConnectingDevices.clear();
    this.plugin.bondManager.clearAll();
    this.plugin.gattCache.clearAll();
    this.plugin.mtuManager.clearAll();
    this.plugin.notifyManager.clearAll();
    this.autoConnectedDevices.clear();
    this.plugin.scanManager.advSeenMap.clear();
    this.plugin.scanManager.scanCountsMap.clear();
    this.plugin.scanManager.nameSeenMap.clear();
    this.plugin.scanManager.scanFiltersMap.clear();
    // 5) 复位扫描状态
    this.plugin.scanManager.isScanning = false;
  }
}
