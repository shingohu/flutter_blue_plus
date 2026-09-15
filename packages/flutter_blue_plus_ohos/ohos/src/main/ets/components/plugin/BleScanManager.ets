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
import { HashMap, List } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import BleDevice from './BleDevice';
import HexUtil from './HexUtil';
import BleUtils from './BleUtils';
import BleAdvParser, { AdvData } from './BleAdvParser';
import FlutterBluePlusOhosPlugin from './FlutterBluePlusOhosPlugin';

/** 扫描结果 Map 的值类型（BmScanAdvertisement 异构 payload）。 */
type ScanAdvValue = string | number | boolean | Uint8Array | List<string>
  | Map<string, Uint8Array> | Map<number, Uint8Array>;

/**
 * 扫描过滤参数 Map 的值类型（BmStartScanArgs.toMap 异构 payload：
 * string / List<string> / List<object> / boolean / number）。
 */
export type ScanFiltersValue = string | List<string> | List<object> | boolean | number;

/**
 * 蓝牙扫描管理器。
 *
 * 封装 BLE 扫描的启动/停止、扫描结果去重与关键词过滤，
 * 以及 onScanResult 回调（成员属性箭头函数，保证 ble.on/off 传引用时 this 不丢失）。
 * 广播数据解析（AdvData/parseAdvHexData/getManufacturerSpecificData）已剥离至 BleAdvParser。
 * 通过 plugin 引用访问 isDetached、channel、permissionManager。
 */
export default class BleScanManager {
  /** 插件引用，用于访问 isDetached/channel/permissionManager。 */
  private plugin: FlutterBluePlusOhosPlugin;

  /** 是否正在扫描（由 handleStopScan/cleanup 复位）。 */
  public isScanning: boolean = false;
  /** 当前扫描过滤参数（来自 Dart 端 BmStartScanArgs.toMap）。 */
  public scanFiltersMap: Map<string, ScanFiltersValue> = new Map();
  /** 已见过的广播数据（remoteId -> advHex），用于非连续模式下重复抑制。 */
  public advSeenMap: Map<string, string> = new Map();
  /**
   * 已解析的设备名缓存（remoteId -> name），避免连续扫描下无 localName 的设备
   * 反复创建 GattClientDevice 读名。
   */
  public nameSeenMap: Map<string, string> = new Map();
  /** 每个设备的扫描计数，用于连续模式下的除数降频。 */
  public scanCountsMap: Map<string, number> = new Map();

  /**
   * 构造扫描管理器。
   * @param plugin - 宿主插件引用
   */
  constructor(plugin: FlutterBluePlusOhosPlugin) {
    this.plugin = plugin;
  }

  /**
   * ble.on('BLEDeviceFind') 回调：保持成员属性箭头函数形式，
   * 保证 ble.on/off 传引用时 this 不丢失。引擎分离后直接返回。
   */
  public onScanResult = async (data: ble.ScanResult[]) => {
    if (this.plugin.isDetached) {
      return;
    }
    await this.scanCallback(data);
  };

  /**
   * 处理 startScan：按服务/远程ID/名称/制造商数据/服务数据过滤后启动 BLE 扫描。
   * OHOS ScanDuty/MatchMode 无对应 Dart 参数映射，固定 LOW_LATENCY+STICKY（平台限制）。
   */
  async startScan(call: MethodCall, result: MethodResult): Promise<void> {
    try {
      let data: Map<string, ScanFiltersValue> = call.args;
      if (!data) {
        result.error('startScan', 'args is null', null);
        return;
      }
      if (!await this.plugin.permissionManager.ensurePermissions(result, 'startScan')) {
        return;
      }
      if (!BleUtils.isAdapterOn()) {
        // 适配器关闭必须回传 result.error，否则 Flutter 端 MethodChannel 调用将永久挂起
        // （Future 不 resolve）。
        result.error('startScan', 'bluetooth adapter is turned off', null);
        return;
      }
      let filterArray: ble.ScanFilter[] = this.buildScanFilters(data);
      this.registerAndStartScan(data, filterArray);
      // 标记扫描进行中，供 isScanningNow 状态查询与扫描去重使用；
      // 在 stopScan/cleanup 复位为 false。
      this.isScanning = true;
      result.success(true);
    } catch (err) {
      let error = err as BusinessError;
      BleUtils.log(hilog.LogLevel.ERROR,
        `startScan: Failed to start BLE scan, code=${error?.code}, msg=${error?.message}`);
      try {
        ble.off('BLEDeviceFind', this.onScanResult);
      } catch (offErr) {
        BleUtils.log(hilog.LogLevel.WARN, `startScan: off BLEDeviceFind on failure failed: ${JSON.stringify(offErr)}`);
      }
      result.error('startScan', error?.message ?? 'Failed to start BLE scan', null);
    }
  }

