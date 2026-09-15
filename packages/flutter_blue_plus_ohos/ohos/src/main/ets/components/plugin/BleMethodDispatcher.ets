/*
 * Copyright (C) 2024 Huawei Device Co., Ltd.
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
import { deviceInfo } from '@kit.BasicServicesKit';
import access from '@ohos.bluetooth.access';
import BleUtils from './BleUtils';
import FlutterBluePlusOhosPlugin from './FlutterBluePlusOhosPlugin';

/** MethodChannel 方法处理函数类型（缩短 handlers 注册处的签名长度）。 */
type Handler = (call: MethodCall, result: MethodResult) => Promise<void>;

/**
 * MethodChannel 方法分发器。
 *
 * 从 FlutterBluePlusOhosPlugin 剥离的方法分发与各 handle* handler：按 call.method 在查找表中
 * 分发到对应 BLE 操作（用 Map 查找替代巨型 switch，降低圈复杂度），
 * 顶层 catch 捕获未处理异常
 * 并通过 result.error 上报。handler 为无状态箭头函数闭包，首次构造后缓存复用。
 *
 * 经 plugin 中介访问各 Manager（this.plugin.scanManager / connectionManager / ...）与 channel，
 * 自身不持有业务状态，故可在插件构造后安全缓存。
 */
export default class BleMethodDispatcher {
  /** 宿主插件引用，用于访问各 Manager / channel / permissionManager。 */
  private plugin: FlutterBluePlusOhosPlugin;

  /** 方法名 -> 处理函数 的查找表（懒构造，handlers 无状态可安全缓存）。 */
  private _methodHandlers: Map<string, Handler> | null = null;

  /**
   * 构造分发器。
   * @param plugin - 宿主插件引用
   */
  constructor(plugin: FlutterBluePlusOhosPlugin) {
    this.plugin = plugin;
  }

  /**
   * MethodChannel 方法分发入口: 按 call.method 在查找表中分发到对应 BLE 操作。
   * 顶层 catch 捕获未处理异常并通过 result.error 上报。
   * @param call - 方法调用, 含方法名与参数
   * @param result - 结果回调, 用于向 Flutter 端返回成功/错误
   */
  async onMethodCall(call: MethodCall, result: MethodResult): Promise<void> {
    try {
      let handler = this.getMethodHandlers().get(call.method);
      if (handler != null) {
        await handler(call, result);
      } else {
        result.notImplemented();
      }
    } catch (e) {
      let error = e as BusinessError;
      let msg: string = error?.message ?? `unknown error: ${JSON.stringify(e)}`;
      BleUtils.log(hilog.LogLevel.ERROR,
        `onMethodCall: unhandled exception for method='${call.method}', ` +
          `code=${error?.code}, msg=${msg}`);
      try {
        // 错误码用 call.method（方法名）而非 Android 的固定串 "androidException"：
        // 方法名能直接定位是哪个 handler 抛出的异常，信息量更大、更利于排查；
        // errorCode/message 格式与各 handler 自身 result.error(method, ...) 保持一致。
        result.error(call.method, msg, null);
      } catch (resultErr) {
        // result 可能已被对应 case 处理过，忽略 double-response
      }
      return;
    }
  }

