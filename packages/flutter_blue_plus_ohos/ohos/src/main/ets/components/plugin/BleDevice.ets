/*
 * Copyright (C) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
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

/** BleDevice 构造配置（参数对象，替代多位置参数）。 */
export interface BleDeviceConfig {
  /** 设备 ID（MAC），必填。 */
  deviceId: string;
  /** 设备名（初始可为空串，后续 setName 回填），必填。 */
  name: string;
  /** RSSI 值（可选）。 */
  rssi?: number;
  /** 原始广播字节数组（可选）。 */
  scanRecord?: Uint8Array;
  /** 扫描时间戳（毫秒，可选）。 */
  timestampNanos?: number;
  /** 是否可连接（可选）。 */
  connectable?: boolean;
}

/**
 * 扫描设备数据类。
 *
 * 承载一次 BLE 扫描发现的设备信息：设备名、deviceId（MAC）、原始广播字节、
 * RSSI、时间戳与可连接性。由 BleScanManager.scanCallback 构造，
 * 名称在解析广播/读取设备名后通过 setName 回填。
 */
export default class BleDevice {
  /** 设备名（解析广播 localName 或读取 GAP 0x2A00 得到，可能为空串）。 */
  deviceName: string = '';
  /** 设备 ID（即 MAC 地址），同时作为 remoteId。 */
  deviceId: string = '';
  /** 原始广播/扫描响应字节数组。 */
  scanRecord: Uint8Array = new Uint8Array();
  /** 本次扫描的 RSSI 值。 */
  rssi: number = 0;
  /** 扫描时间戳（毫秒）。 */
  timestampNanos: number = 0;
  /** 设备是否可连接。 */
  connectable: boolean = false;

  /**
   * 构造扫描设备数据。
   * @param config - 设备配置（deviceId/name 必填，其余可选）
   */
  public constructor(config: BleDeviceConfig) {
    this.deviceName = config.name;
    this.deviceId = config.deviceId;
    if (config.connectable != undefined) {
      this.connectable = config.connectable;
    }
    if (config.scanRecord) {
      this.scanRecord = config.scanRecord;
    }
    if (config.rssi) {
      this.rssi = config.rssi;
    }
    if (config.timestampNanos) {
      this.timestampNanos = config.timestampNanos;
    }
  }

  /**
   * 复制一个设备数据实例（仅复制 deviceId/name/rssi/scanRecord/timestampNanos，不含 connectable）。
   * @param device - 源设备
   * @returns 新的 BleDevice 实例
   */
  public static copy(device: BleDevice): BleDevice {
    return new BleDevice({
      deviceId: device.deviceId,
      name: device.deviceName,
      rssi: device.rssi,
      scanRecord: device.scanRecord,
      timestampNanos: device.timestampNanos,
    });
  }

  /**
   * 获取设备名。
   * @returns 设备名（可能为空串）
   */
  public getName(): string {
    return this.deviceName;
  }

  /**
   * 设置设备名（解析广播/读取设备名后回填）。
   * @param name - 设备名
   */
  public setName(name: string): void {
    this.deviceName = name;
  }

  /**
   * 获取 MAC 地址（同 deviceId）。
   * @returns 设备 ID / MAC 地址
   */
  public getMac(): string {
    return this.deviceId;
  }

  /**
   * 生成去重键（设备名 + deviceId），用于重复广播抑制。
   * @returns 名称与 ID 拼接的键；两者之一为空时返回空串
   */
  public getKey(): string {
    if (this.deviceName != null && this.deviceId != null) {
      // 名称 + ID 拼接作为去重键：重复广播据此合并，避免同一设备被多次上报
      return this.deviceName + this.deviceId;
    }
    // 名称或 ID 缺失时无法构成稳定去重键，返回空串让调用方跳过去重
    return '';
  }

  /**
   * 获取是否可连接。
   * @returns 是否可连接
   */
  public getConnectable(): boolean {
    return this.connectable;
  }

  /**
   * 设置是否可连接。
   * @param connectable - 是否可连接
   */
  public setConnectable(connectable: boolean) {
    this.connectable = connectable;
  }

  /**
   * 获取原始广播字节数组。
   * @returns 原始广播字节数组
   */
  public getScanRecord(): Uint8Array {
    return this.scanRecord;
  }

  /**
   * 设置原始广播字节数组。
   * @param scanRecord - 原始广播字节数组
   */
  public setScanRecord(scanRecord: Uint8Array) {
    this.scanRecord = scanRecord;
  }

  /**
   * 获取 RSSI 值。
   * @returns RSSI 值（dBm）
   */
  public getRssi(): number {
    return this.rssi;
  }

  /**
   * 设置 RSSI 值。
   * @param rssi - RSSI 值
   */
  public setRssi(rssi: number) {
    this.rssi = rssi;
  }

  /**
   * 获取扫描时间戳（毫秒）。
   * @returns 扫描时间戳（毫秒）
   */
  public getTimestampNanos(): number {
    return this.timestampNanos;
  }

  /**
   * 设置扫描时间戳（毫秒）。
   * @param timestampNanos - 扫描时间戳（毫秒）
   */
  public setTimestampNanos(timestampNanos: number) {
    this.timestampNanos = timestampNanos;
  }
}
