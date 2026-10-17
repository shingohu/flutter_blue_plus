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

import { ble } from '@kit.ConnectivityKit';
import { List } from '@kit.ArkTS';
import { MethodResult } from '@ohos/flutter_ohos';
import { deviceInfo } from '@kit.BasicServicesKit';
import BleUtils from './BleUtils';
import { GattSession } from './GattCacheHolder';

/** locateCharacteristic 查找结果。 */
export class ChrFound {
  public characteristic: ble.BLECharacteristic | null = null;
  public error: string | null = null;

  constructor(characteristic: ble.BLECharacteristic | null, error: string | null) {
    this.characteristic = characteristic;
    this.error = error;
  }
}

/**
 * GATT 写操作的设备/特征身份标识（remoteId + 4 个 UUID/instanceId 定位字段）。
 *
 * 抽成独立值对象，使 {@link GattWriteContext} 构造参数收敛到 ≤5 个；
 * 同时作为 executeWriteCharacteristic / writeNotifyDescriptor / executeWriteDescriptor
 * 构建「写入缓存键」的统一数据源。
 */
export class GattWriteTarget {
  /** 设备 ID（remoteId）。 */
  public remoteId: string;
  /** 主服务 UUID（次服务时为 null/空）。 */
  public primaryServiceUuid: string;
  /** 特征所属服务 UUID。 */
  public serviceUuid: string;
  /** 特征 UUID。 */
  public characteristicUuid: string;
  /** 特征 instanceId。 */
  public instanceId: number;

  constructor(remoteId: string, primaryServiceUuid: string, serviceUuid: string,
    characteristicUuid: string, instanceId: number) {
    this.remoteId = remoteId;
    this.primaryServiceUuid = primaryServiceUuid;
    this.serviceUuid = serviceUuid;
    this.characteristicUuid = characteristicUuid;
    this.instanceId = instanceId;
  }
}

/**
 * GATT 写操作上下文。
 *
 * 封装 executeWriteCharacteristic / writeNotifyDescriptor / executeWriteDescriptor 三个写方法
 * 共享的「定位 + 回传」所需信息（gatt 实例、目标特征、服务树、result 回调，
 * 外加 target 身份），将原 11~12 个参数收敛为单个 ctx，且构造参数 ≤5
 * （身份字段经 target 摊平为 ctx.* 直属字段，保持调用方访问不变）。
 */
export class GattWriteContext {
  public session: GattSession;
  public servicesRevision: number;
  /** 目标设备的 GattClientDevice。 */
  public gatt: ble.GattClientDevice;
  /** 目标特征。 */
  public characteristic: ble.BLECharacteristic;
  /** 已发现的服务树（用于回传时定位 primary service）。 */
  public gattServices: ble.GattService[];
  /** 设备 ID（remoteId）。 */
  public remoteId: string;
  /** 主服务 UUID（次服务时为 null/空）。 */
  public primaryServiceUuid: string;
  /** 特征所属服务 UUID。 */
  public serviceUuid: string;
  /** 特征 UUID。 */
  public characteristicUuid: string;
  /** 特征 instanceId。 */
  public instanceId: number;
  /** 结果回调。 */
  public result: MethodResult;

  constructor(gatt: ble.GattClientDevice, characteristic: ble.BLECharacteristic,
    gattServices: ble.GattService[], target: GattWriteTarget, result: MethodResult, session: GattSession) {
    this.session = session;
    this.servicesRevision = session.servicesRevision;
    this.gatt = gatt;
    this.characteristic = characteristic;
    this.gattServices = gattServices;
    this.remoteId = target.remoteId;
    this.primaryServiceUuid = target.primaryServiceUuid;
    this.serviceUuid = target.serviceUuid;
    this.characteristicUuid = target.characteristicUuid;
    this.instanceId = target.instanceId;
    this.result = result;
  }
}