  /**
   * 构建并缓存 方法名 -> 处理函数 的查找表。
   * handlers 为无状态箭头函数闭包，首次构造后缓存到 _methodHandlers，后续直接复用。
   * @returns 方法名到处理函数的 Map
   */
  private getMethodHandlers(): Map<string, Handler> {
    if (this._methodHandlers != null) {
      return this._methodHandlers;
    }
    let handlers = new Map<string, Handler>();
    handlers.set('flutterRestart', (c, r) => this.handleFlutterRestart(c, r));
    handlers.set('connectedCount', (c, r) => this.handleConnectedCount(c, r));
    handlers.set('setOptions', (c, r) => this.handleSetOptions(c, r));
    handlers.set('getAdapterState', (c, r) => this.handleGetAdapterState(c, r));
    handlers.set('getAdapterName', (c, r) => this.handleGetAdapterName(c, r));
    handlers.set('isSupported', (c, r) => this.handleIsSupported(c, r));
    handlers.set('getSystemDevices', (c, r) => this.handleGetSystemDevices(c, r));
    handlers.set('turnOn', (c, r) => this.handleTurnOn(c, r));
    handlers.set('turnOff', (c, r) => this.handleTurnOff(c, r));
    handlers.set('startScan', (c, r) => this.handleStartScan(c, r));
    handlers.set('setLogLevel', (c, r) => this.handleSetLogLevel(c, r));
    handlers.set('stopScan', (c, r) => this.handleStopScan(c, r));
    handlers.set('connect', (c, r) => this.handleConnect(c, r));
    handlers.set('readRssi', (c, r) => this.handleReadRssi(c, r));
    handlers.set('discoverServices', (c, r) => this.handleDiscoverServices(c, r));
    handlers.set('setNotifyValue', (c, r) => this.handleSetNotifyValue(c, r));
    handlers.set('disconnect', (c, r) => this.handleDisconnect(c, r));
    handlers.set('requestMtu', (c, r) => this.handleRequestMtu(c, r));
    handlers.set('readCharacteristic', (c, r) => this.handleReadCharacteristic(c, r));
    handlers.set('writeCharacteristic', (c, r) => this.handleWriteCharacteristic(c, r));
    handlers.set('readDescriptor', (c, r) => this.handleReadDescriptor(c, r));
    handlers.set('writeDescriptor', (c, r) => this.handleWriteDescriptor(c, r));
    handlers.set('getBondedDevices', (c, r) => this.handleGetBondedDevices(c, r));
    handlers.set('getBondState', (c, r) => this.handleGetBondState(c, r));
    handlers.set('getPhySupport', (c, r) => this.handleGetPhySupport(c, r));
    handlers.set('createBond', (c, r) => this.handleCreateBond(c, r));
    handlers.set('removeBond', (c, r) => this.handleRemoveBond(c, r));
    handlers.set('clearGattCache', (c, r) => this.handleClearGattCache(c, r));
    // OHOS BLE 接口未暴露连接优先级/PHY 设置 API，
    // 占位返回成功以保持 API 兼容（底层不生效）。
    handlers.set('requestConnectionPriority', async (c, r) => { r.success(true); });
    handlers.set('setPreferredPhy', async (c, r) => { r.success(true); });
    this._methodHandlers = handlers;
    return handlers;
  }

  /** 处理 FlutterRestart：委托 ConnectionManager。 */
  private async handleFlutterRestart(call: MethodCall, result: MethodResult): Promise<void> {
    await this.plugin.connectionManager.flutterRestart(result);
  }

  /** 处理 ConnectedCount：委托 ConnectionManager。 */
  private async handleConnectedCount(call: MethodCall, result: MethodResult): Promise<void> {
    await this.plugin.connectionManager.connectedCount(result);
  }

  /**
   * 处理 setOptions：OHOS 下无运行时配置项，直接返回成功。
   *
   * 平台限制：Dart 端 BmSetOptionsRequest 携带的 showPowerAlert / restoreState 为 iOS 专属配置，
   * OHOS 与 Android 均不处理（Android 参考实现 FlutterBluePlusPlugin.java 同样忽略并返回 true），
   * 故此处忽略入参、固定返回 true，与 Android 行为保持一致。
   */
  private async handleSetOptions(call: MethodCall, result: MethodResult): Promise<void> {
    result.success(true);
  }

  /** 处理 getAdapterState：返回蓝牙适配器当前状态。 */
  private async handleGetAdapterState(call: MethodCall, result: MethodResult): Promise<void> {
    let accessNum: number = -1;
    try {
      accessNum = access.getState();
    } catch (e) {
      BleUtils.log(hilog.LogLevel.ERROR, 'getAdapterState: Failed to get adapter state: ' + JSON.stringify(e));
    }
    let map: Map<string, number> = new Map();
    map.set('adapter_state', BleUtils.bmAdapterStateEnum(accessNum));
    result.success(map);
  }