  /**
   * 注册扫描回调并启动 BLE 扫描。
   * 注册前先 off 可能的旧监听, 避免重复 startScan 累积导致回调多次执行。
   */
  private registerAndStartScan(data: Map<string, ScanFiltersValue>, filterArray: ble.ScanFilter[]): void {
    let scanOption: ble.ScanOptions = {
      dutyMode: ble.ScanDuty.SCAN_MODE_LOW_LATENCY,
      matchMode: ble.MatchMode.MATCH_MODE_STICKY,
      interval: 1000
    };
    try {
      ble.off('BLEDeviceFind', this.onScanResult);
    } catch (e) {
      BleUtils.log(hilog.LogLevel.WARN, `registerAndStartScan: off BLEDeviceFind failed: ${JSON.stringify(e)}`);
    }
    ble.on('BLEDeviceFind', this.onScanResult);
    this.scanFiltersMap = data;
    // clear seen devices
    this.advSeenMap.clear();
    this.scanCountsMap.clear();
    this.nameSeenMap.clear();
    if (filterArray.length == 0) {
      ble.startBLEScan(null, scanOption);
    } else {
      ble.startBLEScan(filterArray, scanOption);
    }
  }

  /**
   * 根据各过滤维度构造 ble.ScanFilter 数组。
   * 各维度由独立 builder 方法构造，便于阅读与维护。
   */
  private buildScanFilters(data: Map<string, ScanFiltersValue>): ble.ScanFilter[] {
    let withServices: List<string> = (data.get('with_services') as List<string>) ?? new List<string>();
    let withRemoteIds: List<string> = (data.get('with_remote_ids') as List<string>) ?? new List<string>();
    let withNames: List<string> = (data.get('with_names') as List<string>) ?? new List<string>();
    let withMsd: List<object> = (data.get('with_msd') as List<object>) ?? new List<object>();
    let withServiceData: List<object> = (data.get('with_service_data') as List<object>) ?? new List<object>();
    let filterArray: ble.ScanFilter[] = [];
    this.appendServiceFilters(filterArray, withServices);
    this.appendRemoteIdFilters(filterArray, withRemoteIds);
    this.appendNameFilters(filterArray, withNames);
    this.appendManufacturerDataFilters(filterArray, withMsd);
    this.appendServiceDataFilters(filterArray, withServiceData);
    return filterArray;
  }

  /** 按 service UUID 追加过滤器。 */
  private appendServiceFilters(filterArray: ble.ScanFilter[], withServices: List<string>): void {
    for (let i = 0; i < withServices.length; i++) {
      filterArray.push({ serviceUuid: withServices[i] } as ble.ScanFilter);
    }
  }

  /** 按 remoteId（deviceId）追加过滤器。 */
  private appendRemoteIdFilters(filterArray: ble.ScanFilter[], withRemoteIds: List<string>): void {
    for (let i = 0; i < withRemoteIds.length; i++) {
      filterArray.push({ deviceId: withRemoteIds[i] } as ble.ScanFilter);
    }
  }

  /** 按设备名追加过滤器。 */
  private appendNameFilters(filterArray: ble.ScanFilter[], withNames: List<string>): void {
    for (let i = 0; i < withNames.length; i++) {
      filterArray.push({ name: withNames[i] } as ble.ScanFilter);
    }
  }