/**
 * GATT 服务树查找工具集（横切关注点，无实例状态）。
 *
 * 从 BleGattManager 剥离的纯静态工具方法：getInstanceId（实例 ID 计算）、getPrimaryService
 * （主服务回溯）、locateCharacteristic（定位特征）及其子 helper getServiceFromArray /
 * getCharacteristicFromArray、getDescriptorFromArray / getReadDescriptorFromArray。
 *
 * 这些方法被 GATT 的 Characteristic/Descriptor/Notify/服务发现等多个功能组共用，
 * 且只依赖入参与 BleUtils / deviceInfo（无 plugin/缓存字段依赖），故抽为独立工具类，
 * 各 Manager 直接以 BleGattShared.xxx(...) 调用，避免子 Manager 间互相持有引用。
 */
export default class BleGattShared {
  /**
   * 计算特征在所属服务中的实例 ID（用于区分同 UUID 多特征）。
   * API>=18 对重复 UUID 使用 characteristicValueHandle；否则仅接受可证明的对象身份。
   * 跨所有同 UUID 服务计算重复实例，唯一实例返回 0。
   * @param target - 目标特征
   * @param services - GATT 服务数组
   * @returns 实例 ID
   */
  static getInstanceId(target: ble.BLECharacteristic, services: ble.GattService[]): number {
    const primary = BleGattShared.getPrimaryService(services, target);
    const matches = BleGattShared.matchingServices(primary?.serviceUuid ?? null, target.serviceUuid, services);
    let chars: ble.BLECharacteristic[] = [];
    for (const service of matches) {
      for (const c of service.characteristics) {
        if (BleUtils.uuid128(c.characteristicUuid) === BleUtils.uuid128(target.characteristicUuid)) chars.push(c);
      }
    }
    if (chars.length === 0) {
      // Service Changed must remain observable even before discovery includes
      // the Generic Attribute service. Other absent characteristics are stale.
      if (BleUtils.uuid128(target.serviceUuid) === BleUtils.uuid128('1801') &&
        BleUtils.uuid128(target.characteristicUuid) === BleUtils.uuid128('2a05')) return 0;
      throw new Error('Characteristic not in current services');
    }
    if (chars.length === 1 && deviceInfo.sdkApiVersion >= 18 &&
      target.characteristicValueHandle > 0 && chars[0].characteristicValueHandle > 0 &&
      target.characteristicValueHandle !== chars[0].characteristicValueHandle) {
      throw new Error('Obsolete characteristic handle');
    }
    if (chars.length <= 1) return 0;
    if (deviceInfo.sdkApiVersion >= 18 && target.characteristicValueHandle > 0) {
      if (!chars.some(c => c.characteristicValueHandle === target.characteristicValueHandle)) {
        throw new Error('Obsolete characteristic handle');
      }
      return target.characteristicValueHandle;
    }
    // Older APIs cannot distinguish cloned notifications for identical UUIDs.
    // Reference identity is safe during discovery; never guess from properties.
    const index = chars.indexOf(target);
    if (index < 0) throw new Error('Ambiguous characteristic: platform supplies no instance handle');
    return index + 1;
  }

  static matchingServices(primaryUuid: string | null, serviceUuid: string,
    services: ble.GattService[]): ble.GattService[] {
    const matches: ble.GattService[] = [];
    for (const root of services) {
      if (primaryUuid == null) {
        if (root.isPrimary && BleUtils.uuid128(root.serviceUuid) === BleUtils.uuid128(serviceUuid)) matches.push(root);
      } else if (BleUtils.uuid128(root.serviceUuid) === BleUtils.uuid128(primaryUuid)) {
        for (const included of root.includeServices ?? []) {
          if (BleUtils.uuid128(included.serviceUuid) === BleUtils.uuid128(serviceUuid) && matches.indexOf(included) < 0) {
            matches.push(included);
          }
        }
      }
    }
    return matches;
  }