  /**
   * 处理 getAdapterName：返回本机蓝牙适配器名称。
   * 对标 Android `BluetoothAdapter.getName()`，优先使用 connection.getLocalName()（本机蓝牙名），
   * 获取失败时回退 deviceInfo.productModel 占位；适配器关闭时返回空串。
   */
  private async handleGetAdapterName(call: MethodCall, result: MethodResult): Promise<void> {
    try {
      let state = access.getState();
      // 仅在适配器开启时返回名称,
      // 关闭时返回空串(Dart 端 r.adapterName 直接作为字符串赋值)。
      if (state == access.BluetoothState.STATE_ON ||
        state == access.BluetoothState.STATE_BLE_ON ||
        state == access.BluetoothState.STATE_TURNING_ON ||
        state == access.BluetoothState.STATE_BLE_TURNING_ON) {
        // getLocalName 返回本机蓝牙名, 语义最接近 Android 的 adapter.getName()。
        // 极少数情况下返回空或抛异常时, 回退 deviceInfo.productModel 占位。
        let name: string = '';
        try {
          name = connection.getLocalName() ?? '';
        } catch (le) {
          BleUtils.log(hilog.LogLevel.WARN,
            'getAdapterName: getLocalName failed, fallback to productModel: ' + JSON.stringify(le));
        }
        if (name == '') {
          name = deviceInfo.productModel ?? '';
        }
        result.success(name);
      } else {
        result.success('');
      }
    } catch (e) {
      BleUtils.log(hilog.LogLevel.ERROR, 'getAdapterName: failed: ' + JSON.stringify(e));
      result.success('');
    }
  }

  /** 处理 isSupported：检测当前设备是否支持蓝牙。 */
  private async handleIsSupported(call: MethodCall, result: MethodResult): Promise<void> {
    let isSupported: boolean = true;
    try {
      access.getState();
    } catch (e) {
      isSupported = false;
    }
    // Dart 端 _callOhosMethod<bool>('isSupported') == true 期望裸 bool,
    // 不能用 Map 包装, 否则 Map == true 恒为 false。
    result.success(isSupported);
  }

  /** 处理 getSystemDevices：返回系统已连接的 BLE 设备列表（含 platform_name）。 */
  private async handleGetSystemDevices(call: MethodCall, result: MethodResult): Promise<void> {
    if (!(await this.plugin.permissionManager.ensurePermissions(result, 'getSystemDevices'))) {
      return;
    }
    try {
      let devices: string[] = ble.getConnectedBLEDevices();
      let devList: List<Map<string, string>> = new List<Map<string, string>>();
      // 参照 getBondedDevices: 为每个设备获取名称填充 platform_name, 取名失败兜底空串。
      for (let device of devices) {
        let gatt: ble.GattClientDevice | null = null;
        try {
          gatt = ble.createGattClientDevice(device);
          let name: string = await gatt.getDeviceName();
          devList.add(BleUtils.bmBluetoothDevice(device, name));
        } catch (e) {
          BleUtils.log(hilog.LogLevel.ERROR,
            `getSystemDevices: failed to read name for ${device}, code=${e?.code}, msg=${e?.message}`);
          devList.add(BleUtils.bmBluetoothDevice(device, ''));
        } finally {
          if (gatt != null) {
            try {
              gatt.close();
            } catch (closeErr) {
              BleUtils.log(hilog.LogLevel.WARN,
                `getSystemDevices: close failed for ${device}: ${JSON.stringify(closeErr)}`);
            }
          }
        }
      }
      let response: Map<string, object> = new Map();
      response.set('devices', devList);
      result.success(response);
    } catch (err) {
      BleUtils.log(hilog.LogLevel.ERROR,
        `getSystemDevices: failed to get connected BLE devices, ` +
          `errCode=${err?.code}, errMsg=${err?.message}`);
      // 必须回调 result, 否则 Flutter MethodChannel 调用永久挂起。
      result.error('getSystemDevices', err?.message ?? 'Failed to get connected BLE devices', null);
    }
  }

