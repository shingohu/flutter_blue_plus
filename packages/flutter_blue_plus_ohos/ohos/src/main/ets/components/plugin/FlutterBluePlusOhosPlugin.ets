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
import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
  AbilityPluginBinding,
} from '@ohos/flutter_ohos';
import { ble, connection } from '@kit.ConnectivityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import access from '@ohos.bluetooth.access';
import BleUtils from './BleUtils';
import BlePermissionManager from './BlePermissionManager';
import BleScanManager from './BleScanManager';
import BleGattManager from './BleGattManager';
import BleCharacteristicManager from './BleCharacteristicManager';
import BleDescriptorManager from './BleDescriptorManager';
import BleNotifyManager from './BleNotifyManager';
import BleMtuManager from './BleMtuManager';
import BleConnectionManager from './BleConnectionManager';
import BleBondManager from './BleBondManager';
import GattCacheHolder from './GattCacheHolder';
import BleMethodDispatcher from './BleMethodDispatcher';

/**
 * FlutterBluePlus OHOS 插件主入口：实现 FlutterPlugin 与 MethodCallHandler，
 * 持有扫描/GATT/连接/配对四大 Manager 并通过 MethodChannel 与 Flutter 端双向通信。
 * 方法分发与各 handle* handler 已剥离至 {@link BleMethodDispatcher}。
 */
export default class FlutterBluePlusOhosPlugin implements FlutterPlugin, MethodCallHandler {
  /** MethodChannel，供 Manager 回调 invokeMethod。public 供 Manager 访问。 */
  public channel: MethodChannel | null = null;
  /** 权限管理器：封装 ACCESS_BLUETOOTH 权限检测/申请。 */
  public permissionManager: BlePermissionManager = new BlePermissionManager();
  /** GATT 共享缓存层：持有 mtuMap/writeChrMap/writeDescMap/deviceServicesMap。 */
  public gattCache: GattCacheHolder = new GattCacheHolder();
  /** 扫描管理器：startScan/stopScan/扫描回调（广播解析在 BleAdvParser）。 */
  public scanManager!: BleScanManager;
  /** GATT 管理器(facade)：服务发现/RSSI/通知回调，读写委托子 Manager。 */
  public gattManager!: BleGattManager;
  /** 特征读写管理器：read/writeCharacteristic，经 gattCache.writeChrMap。 */
  public characteristicManager!: BleCharacteristicManager;
  /** 描述符读写管理器：read/writeDescriptor，经 gattCache.writeDescMap。 */
  public descriptorManager!: BleDescriptorManager;
  /** 通知管理器：setNotifyValue + 特征变化回调。 */
  public notifyManager!: BleNotifyManager;
  /** MTU 管理器：MTU 协商/回调注册/回传，持有 mtuCallbackMap。 */
  public mtuManager!: BleMtuManager;
  /** 连接管理器：connect/disconnect，持有连接状态及状态回调。 */
  public connectionManager!: BleConnectionManager;
  /** 配对管理器：create/remove/getBond，持有 bondingDevices。 */
  public bondManager!: BleBondManager;
  /** 方法分发器：方法名 -> handler 查找表 + 各 handle* handler。 */
  public dispatcher!: BleMethodDispatcher;
  /** detached 标志：回调首行检查，引擎分离后阻止重入。 */
  public isDetached: boolean = false;

  /**
   * 返回插件类名, 供 Flutter 框架识别。
   * @returns 插件类名字符串
   */
  getUniqueClassName(): string {
    return 'FlutterBluePlusOhosPlugin';
  }