  /** 按制造商数据（manufacturer_id/data/mask）追加过滤器；缺 data 项跳过。 */
  private appendManufacturerDataFilters(filterArray: ble.ScanFilter[],
    withMsd: List<object>): void {
    for (let i = 0; i < withMsd.length; i++) {
      let rawMsd: object | null = withMsd.get(i);
      if (rawMsd == null) {
        continue;
      }
      let m: HashMap<string, number | Uint8Array> = rawMsd as HashMap<string, number | Uint8Array>;
      let id = (m.get('manufacturer_id') ?? 0) as number;
      let data: Uint8Array = m.get('data') as Uint8Array;
      if (data == null) {
        continue;
      }
      let mask: Uint8Array = m.get('mask') as Uint8Array;
      filterArray.push({
        manufactureId: id,
        manufactureData: data.buffer,
        manufactureDataMask: mask != null ? mask.buffer : undefined,
      } as ble.ScanFilter);
    }
  }

  /** 按服务数据（service/data/mask）追加过滤器；缺 service 项跳过。 */
  private appendServiceDataFilters(filterArray: ble.ScanFilter[],
    withServiceData: List<object>): void {
    for (let i = 0; i < withServiceData.length; i++) {
      let rawSvcData: object | null = withServiceData.get(i);
      if (rawSvcData == null) {
        continue;
      }
      let m: HashMap<string, string | Uint8Array> = rawSvcData as HashMap<string, string | Uint8Array>;
      let service: string = m.get('service') as string;
      if (service == null) {
        continue;
      }
      let mdata: Uint8Array = m.get('data') as Uint8Array;
      if (mdata == null) {
        continue;
      }
      let mask: Uint8Array = m.get('mask') as Uint8Array;
      filterArray.push({
        // OHOS 过滤接口要求 128 位 UUID, 故将 Dart 端可能的短 UUID 统一展开。
        serviceUuid: BleUtils.uuid128(service),
        serviceData: mdata.buffer,
        serviceDataMask: mask != null ? mask.buffer : undefined,
      } as ble.ScanFilter);
    }
  }

  /**
   * 处理 stopScan：停止 BLE 扫描并清理扫描状态。
   */
  async stopScan(result: MethodResult): Promise<void> {
    try {
      ble.stopBLEScan();
    } catch (e) {
      BleUtils.log(hilog.LogLevel.WARN, `stopScan: stopBLEScan failed: ${JSON.stringify(e)}`);
    }
    try {
      ble.off('BLEDeviceFind', this.onScanResult);
    } catch (e) {
      BleUtils.log(hilog.LogLevel.WARN, `stopScan: off BLEDeviceFind failed: ${JSON.stringify(e)}`);
    }
    this.advSeenMap.clear();
    this.scanCountsMap.clear();
    this.nameSeenMap.clear();
    this.scanFiltersMap.clear();
    this.isScanning = false;
    result.success(true);
  }