  /** 处理 turnOn：打开蓝牙适配器，并根据 apiVersion 选择同步/异步启用方式。 */
  private async handleTurnOn(call: MethodCall, result: MethodResult): Promise<void> {
    if (!(await this.plugin.permissionManager.ensurePermissions(result, 'turnOn'))) {
      return;
    }
    try {
      let state = access.getState();
      if (state == access.BluetoothState.STATE_OFF || state == access.BluetoothState.STATE_TURNING_OFF ||
        state == access.BluetoothState.STATE_BLE_TURNING_OFF) {
        const apiVersion: number = deviceInfo.sdkApiVersion;
        // OHOS API 20+ 才提供 enableBluetoothAsync，
        // 低版本只能用同步 enableBluetooth（内部仍可能弹窗）。
        if (apiVersion >= 20) {
          access.enableBluetoothAsync().then(() => {
            this.emitTurnOnResponse(true);
          }, (error: BusinessError) => {
            // 2900014 为用户拒绝开启蓝牙的错误码，回传 user_accepted:false；
            // 其他系统错误（如 2900099 操作失败 / 2900003 蓝牙已关闭等）也需记录日志，
            // 避免静默忽略导致 Flutter 端无任何线索且系统错误被吞掉。
            BleUtils.log(hilog.LogLevel.ERROR,
              `handleTurnOn: enableBluetoothAsync failed, code=${error.code}, msg=${error.message}`);
            if (error.code === 2900014) {
              this.emitTurnOnResponse(false);
            }
          });
          result.success(true);
        } else {
          try {
            await access.enableBluetooth();
            this.emitTurnOnResponse(true);
            result.success(true);
          } catch (error) {
            this.emitTurnOnResponse(false);
            result.success(true);
          }
        }
      } else {
        this.emitTurnOnResponse(true);
        result.success(false);
      }
    } catch (e) {
      // 适配器启用失败：通知 Flutter 用户未接受，
      // 并返回 changed=false（无状态变化，不触发等待）。
      // 不返回 result.error，避免与 turnOn 的 Future<bool> changed 语义冲突。
      this.emitTurnOnResponse(false);
      BleUtils.log(hilog.LogLevel.ERROR, `handleTurnOn: failed: ${JSON.stringify(e)}`);
      result.success(false);
    }
  }

  /**
   * 回传 OnTurnOnResponse 到 Flutter 端。
   * 使用 Map 构造响应（与项目其他 invokeMethod 调用一致），
   * 避免对象字面量在 ArkTS 严格模式下的序列化风险。
   * @param userAccepted - 用户是否接受开启蓝牙
   */
  private emitTurnOnResponse(userAccepted: boolean): void {
    try {
      let response: Map<string, boolean> = new Map<string, boolean>();
      response.set('user_accepted', userAccepted);
      this.plugin.channel?.invokeMethod('OnTurnOnResponse', response);
    } catch (e) {
      BleUtils.log(hilog.LogLevel.ERROR,
        `emitTurnOnResponse: invokeMethod OnTurnOnResponse(${userAccepted}) failed: ${JSON.stringify(e)}`);
    }
  }

  /** 处理 turnOff：关闭蓝牙适配器。 */
  private async handleTurnOff(call: MethodCall, result: MethodResult): Promise<void> {
    if (!(await this.plugin.permissionManager.ensurePermissions(result, 'turnOff'))) {
      return;
    }
    let state = access.getState();
    if (state == access.BluetoothState.STATE_ON || state == access.BluetoothState.STATE_TURNING_ON ||
      state == access.BluetoothState.STATE_BLE_TURNING_ON || state == access.BluetoothState.STATE_BLE_ON) {
      try {
        access.disableBluetooth();
        result.success(true);
      } catch (e) {
        result.success(false);
      }
      return;
    }
    result.success(false);
  }

  /** 处理 startScan：按服务/远程ID/名称/制造商数据/服务数据过滤后启动 BLE 扫描。 */
  private async handleStartScan(call: MethodCall, result: MethodResult): Promise<void> {
    await this.plugin.scanManager.startScan(call, result);
  }

  /** 处理 setLogLevel：根据传入等级索引设置 hilog 日志级别。 */
  private async handleSetLogLevel(call: MethodCall, result: MethodResult): Promise<void> {
    let idx: number = call.args as number;
    // 参数校验：idx 必须为合法 number，非法值回退到默认 DEBUG 级别。
    if (idx == null || idx == undefined || typeof idx !== 'number') {
      BleUtils.log(hilog.LogLevel.WARN, `setLogLevel: invalid idx=${JSON.stringify(call.args)}, fallback to DEBUG`);
      idx = 4;
    }
    switch (idx) {
      case 0:
        BleUtils.logLevel = hilog.LogLevel.FATAL + 1; // disable all logs
        break;
      case 1:
        BleUtils.logLevel = hilog.LogLevel.ERROR;
        break;
      case 2:
        BleUtils.logLevel = hilog.LogLevel.WARN;
        break;
      case 3:
        BleUtils.logLevel = hilog.LogLevel.INFO;
        break;
      case 4:
      case 5:
        BleUtils.logLevel = hilog.LogLevel.DEBUG;
        break;
      default:
        BleUtils.logLevel = hilog.LogLevel.DEBUG;
        break;
    }
    result.success(true);
  }