  /**
   * 在服务数组中查找特征所属的主服务（针对次级服务回溯 includeServices）。
   * @param services - GATT 服务数组
   * @param characteristic - 目标特征
   * @returns 主服务；特征本身属于主服务或未找到时返回 null
   */
  static getPrimaryService(services: ble.GattService[],
    characteristic: ble.BLECharacteristic): ble.GattService | null {
    for (const root of services) {
      if (!root.isPrimary) continue;
      for (const candidate of root.characteristics) {
        if (candidate === characteristic || (deviceInfo.sdkApiVersion >= 18 &&
          characteristic.characteristicValueHandle > 0 &&
          candidate.characteristicValueHandle === characteristic.characteristicValueHandle)) return null;
      }
    }
    for (const root of services) {
      for (const included of root.includeServices ?? []) {
        for (const candidate of included.characteristics) {
          if (candidate === characteristic || (deviceInfo.sdkApiVersion >= 18 &&
            characteristic.characteristicValueHandle > 0 &&
            candidate.characteristicValueHandle === characteristic.characteristicValueHandle)) return root;
        }
      }
    }
    // UUID-only callbacks must consider primary and included candidates alike.
    // A unique included owner is not proof if a primary service also matches.
    let owner: ble.GattService | null = null;
    let found: boolean = false;
    const serviceUuid = BleUtils.uuid128(characteristic.serviceUuid);
    const charUuid = BleUtils.uuid128(characteristic.characteristicUuid);
    for (const root of services) {
      if (root.isPrimary && BleUtils.uuid128(root.serviceUuid) === serviceUuid &&
        root.characteristics.some(c => BleUtils.uuid128(c.characteristicUuid) === charUuid)) {
        if (found && owner !== null) throw new Error('Ambiguous service owner');
        found = true;
        owner = null;
      }
      for (const included of root.includeServices ?? []) {
        if (BleUtils.uuid128(included.serviceUuid) === serviceUuid &&
          included.characteristics.some(c => BleUtils.uuid128(c.characteristicUuid) === charUuid)) {
          if (found && owner !== root) throw new Error('Ambiguous service owner');
          found = true;
          owner = root;
        }
      }
    }
    return owner;
  }

  /**
   * 在服务数组中按 UUID 查找服务（UUID 规范化为 128-bit 比较）。
   * @param uuid - 目标服务 UUID
   * @param array - 服务数组
   * @returns 匹配的服务；未找到返回 null
   */
  static getServiceFromArray(uuid: string, array: ble.GattService[]): ble.GattService | null {
    for (let i = 0; i < array.length; i++) {
      if (BleUtils.uuid128(uuid) === BleUtils.uuid128(array[i].serviceUuid)) {
        return array[i];
      }
    }
    return null;
  }

  /**
   * 在特征数组中按 UUID+实例 ID 查找特征。
   * 同 UUID 多特征时按 instanceId 精确匹配，否则返回首个。
   * @param uuid - 目标特征 UUID
   * @param array - 特征数组
   * @param services - GATT 服务数组（用于计算实例 ID）
   * @param instanceId - 实例 ID
   * @returns 匹配的特征；未找到返回 null
   */
  static getCharacteristicFromArray(uuid: string, array: ble.BLECharacteristic[],
    services: ble.GattService[], instanceId: number): ble.BLECharacteristic | null {
    const targetUuid = BleUtils.uuid128(uuid);
    for (const characteristic of array) {
      if (BleUtils.uuid128(characteristic.characteristicUuid) === targetUuid &&
        BleGattShared.getInstanceId(characteristic, services) === instanceId) return characteristic;
    }
    return null;
  }

  /**
   * 定位特征：按主服务/次服务/特征 UUID/实例 ID 在服务树中查找。
   * @param primaryServiceUuid - 主服务 UUID（可空）
   * @param serviceUuid - 服务 UUID
   * @param characteristicUuid - 特征 UUID
   * @param instanceId - 实例 ID
   * @param gattServices - GATT 服务数组
   * @returns ChrFound（含特征或错误信息）
   */
  static async locateCharacteristic(primaryServiceUuid: string, serviceUuid: string,
    characteristicUuid: string, instanceId: number,
    gattServices: ble.GattService[]): Promise<ChrFound | undefined> {
    const services = BleGattShared.matchingServices(primaryServiceUuid ?? null, serviceUuid, gattServices);
    const characteristics: ble.BLECharacteristic[] = [];
    for (const service of services) {
      for (const characteristic of service.characteristics) characteristics.push(characteristic);
    }
    const characteristic = BleGattShared.getCharacteristicFromArray(characteristicUuid,
      characteristics, gattServices, instanceId);
    if (characteristic == null) return new ChrFound(null, 'characteristic instance not found');
    return new ChrFound(characteristic, null);
  }