  /**
   * 扫描结果回调主体：解析广播、获取设备名、过滤、组装 BmScanAdvertisement
   * 并回传 Flutter。
   * 去重/降频逻辑见 shouldSuppressScanResult，响应回传见 emitScanResponse。
   * @param data - 扫描结果数组（OHOS 通常仅返回第一个）
   */
  async scanCallback(data: ble.ScanResult[]): Promise<void> {
    try {
      let item = data[0];
      let remoteId: string = item.deviceId;
      let scanData: Uint8Array = new Uint8Array(item.data);
      let advHex: string = HexUtil.formatHexString(scanData);
      BleUtils.log(hilog.LogLevel.DEBUG,
        `scanCallback: deviceId=${remoteId}, deviceName='${item.deviceName}', rssi=${item.rssi}, ` +
        `connectable=${item.connectable}, dataLen=${scanData.length}`);
      if (this.shouldSuppressScanResult(remoteId, advHex)) {
        return;
      }
      let device: BleDevice =
        new BleDevice({
          deviceId: item.deviceId,
          name: '',
          rssi: item.rssi,
          scanRecord: scanData,
          timestampNanos: new Date().getTime(),
          connectable: item.connectable,
        });
      let advDataSource: AdvData = BleAdvParser.parseAdvHexData(advHex);
      BleUtils.log(hilog.LogLevel.DEBUG,
        `scanCallback: advParsed localName='${advDataSource.localName}', ` +
        `serviceUUIDs=${advDataSource.serviceUUIDs?.length ?? 0}, ` +
        `flags='${advDataSource.flags}', appearance=${advDataSource.appearance}`);
      let deviceName: string = await this.resolveDeviceName(device, item.deviceName, advDataSource);
      device.setName(deviceName);
      BleUtils.log(hilog.LogLevel.DEBUG,
        `scanCallback: resolvedName='${deviceName}' for ${remoteId}`);
      let name: string = device.getName() != null ? device.getName() : '';
      let keywords: List<string> = this.scanFiltersMap.get('with_keywords') as List<string>;
      if (this.filterKeywords(keywords, name) == false) {
        return;
      }
      this.emitScanResponse(device, advDataSource, scanData);
    } catch (e) {
      // 顶层兜底: 解析畸形广播数据或组装异常时, 记录并吞掉, 避免未捕获的
      // Promise rejection 导致整批扫描结果丢失。
      BleUtils.log(hilog.LogLevel.ERROR,
        `scanCallback: unhandled error processing scan result: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 判断本次扫描结果是否应被抑制（不上报）。
   * 非连续模式: 按 remoteId 去重, 同一设备仅上报首次广播；连续模式: 按 divisor 除数降频。
   * @param remoteId - 设备 ID
   * @param advHex - 广播十六进制串（非连续模式下缓存）
   * @returns true 表示丢弃本次结果
   */
  private shouldSuppressScanResult(remoteId: string, advHex: string): boolean {
    // continuous_updates 缺失（Dart 未传）时默认 false（非连续模式），与 Dart 端默认值一致。
    // 避免 undefined as boolean == false 求值为 false 而误入连续模式
    // （导致非连续扫描下每帧重复上报）。
    let continuousUpdates: boolean = (this.scanFiltersMap.get('continuous_updates') as boolean) ?? false;
    // 非连续模式: 按 remoteId 去重, 同一设备仅上报首次广播, 避免重复刷屏。
    if (!continuousUpdates) {
      if (this.advSeenMap.has(remoteId)) {
        return true;
      }
      this.advSeenMap.set(remoteId, advHex);
      return false;
    }
    // 连续模式: 按 divisor 除数降频, 仅 count 整除 divisor 时上报, 否则丢弃本次。
    let count: number = this.scanCountIncrement(remoteId);
    // divisor 缺省时取 1（每帧上报），避免 undefined 导致 count % undefined == NaN 恒丢弃所有帧。
    let divisor: number = (this.scanFiltersMap.get('continuous_divisor') as number) ?? 1;
    return (count % divisor) != 0;
  }

  /**
   * 组装扫描响应并回传 OnScanResponse。
   * @param device - 已设置名称的 BleDevice
   * @param advDataSource - 已解析的广播数据
   * @param scanData - 原始扫描字节数组
   */
  private emitScanResponse(device: BleDevice, advDataSource: AdvData, scanData: Uint8Array): void {
    let response: Map<string, List<Map<string, ScanAdvValue>> | number | string> = new Map();
    let deviceList: List<Map<string, ScanAdvValue>> = new List<Map<string, ScanAdvValue>>();
    let map: Map<string, ScanAdvValue> = this.buildScanAdvMap(device, advDataSource, scanData);
    try {
      deviceList.add(map);
    } catch (error) {
      BleUtils.log(hilog.LogLevel.ERROR, `addDeviceToList: Failed to add device to list: ${JSON.stringify(error)}`);
    }
    response.set('advertisements', deviceList);
    if (this.plugin.channel != null) {
      this.plugin.channel.invokeMethod('OnScanResponse', response);
    }
  }

  /**
   * 解析设备名：优先使用 ScanResult.deviceName（OHOS 栈已解析的名称），
   * 其次广播中的 localName，再次查 nameSeenMap 缓存，
   * 仍无则临时创建 GattClientDevice 读取一次并缓存。
   *
   * 优先使用 item.deviceName 的原因：OHOS BLE 栈在扫描时已从广播/Scan Response
   * 中提取了设备名，比手动解析广播 AD type 更可靠（Scan Response 中的名称
   * 不在 item.data 中，但 OHOS 栈会合并到 deviceName 字段）。
   * @param device - 当前扫描到的 BleDevice
   * @param scanDeviceName - ScanResult.deviceName（OHOS 栈提供的名称）
   * @param advDataSource - 已解析的广播数据
   * @returns 设备名（可能为空串）
   */
  private async resolveDeviceName(device: BleDevice, scanDeviceName: string,
    advDataSource: AdvData): Promise<string> {
    // 优先级 1: OHOS 栈已解析的 deviceName（含 Scan Response 中的名称）
    let deviceName: string = scanDeviceName || '';
    if (deviceName !== '') {
      BleUtils.log(hilog.LogLevel.DEBUG,
        `resolveDeviceName: using scanDeviceName='${deviceName}' for ${device.getMac()}`);
      this.nameSeenMap.set(device.getMac(), deviceName);
      return deviceName;
    }
    // 优先级 2: 广播 AD type 0x08/0x09 解析的 localName
    deviceName = advDataSource.localName || '';
    if (deviceName !== '') {
      BleUtils.log(hilog.LogLevel.DEBUG,
        `resolveDeviceName: using advLocalName='${deviceName}' for ${device.getMac()}`);
      this.nameSeenMap.set(device.getMac(), deviceName);
      return deviceName;
    }
    // 优先级 3: nameSeenMap 缓存
    let cached: string | undefined = this.nameSeenMap.get(device.getMac());
    if (cached != null && cached !== '') {
      BleUtils.log(hilog.LogLevel.DEBUG,
        `resolveDeviceName: using cachedName='${cached}' for ${device.getMac()}`);
      return cached;
    }
    // 优先级 4: 临时创建 GattClientDevice 读取
    BleUtils.log(hilog.LogLevel.DEBUG,
      `resolveDeviceName: no name from scan/adv/cache, creating GattClient for ${device.getMac()}`);
    let gattClient: ble.GattClientDevice | null = null;
    try {
      gattClient = ble.createGattClientDevice(device.getMac());
      deviceName = await gattClient.getDeviceName();
      BleUtils.log(hilog.LogLevel.DEBUG,
        `resolveDeviceName: gattClient.getDeviceName() returned '${deviceName}' for ${device.getMac()}`);
    } catch (e) {
      BleUtils.log(hilog.LogLevel.WARN,
        `resolveDeviceName: gattClient.getDeviceName() failed for ${device.getMac()}: ${JSON.stringify(e)}`);
      deviceName = '';
    } finally {
      if (gattClient != null) {
        try {
          gattClient.close();
        } catch (closeErr) {
          BleUtils.log(hilog.LogLevel.WARN,
            `resolveDeviceName: failed to close gattClient for ${device.getMac()}: ${JSON.stringify(closeErr)}`);
        }
      }
    }
    // 缓存本次解析结果（含空串），后续该设备广播直接复用，不再创建 GattClientDevice。
    this.nameSeenMap.set(device.getMac(), deviceName);
    return deviceName;
  }

  /**
   * 组装单个设备的 BmScanAdvertisement Map（manufacturer_data/platform_name/remote_id 等）。
   * 制造商数据由 buildManufacturerData 构造，其余广播字段由 applyAdvFields 填充。
   * @param device - 已设置名称的 BleDevice
   * @param advDataSource - 已解析的广播数据
   * @param scanData - 原始扫描字节数组
   * @returns 广告数据 Map
   */
  private buildScanAdvMap(device: BleDevice, advDataSource: AdvData, scanData: Uint8Array): Map<string, ScanAdvValue> {
    let map: Map<string, ScanAdvValue> = new Map();
    map.set('manufacturer_data', this.buildManufacturerData(scanData));
    this.applyAdvFields(map, device, advDataSource);
    return map;
  }

  /**
   * 从原始扫描字节构造制造商数据 Map（manufacturerId -> payload）。
   * manufacturerId 为小端 16-bit: 低字节在前, 高字节左移 8 位拼接。
   * @param scanData - 原始扫描字节数组
   * @returns manufacturerId -> payload（无 MSD 时为空 Map）
   */
  private buildManufacturerData(scanData: Uint8Array): Map<number, Uint8Array> {
    let manufDataB: Map<number, Uint8Array> = new Map<number, Uint8Array>();
    let rawMsd: Uint8Array = BleAdvParser.getManufacturerSpecificData(scanData);
    if (rawMsd != null && rawMsd.length >= 2) {
      let manufacturerId = (rawMsd[0] & 0xFF) | ((rawMsd[1] & 0xFF) << 8);
      let payloadLen: number = rawMsd.length - 2;
      let payload: Uint8Array = new Uint8Array(payloadLen);
      for (let i = 0; i < payloadLen; i++) {
        payload[i] = rawMsd[i + 2];
      }
      manufDataB.set(manufacturerId, payload);
    }
    return manufDataB;
  }

  /**
   * 将设备信息与已解析的广播字段填入广告 Map。
   * platform_name/remote_id/connectable/rssi 来自设备，adv_name/tx_power_level/appearance/
   * service_uuids/service_data 来自广播解析结果。
   * @param map - 待填充的广告 Map
   * @param device - 已设置名称的 BleDevice
   * @param advDataSource - 已解析的广播数据
   */
  private applyAdvFields(map: Map<string, ScanAdvValue>, device: BleDevice, advDataSource: AdvData): void {
    if (device.getName() != null) {
      map.set('platform_name', device.getName());
    } else {
      map.set('platform_name', '');
    }
    if (device.getMac() != null) {
      map.set('remote_id', device.getMac());
    }
    if (device.getConnectable()) {
      map.set('connectable', device.getConnectable());
    }
    if (device.getRssi() != 0) {
      map.set('rssi', device.getRssi());
    }
    if (advDataSource.localName != null) {
      map.set('adv_name', advDataSource.localName);
    }
    const min: number = -2147483648;
    if (advDataSource.txPowerLevel != null && advDataSource.txPowerLevel != min) {
      map.set('tx_power_level', advDataSource.txPowerLevel);
    }
    if (advDataSource.appearance != null && advDataSource.appearance != 0) {
      map.set('appearance', advDataSource.appearance);
    }
    if (advDataSource.serviceUUIDs != null && advDataSource.serviceUUIDs.length > 0) {
      let serviceUuidsList: List<string> = new List<string>();
      for (let uuid of advDataSource.serviceUUIDs) {
        serviceUuidsList.add(uuid);
      }
      map.set('service_uuids', serviceUuidsList);
    }
    if (advDataSource.serviceData != null && advDataSource.serviceData.size > 0) {
      map.set('service_data', this.buildServiceDataMap(advDataSource.serviceData));
    }
  }

  /**
   * 将广播中的服务数据（UUID -> hex payload 字符串）转为 UUID -> Uint8Array。
   * @param serviceData - 原始服务数据（hex 字符串值）
   * @returns UUID -> 字节数组
   */
  private buildServiceDataMap(serviceData: Map<string, string>): Map<string, Uint8Array> {
    let serviceDataMap: Map<string, Uint8Array> = new Map<string, Uint8Array>();
    serviceData.forEach((hexValue, uuid) => {
      let byteArray: number[] = [];
      for (let i = 0; i < hexValue.length; i += 2) {
        if (i + 2 <= hexValue.length) {
          let byte = Number.parseInt(hexValue.substring(i, i + 2), 16);
          byteArray.push(byte);
        }
      }
      serviceDataMap.set(uuid, new Uint8Array(byteArray));
    });
    return serviceDataMap;
  }

  /**
   * 递增指定设备的扫描计数（用于连续模式降频）。
   * @param remoteId - 设备 ID
   * @returns 递增前的计数
   */
  scanCountIncrement(remoteId: string): number {
    if (this.scanCountsMap.get(remoteId) == null) {
      this.scanCountsMap.set(remoteId, 0);
    }
    let count: number = this.scanCountsMap.get(remoteId) as number;
    this.scanCountsMap.set(remoteId, count + 1);
    return count;
  }

  /**
   * 关键词过滤：任一关键词被设备名包含即通过；关键词列表为空时无条件通过。
   * @param keywords - 关键词列表
   * @param target - 设备名
   * @returns 是否通过过滤
   */
  filterKeywords(keywords: List<string>, target: string): boolean {
    // 先判 null 再访问 length：keywords 为 null/undefined（Dart 未传 with_keywords）时直接放行，
    // 否则 ArkTS 严格模式下访问 undefined.length 会抛异常。
    if (keywords == null || keywords.length == 0) {
      return true;
    }
    if (target == null) {
      return false;
    }
    for (let i = 0; i < keywords.length; i++) {
      if (target.includes(keywords[i])) {
        return true;
      }
    }
    return false;
  }
}
