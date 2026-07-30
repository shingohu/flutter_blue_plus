/*
 * Copyright (C) 2024 Huawei Device Co., Ltd.
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

export default class BleDevice {
  mDeviceName: string = '';
  mDeviceId: string = '';
  mScanRecord: Uint8Array = new Uint8Array();
  mRssi: number = 0;
  mTimestampNanos: number = 0;
  connectable: boolean = false;

  public constructor(deviceId: string, name: string, rssi?: number, scanRecord ?: Uint8Array, timestampNanos ?: number,
    connectable?: boolean) {
    this.mDeviceName = name;
    this.mDeviceId = deviceId;
    if (connectable != undefined) {
      this.connectable = connectable;
    }
    if (scanRecord) {
      this.mScanRecord = scanRecord;
    }
    if (rssi) {
      this.mRssi = rssi;
    }
    if (timestampNanos) {
      this.mTimestampNanos = timestampNanos;
    }
  }

  public static copy(device: BleDevice): BleDevice {
    return new BleDevice(device.mDeviceId, device.mDeviceName, device.mRssi, device.mScanRecord,
      device.mTimestampNanos);
  }

  public getName(): string {
    return this.mDeviceName;
  }

  public setName(name: string): void {
    this.mDeviceName = name;
  }

  public getMac(): string {
    return this.mDeviceId;
  }

  public getKey(): string {
    if (this.mDeviceName != null && this.mDeviceId != null) {
      return this.mDeviceName + this.mDeviceId;
    }
    return "";
  }

  public getConnectable(): boolean {
    return this.connectable;
  }

  public setConnectable(connectable: boolean) {
    this.connectable = connectable;
  }

  public getScanRecord(): Uint8Array {
    return this.mScanRecord;
  }

  public setScanRecord(scanRecord: Uint8Array) {
    this.mScanRecord = scanRecord;
  }

  public getRssi(): number {
    return this.mRssi;
  }

  public setRssi(rssi: number) {
    this.mRssi = rssi;
  }

  public getTimestampNanos(): number {
    return this.mTimestampNanos;
  }

  public setTimestampNanos(timestampNanos: number) {
    this.mTimestampNanos = timestampNanos;
  }
}