  /**
   * 查找描述符数组中匹配 UUID 的描述符（UUID 先规范化为 128-bit 比较）。
   * @param uuid - 目标描述符 UUID
   * @param array - 描述符数组
   * @returns 匹配的描述符；未找到返回 null
   */
  static getDescriptorFromArray(uuid: string, array: ble.BLEDescriptor[]): ble.BLEDescriptor | null {
    for (let i = 0; i < array.length; i++) {
      if (BleUtils.uuid128(array[i].descriptorUuid) === BleUtils.uuid128(uuid)) {
        return array[i];
      }
    }
    return null;
  }

  /**
   * 查找描述符数组中匹配 UUID 的描述符（读取场景使用，行为同 getDescriptorFromArray）。
   * @param uuid - 目标描述符 UUID
   * @param array - 描述符数组
   * @returns 匹配的描述符；未找到返回 null
   */
  static getReadDescriptorFromArray(uuid: string, array: ble.BLEDescriptor[]): ble.BLEDescriptor | null {
    for (let i = 0; i < array.length; i++) {
      if (BleUtils.uuid128(array[i].descriptorUuid) === BleUtils.uuid128(uuid)) {
        return array[i];
      }
    }
    return null;
  }

  /**
   * 计算指定写入类型下的最大负载长度（MTU-3 或 512）。
   * @param mtuMap - MTU 缓存（设备 -> MTU）
   * @param remoteId - 设备 ID
   * @param writeType - 写入类型
   * @param allowLongWrite - 是否允许长写入
   * @returns 最大负载字节数
   */
  static getMaxPayload(mtuMap: Map<string, number>, remoteId: string,
    writeType: number, allowLongWrite: boolean): number {
    let maxAttrLen: number = 512;
    // if no response, we can only write up to MTU-3.
    if (writeType == ble.GattWriteType.WRITE_NO_RESPONSE || allowLongWrite == false) {
      let mtu: number = mtuMap.get(remoteId) as number;
      if (mtu == null) {
        mtu = 23;
      }
      return Math.min(mtu - 3, maxAttrLen);
    } else {
      return maxAttrLen;
    }
  }

  /**
   * 构造 BmBluetoothService Map（remote_id/primary_service_uuid/service_uuid/characteristics）。
   * @param service - GATT 服务
   * @param primaryService - 关联主服务（次级服务时传入）
   * @param remoteId - 设备 ID
   * @param gattServices - GATT 服务数组（用于实例 ID 计算）
   * @returns BmBluetoothService Map
   */
  static bmBluetoothService(service: ble.GattService, primaryService: ble.GattService | null, remoteId: string,
    gattServices: ble.GattService[]): Map<string, object | string | number> {
    let characteristics: List<object> = new List<object>();
    service.characteristics.forEach((characteristic) => {
      characteristics.add(BleGattShared.bmBluetoothCharacteristic(remoteId, characteristic, gattServices));
    });
    let map: Map<string, object | string | number> = new Map();
    map.set('remote_id', remoteId);
    if (primaryService != null) {
      map.set('primary_service_uuid', BleUtils.uuidStr(primaryService.serviceUuid));
    }
    map.set('service_uuid', BleUtils.uuidStr(service.serviceUuid));
    map.set('characteristics', characteristics);
    return map;
  }