  /** 处理 stopScan：停止 BLE 扫描并清理扫描状态。 */
  private async handleStopScan(call: MethodCall, result: MethodResult): Promise<void> {
    await this.plugin.scanManager.stopScan(result);
  }

  /** 处理 Connect：委托 ConnectionManager。 */
  private async handleConnect(call: MethodCall, result: MethodResult): Promise<void> {
    await this.plugin.connectionManager.connect(call, result);
  }

  /** 处理 readRssi：读取已连接设备的 RSSI 值并通过 OnReadRssi 回传。 */
  private async handleReadRssi(call: MethodCall, result: MethodResult): Promise<void> {
    await this.plugin.gattManager.readRssi(call, result);
  }

  /** 处理 discoverServices：发现已连接设备的 GATT 服务。 */
  private async handleDiscoverServices(call: MethodCall, result: MethodResult): Promise<void> {
    await this.plugin.gattManager.discoverServices(call, result);
  }

  /** 处理 requestMtu：协商 MTU 大小并通过 OnMtuChanged 回传结果。 */
  private async handleRequestMtu(call: MethodCall, result: MethodResult): Promise<void> {
    await this.plugin.mtuManager.requestMtu(call, result);
  }

  /** 处理 GetBondedDevices：委托 BondManager。 */
  private async handleGetBondedDevices(call: MethodCall, result: MethodResult): Promise<void> {
    await this.plugin.bondManager.getBondedDevices(call, result);
  }

  /** 处理 GetBondState：委托 BondManager。 */
  private async handleGetBondState(call: MethodCall, result: MethodResult): Promise<void> {
    await this.plugin.bondManager.getBondState(call, result);
  }

  /** 处理 GetPhySupport：委托 GattManager。 */
  private async handleGetPhySupport(call: MethodCall, result: MethodResult): Promise<void> {
    await this.plugin.gattManager.getPhySupport(call, result);
  }

  /** 处理 CreateBond：委托 BondManager。 */
  private async handleCreateBond(call: MethodCall, result: MethodResult): Promise<void> {
    await this.plugin.bondManager.createBond(call, result);
  }

  /** 处理 RemoveBond：委托 BondManager。 */
  private async handleRemoveBond(call: MethodCall, result: MethodResult): Promise<void> {
    await this.plugin.bondManager.removeBond(call, result);
  }

  /** 处理 ClearGattCache：委托 GattManager。 */
  private async handleClearGattCache(call: MethodCall, result: MethodResult): Promise<void> {
    await this.plugin.gattManager.clearGattCache(call, result);
  }

  /** 处理 setNotifyValue：开启/关闭特征通知，并写入 BleUtils.CCCD 描述符。 */
  private async handleSetNotifyValue(call: MethodCall, result: MethodResult): Promise<void> {
    await this.plugin.notifyManager.setNotifyValue(call, result);
  }

  /** 处理 Disconnect：委托 ConnectionManager。 */
  private async handleDisconnect(call: MethodCall, result: MethodResult): Promise<void> {
    await this.plugin.connectionManager.disconnect(call, result);
  }

  /** 处理 ReadCharacteristic：委托 CharacteristicManager。 */
  private async handleReadCharacteristic(call: MethodCall, result: MethodResult): Promise<void> {
    await this.plugin.characteristicManager.readCharacteristic(call, result);
  }

  /** 处理 WriteCharacteristic：委托 CharacteristicManager。 */
  private async handleWriteCharacteristic(call: MethodCall, result: MethodResult): Promise<void> {
    await this.plugin.characteristicManager.writeCharacteristic(call, result);
  }

  /** 处理 ReadDescriptor：委托 DescriptorManager。 */
  private async handleReadDescriptor(call: MethodCall, result: MethodResult): Promise<void> {
    await this.plugin.descriptorManager.readDescriptor(call, result);
  }

  /** 处理 WriteDescriptor：委托 DescriptorManager。 */
  private async handleWriteDescriptor(call: MethodCall, result: MethodResult): Promise<void> {
    await this.plugin.descriptorManager.writeDescriptor(call, result);
  }
}