  /**
   * 引擎附加时调用: 创建 MethodChannel 并注册方法处理器,
   * 复位 detached 标志, 构造并接线各 Manager。
   * @param binding - 引擎绑定信息, 提供 BinaryMessenger
   */
  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.isDetached = false;
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'flutter_blue_plus/methods');
    this.channel.setMethodCallHandler(this);
    // 连接管理器持有 connectedDevices 等连接状态，此处构造。
    this.connectionManager = new BleConnectionManager(this);
    // 配对管理器持有 bondingDevices，createBond 经 connectedDevices 反查。
    this.bondManager = new BleBondManager(this);
    // GATT 管理器(facade)：服务发现/RSSI/通知回调。
    this.gattManager = new BleGattManager(this);
    // 特征读写管理器，经 gattCache.writeChrMap 共享缓存。
    this.characteristicManager = new BleCharacteristicManager(this);
    // 描述符读写管理器，经 gattCache.writeDescMap/mtuMap 共享缓存。
    this.descriptorManager = new BleDescriptorManager(this);
    // 通知管理器，持有特征变化回调与 ENABLE_* CCCD 值。
    this.notifyManager = new BleNotifyManager(this);
    // MTU 管理器持有 mtuCallbackMap，经共享缓存访问。
    this.mtuManager = new BleMtuManager(this);
    // 扫描管理器需引用本插件（isDetached/channel），此处构造。
    this.scanManager = new BleScanManager(this);
    // 方法分发器需引用本插件以访问各 Manager，此处构造。
    this.dispatcher = new BleMethodDispatcher(this);
  }

  /**
   * 引擎分离时调用: 释放所有 BLE 资源(停扫描/断开设备/清空状态)并取消全局监听。
   * @param binding - 引擎绑定信息
   */
  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.isDetached = true;
    if (this.channel != null) {
      this.channel.setMethodCallHandler(null);
    }
    // 优先释放所有设备与扫描资源
    this.connectionManager.cleanup();
    // 再精确 off 全局监听
    try {
      connection.off('bondStateChange', this.bondManager.bondStateChangeCallback);
    } catch (e) {
      BleUtils.log(hilog.LogLevel.ERROR, `onDetachedFromEngine: off bondStateChange failed: ${JSON.stringify(e)}`);
    }
    try {
      access.off('stateChange', this.connectionManager.stateChangeCallback);
    } catch (e) {
      BleUtils.log(hilog.LogLevel.ERROR, `onDetachedFromEngine: off stateChange failed: ${JSON.stringify(e)}`);
    }
    try {
      ble.off('BLEDeviceFind', this.scanManager.onScanResult);
    } catch (e) {
      BleUtils.log(hilog.LogLevel.ERROR, `onDetachedFromEngine: off BLEDeviceFind failed: ${JSON.stringify(e)}`);
    }
    this.channel = null;
  }

  /**
   * Ability 附加时调用: 复位 detached 标志,
   * 注册绑定状态/适配器状态监听, 获取 Ability context。
   * 全局监听注册前先 off 可能的旧监听, 避免多次 attach 累积回调。
   * @param binding - Ability 绑定信息
   */
  onAttachedToAbility(binding: AbilityPluginBinding) {
    this.isDetached = false;
    try {
      connection.off('bondStateChange', this.bondManager.bondStateChangeCallback);
    } catch (e) {
      BleUtils.log(hilog.LogLevel.WARN, `onAttachedToAbility: off bondStateChange failed: ${JSON.stringify(e)}`);
    }
    connection.on('bondStateChange', this.bondManager.bondStateChangeCallback);
    // stateChange 须在 Ability 生命周期注册, 否则热重启前适配器状态变化不会被监测。
    try {
      access.off('stateChange', this.connectionManager.stateChangeCallback);
    } catch (e) {
      BleUtils.log(hilog.LogLevel.WARN, `onAttachedToAbility: off stateChange failed: ${JSON.stringify(e)}`);
    }
    access.on('stateChange', this.connectionManager.stateChangeCallback);
    this.permissionManager.context = binding.getAbility().context;
  }

  /**
   * Ability 分离时调用: 取消绑定状态/适配器状态监听, 清空 Ability context。
   * @param binding - Ability 绑定信息
   */
  onDetachedFromAbility(binding: AbilityPluginBinding) {
    try {
      connection.off('bondStateChange', this.bondManager.bondStateChangeCallback);
    } catch (e) {
      BleUtils.log(hilog.LogLevel.ERROR, `onDetachedFromAbility: failed to off bondStateChange: ${JSON.stringify(e)}`);
    }
    try {
      access.off('stateChange', this.connectionManager.stateChangeCallback);
    } catch (e) {
      BleUtils.log(hilog.LogLevel.ERROR, `onDetachedFromAbility: failed to off stateChange: ${JSON.stringify(e)}`);
    }
    // 清空 Ability context, 避免分离后仍使用失效 context 申请权限。
    this.permissionManager.context = null;
  }

  /**
   * MethodChannel 方法分发入口: 委托分发器按 call.method 分发到对应 BLE 操作。
   * @param call - 方法调用, 含方法名与参数
   * @param result - 结果回调, 用于向 Flutter 端返回成功/错误
   */
  async onMethodCall(call: MethodCall, result: MethodResult): Promise<void> {
    await this.dispatcher.onMethodCall(call, result);
  }
}