  /**
   * 构造 BmBluetoothCharacteristic Map。
   * @param remoteId - 设备 ID
   * @param characteristic - BLE 特征
   * @param gattServices - GATT 服务数组（用于实例 ID 计算）
   * @returns BmBluetoothCharacteristic Map
   */
  static bmBluetoothCharacteristic(remoteId: string, characteristic: ble.BLECharacteristic,
    gattServices: ble.GattService[]): Map<string, object | string | number> {
    let descriptors: List<object> = new List<object>();
    characteristic.descriptors?.forEach((d) => {
      descriptors.add(BleGattShared.bmBluetoothDescriptor(remoteId, characteristic, d, gattServices));
    });
    let primaryService: ble.GattService | null = null;
    if (gattServices) {
      primaryService = BleGattShared.getPrimaryService(gattServices, characteristic);
    }
    let map: Map<string, object | string | number> = new Map<string, object | string | number>();
    map.set('remote_id', remoteId);
    if (primaryService != null) {
      map.set('primary_service_uuid', BleUtils.uuidStr(primaryService.serviceUuid));
    }
    map.set('service_uuid', BleUtils.uuidStr(characteristic.serviceUuid));
    map.set('characteristic_uuid', BleUtils.uuidStr(characteristic.characteristicUuid));
    let instanceId: number = 0;
    if (gattServices) {
      instanceId = BleGattShared.getInstanceId(characteristic, gattServices);
    }
    map.set('instance_id', instanceId);
    map.set('descriptors', descriptors);
    map.set('properties', BleGattShared.bmCharacteristicProperties(characteristic));
    return map;
  }

  /**
   * 构造特征属性 Map（read/write/notify/indicate 等布尔转 0/1）。
   * OHOS 不支持的字段（broadcast/authenticated_signed_writes 等）固定 0。
   * @param characteristic - BLE 特征
   * @returns 属性 Map
   */
  static bmCharacteristicProperties(characteristic: ble.BLECharacteristic): Map<string, number> {
    let props: Map<string, number> = new Map<string, number>();
    if (characteristic.properties) {
      characteristic.properties.write ? props.set('write', 1) : props.set('write', 0);
      characteristic.properties.writeNoResponse ? props.set('write_without_response', 1) :
        props.set('write_without_response', 0);
      characteristic.properties.read ? props.set('read', 1) : props.set('read', 0);
      characteristic.properties.notify ? props.set('notify', 1) : props.set('notify', 0);
      characteristic.properties.indicate ? props.set('indicate', 1) : props.set('indicate', 0);
      props.set('broadcast', 0);
      props.set('authenticated_signed_writes', 0);
      props.set('extended_properties', 0);
      props.set('notify_encryption_required', 0);
      props.set('indicate_encryption_required', 0);
    }
    return props;
  }

  /**
   * 构造 BmBluetoothDescriptor Map。
   * @param remoteId - 设备 ID
   * @param characteristic - 所属特征
   * @param descriptor - BLE 描述符
   * @param gattServices - GATT 服务数组（用于实例 ID 计算）
   * @returns BmBluetoothDescriptor Map
   */
  static bmBluetoothDescriptor(remoteId: string, characteristic: ble.BLECharacteristic,
    descriptor: ble.BLEDescriptor,
    gattServices: ble.GattService[]): Map<string, object | string | number> {
    let primaryService: ble.GattService | null = BleGattShared.getPrimaryService(gattServices, characteristic);
    let map: Map<string, object | string | number> = new Map<string, object | string | number>();
    map.set('remote_id', remoteId);
    if (primaryService != null) {
      map.set('primary_service_uuid', BleUtils.uuidStr(primaryService.serviceUuid));
    }
    map.set('descriptor_uuid', BleUtils.uuidStr(descriptor.descriptorUuid));
    map.set('characteristic_uuid', BleUtils.uuidStr(descriptor.characteristicUuid));
    map.set('service_uuid', BleUtils.uuidStr(descriptor.serviceUuid));
    let instanceId = BleGattShared.getInstanceId(characteristic!, gattServices);
    map.set('instance_id', instanceId);
    return map;
  }
}
