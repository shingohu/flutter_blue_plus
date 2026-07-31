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
import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
  AbilityPluginBinding,
} from '@ohos/flutter_ohos';
import { ble, connection, constant } from '@kit.ConnectivityKit';
import { buffer, HashMap, List } from '@kit.ArkTS';
import { abilityAccessCtrl, bundleManager, Permissions, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import access from '@ohos.bluetooth.access';
import BleDevice from './BleDevice'
import HexUtil from './HexUtil'
import TextUtils from "./TextUtils"
import BinaryProtocolHandler from './BinaryProtocolHandler'
import { deviceInfo } from '@kit.BasicServicesKit';
import { geoLocationManager } from '@kit.LocationKit';

const CCCD: string = "2902";
const TAG = "[FBP-Ohos]";
const DOMAIN: number = 0x00FF;

/** FlutterBluePlusPlugin **/
export default class FlutterBluePlusOhosPlugin implements FlutterPlugin, MethodCallHandler {
  public readonly ENABLE_NOTIFICATION_VALUE: Uint8Array = new Uint8Array([0x01, 0x00]);
  public readonly ENABLE_INDICATION_VALUE: Uint8Array = new Uint8Array([0x02, 0x00]);
  public readonly DISABLE_NOTIFICATION_VALUE: Uint8Array = new Uint8Array([0x00, 0x00]);
  private channel: MethodChannel | null = null;
  private binaryHandler: BinaryProtocolHandler | null = null;
  private context: common.Context | null = null;
  private mConnectedDevices: Map<string, ble.GattClientDevice> = new Map<string, ble.GattClientDevice>();
  private mCurrentlyConnectingDevices: Map<string, ble.GattClientDevice> = new Map();
  private mBondingDevices: Map<string, ble.GattClientDevice> = new Map();
  private mBondingPins: Map<string, Uint8Array> = new Map();
  private mMtu: Map<string, number> = new Map();
  private mAutoConnected: Map<string, ble.GattClientDevice> = new Map();
  private mWriteChr: Map<string, Uint8Array> = new Map();
  private mWriteDesc: Map<string, Uint8Array> = new Map();
  private loglevel: hilog.LogLevel = hilog.LogLevel.DEBUG;
  private mIsScanning: boolean = false;
  private clientDevice: ble.GattClientDevice | null = null;
  private remoteId: string | null = null
  private mScanFilters: Map<string, Object> = new Map();
  private mAdvSeen: Map<string, string> = new Map();
  private mScanCounts: Map<string, number> = new Map();
  private static readonly ACCESS_BLUETOOTH_PERMISSION: Permissions = "ohos.permission.ACCESS_BLUETOOTH";

  getUniqueClassName(): string {
    return "FlutterBluePlusOhosPlugin"
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), "flutter_blue_plus/methods");
    this.channel.setMethodCallHandler(this);
    this.binaryHandler = new BinaryProtocolHandler();
    this.binaryHandler.register(binding, this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.binaryHandler != null) {
      this.binaryHandler.unregister();
      this.binaryHandler = null;
    }
    if (this.channel != null) {
      this.channel.setMethodCallHandler(null)
    }
    try {
      connection.off("bondStateChange")
      access.off("stateChange")
      ble.off("BLEDeviceFind")
    } catch (e) {
      this.log(hilog.LogLevel.ERROR, "onDetachedFromEngine: Failed to remove event listeners: " + JSON.stringify(e));
    }
  }

  onAttachedToAbility(binding: AbilityPluginBinding) {
    connection.on('bondStateChange', (data: connection.BondStateParam) => {
      let gatt: ble.GattClientDevice = ble.createGattClientDevice(data.deviceId);
      if (data.state == connection.BondState.BOND_STATE_BONDING) {
        this.mBondingDevices.set(data.deviceId, gatt);
      } else {
        this.mBondingDevices.delete(data.deviceId);
      }
      let map: Map<string, string | number | null> = new Map();
      map.set("remote_id", data.deviceId);
      map.set("bond_state", this.bmBondStateEnum(data.state));
      map.set("prev_state", null);
      this.channel?.invokeMethod("OnBondStateChanged", map)
    });
    this.context = binding.getAbility().context;
  }

  async onMethodCall(call: MethodCall, result: MethodResult): Promise<void> {
    try {
      switch (call.method) {
        case "flutterRestart": {
          result.success(this.mConnectedDevices.size)
          try {
            this.log(hilog.LogLevel.DEBUG, "flutterRestart: calling stopScan");
            ble.stopBLEScan()
          } catch (e) {
            this.log(hilog.LogLevel.ERROR, "flutterRestart: Failed to stop scan: " + JSON.stringify(e));
          }
          access.on('stateChange', (data: access.BluetoothState) => {
            this.onReceiveEvent(data)
          });
          this.disconnectAllDevices("flutterRestart");
          break;
        }
        case "connectedCount": {
          this.log(hilog.LogLevel.DEBUG, "connectedPeripherals count: " + this.mConnectedDevices.size);
          if (this.mConnectedDevices.size == 0) {
            this.log(hilog.LogLevel.DEBUG, "connectedPeripherals: Hot Restart complete, no devices connected");
          }
          result.success(this.mConnectedDevices.size);
          break;
        }
        case "setOptions": {
          result.success(this.mConnectedDevices);
          break;
        }
        case "getAdapterState": {
          let accessNum: number = -1;
          try {
            accessNum = access.getState();
          } catch (e) {
            this.log(hilog.LogLevel.ERROR, "getAdapterState: Failed to get adapter state: " + JSON.stringify(e));
          }
          let map: Map<string, number> = new Map();
          map.set("adapter_state", this.bmAdapterStateEnum(accessNum))
          result.success(map);
          break;
        }

        case "isSupported": {
          let isSupported: boolean = true;
          try {
            access.getState();
          } catch (e) {
            isSupported = false;
          }
          let map: Map<string, number> = new Map();
          map.set("is_supported", isSupported ? 1 : 0);
          result.success(map);
          break;
        }

        case "getSystemDevices": {
          if (!(await this.ensurePermissions(result, "getSystemDevices"))) {
            return;
          }
          try {
            let devices: Array<string> = ble.getConnectedBLEDevices();
            let devList: List<Map<string, string>> = new List<Map<string, string>>();
            devices.forEach(device => devList.add(this.bmBluetoothDevice(device)))
            let response: Map<string, object> = new Map();
            response.set("devices", devList);
            result.success(response);
          } catch (err) {
            this.log(hilog.LogLevel.ERROR, `getSystemDevices: failed to get connected BLE devices, errCode=${(err as BusinessError).code}, errMsg=${(err as BusinessError).message}`);
          }
          break;
        }
        case "turnOn": {
          if (!(await this.ensurePermissions(result, "turnOn"))) {
            return;
          }
          try {
            let state = access.getState();
            if (state == access.BluetoothState.STATE_OFF || state == access.BluetoothState.STATE_TURNING_OFF ||
              state == access.BluetoothState.STATE_BLE_TURNING_OFF) {
              const apiVersion: number = deviceInfo.sdkApiVersion;
              if (apiVersion >= 20) {
                access.enableBluetoothAsync().then(() => {
                  this.channel?.invokeMethod("OnTurnOnResponse", { user_accepted: true });
                }, (error: BusinessError) => {
                  if (error.code === 2900014) {
                    this.channel?.invokeMethod("OnTurnOnResponse", { user_accepted: false });
                  }
                });
                result.success(true);
              } else {
                try {
                  await access.enableBluetooth();
                  this.channel?.invokeMethod("OnTurnOnResponse", { user_accepted: true });
                  result.success(true);
                } catch (error) {
                  this.channel?.invokeMethod("OnTurnOnResponse", { user_accepted: false });
                  result.success(true);
                }
              }
            } else {
              this.channel?.invokeMethod("OnTurnOnResponse", { user_accepted: true });
              result.success(false);
            }
          } catch (e) {
            this.channel?.invokeMethod("OnTurnOnResponse", { user_accepted: false });
            result.success(true);
          }
          return;
        }
        case "turnOff": {
          if (!(await this.ensurePermissions(result, "turnOff"))) {
            return;
          }
          let state = access.getState()
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
          break;
        }
        case "startScan": {
          try {
            let data: Map<string, Object> = call.args;
            let withServices: List<string> = data.get("with_services") as List<string>;
            let withRemoteIds: List<string> = data.get("with_remote_ids") as List<string>;
            let withNames: List<string> = data.get("with_names") as List<string>;
            let withMsd: List<object> = data.get("with_msd") as List<object>;
            let withServiceData: List<object> = data.get("with_service_data") as List<object>;

            if (!await this.ensurePermissions(result, "startScan")) {
              return;
            }
            if (!this.isAdapterOn()) {
              return;
            }
            let filterArray: Array<ble.ScanFilter> = [];
            // services
            for (let i = 0; i < withServices.length; i++) {
              let filter: ble.ScanFilter = {
                serviceUuid: withServices[i]
              };
              filterArray.push(filter);
            }
            // remoteIds
            for (let i = 0; i < withRemoteIds.length; i++) {
              let filter: ble.ScanFilter = {
                deviceId: withRemoteIds[i]
              };
              filterArray.push(filter);
            }
            // names
            for (let i = 0; i < withNames.length; i++) {
              let filter: ble.ScanFilter = {
                name: withNames[i]
              };
              filterArray.push(filter);
            }
            // msd
            for (let i = 0; i < withMsd.length; i++) {
              let m: HashMap<string, Object> = withMsd.get(i) as HashMap<string, Object>;
              let id = m.get("manufacturer_id") as number;
              let data: Uint8Array = m.get("data") as Uint8Array;
              let mask: Uint8Array = m.get("mask") as Uint8Array;
              let manufactureData = data.buffer;
              let manufactureDataMask = mask.buffer;
              let filter: ble.ScanFilter = {
                manufactureId: id,
                manufactureData: manufactureData,
                manufactureDataMask: manufactureDataMask,
              };
              filterArray.push(filter);
            }
            // service data
            for (let i = 0; i < withServiceData.length; i++) {
              let m: HashMap<string, Object> = withServiceData.get(i) as HashMap<string, Object>;
              let serviceUUid: string = this.uuid128(m.get("service") as string);
              let mdata: Uint8Array = m.get("data") as Uint8Array;
              let mask: Uint8Array = m.get("mask") as Uint8Array;
              let serviceData = mdata.buffer;
              let serviceDataMask = mask.buffer;
              let filter: ble.ScanFilter = {
                serviceUuid: serviceUUid,
                serviceData: serviceData,
                serviceDataMask: serviceDataMask
              };
              filterArray.push(filter);
            }
            let scanOption: ble.ScanOptions = {
              dutyMode: ble.ScanDuty.SCAN_MODE_LOW_LATENCY,
              matchMode: ble.MatchMode.MATCH_MODE_STICKY,
              interval: 1000
            };
            ble.on("BLEDeviceFind", this.onScanResult);
            this.mScanFilters = data;
            // clear seen devices
            this.mAdvSeen.clear();
            this.mScanCounts.clear();
            if (filterArray.length == 0) {
              ble.startBLEScan(null, scanOption);
            } else {
              ble.startBLEScan(filterArray, scanOption);
            }
          } catch (err) {
            this.log(hilog.LogLevel.ERROR, "startScan: Failed to start BLE scan: " + JSON.stringify(err));
          }
          result.success(true)
          break;
        }
        case "setLogLevel": {
          let idx: number = call.args as number;
          switch (idx) {
            case 0:
              this.loglevel = hilog.LogLevel.FATAL + 1; // disable all logs
              break;
            case 1:
              this.loglevel = hilog.LogLevel.ERROR;
              break;
            case 2:
              this.loglevel = hilog.LogLevel.WARN;
              break;
            case 3:
              this.loglevel = hilog.LogLevel.INFO;
              break;
            case 4:
            case 5:
              this.loglevel = hilog.LogLevel.DEBUG;
              break;
            default:
              this.loglevel = hilog.LogLevel.DEBUG;
              break;
          }
          result.success(true);
          break;
        }
        case "stopScan": {
          ble.stopBLEScan();
          ble.off('BLEDeviceFind', this.onScanResult);
          result.success(true);
          break;
        }
        case "connect": {
          let args: Map<string, string | boolean> = call.args;
          let remoteId: string = args.get("remote_id") as string;
          this.remoteId = remoteId;
          let autoConnect: boolean = args.get("auto_connect") as boolean;
          if (!await this.ensurePermissions(result, "connect")) {
            return;
          }
          if (!this.isAdapterOn()) {
            this.log(hilog.LogLevel.ERROR, "connect failed for remoteId=" + remoteId + ": bluetooth adapter is turned off");
            result.error("connect", "bluetooth must be turned on", null);
            return;
          }
          if (this.mCurrentlyConnectingDevices.get(this.remoteId) != null) {
            this.log(hilog.LogLevel.DEBUG, "connect: already connecting to " + this.remoteId);
            result.success(true);
            return;
          }
          if (this.mConnectedDevices.get(this.remoteId) != null) {
            this.log(hilog.LogLevel.DEBUG, "connect: already connected to " + this.remoteId);
            result.success(false);
            return;
          }
          try {
            this.clientDevice = ble.createGattClientDevice(this.remoteId);
            this.clientDevice.connect();
            this.clientDevice.on('BLEConnectionStateChange', this.ConnectStateChanged);
          } catch (err) {
            this.log(hilog.LogLevel.ERROR, `connect: failed for remoteId=${this.remoteId}, errCode=${(err as BusinessError).code}, errMsg=${(err as BusinessError).message}`);
          }
          if (this.clientDevice != null) {
            this.mCurrentlyConnectingDevices.set(remoteId, this.clientDevice);
          } else {
            this.log(hilog.LogLevel.ERROR, `connect failed for remoteId=${remoteId}: ble.createGattClientDevice() returned null, check if bluetooth adapter is on`);
            result.error("connect", "getBluetoothLeScanner() is null. Is the Adapter on?", null);
            return;
          }
          if (autoConnect) {
            this.mAutoConnected.set(remoteId, this.clientDevice);
          } else {
            this.mAutoConnected.delete(remoteId);
          }
          result.success(true);
          break;
        }
        case "readRssi": {
          let remoteId: string = call.args;
          // check connection
          let gatt: ble.GattClientDevice | undefined = this.mConnectedDevices.get(remoteId);
          if (gatt == null || gatt == undefined) {
            this.log(hilog.LogLevel.ERROR, "readRssi failed for remoteId=" + remoteId + ": device is not connected");
            result.error("readRssi", "device is disconnected", null);
            break;
          }
          let readRssiFlag = true;
          let rssiValue: number = 0;
          let errcode: number = 0;
          let errMsg: string = "GATT_SUCCESS";
          try {
            rssiValue = await gatt.getRssiValue();
          } catch (e) {
            readRssiFlag = false
          }
          // read rssi
          if (rssiValue == 0 || rssiValue == null || rssiValue == undefined) {
            this.log(hilog.LogLevel.ERROR, "readRssi failed for remoteId=" + remoteId + ": gatt.getRssiValue() returned invalid value");
            result.error("readRssi", "gatt.readRemoteRssi() returned false", null);
            break;
          }
          result.success(true);
          let response: Map<String, Object> = new Map();
          response.set("remote_id", remoteId);
          response.set("rssi", rssiValue);
          response.set("success", readRssiFlag ? 1 : 0);
          response.set("error_code", errcode);
          response.set("error_string", errMsg);
          this.channel?.invokeMethod("OnReadRssi", response);
          break;
        }
        case "discoverServices": {
          let remoteId: string = call.args;

          // check connection
          let gatt: ble.GattClientDevice | undefined = this.mConnectedDevices.get(remoteId);
          if (gatt == null) {
            this.log(hilog.LogLevel.ERROR, "discoverServices failed for remoteId=" + remoteId + ": device is not connected");
            result.error("discoverServices", "device is disconnected", null);
            break;
          }

          // discover services
          let services: Array<ble.GattService> = await gatt.getServices();
          if (services == null || services.length == 0) {
            this.log(hilog.LogLevel.ERROR, "discoverServices failed for remoteId=" + remoteId + ": getServices() returned empty or null");
            result.error("discoverServices", "gatt.discoverServices() returned false", null);
            break;
          }
          this.OnDiscoveredServices(services, remoteId)
          result.success(true);
          break;
        }
        case "setNotifyValue": {
          let data: Map<string, Object> = call.args;
          let remoteId: string = data.get("remote_id") as string;
          let primaryServiceUuid: string = data.get("primary_service_uuid") as string;
          let serviceUuid: string = data.get("service_uuid") as string;
          let characteristicUuid: string = data.get("characteristic_uuid") as string;
          let instanceId = data.get("instance_id") as number;
          let forceIndications: string = data.get("force_indications") as string;
          let enable: boolean = data.get("enable") as boolean;
          let gatt: ble.GattClientDevice = this.mConnectedDevices.get(remoteId) as ble.GattClientDevice;
          if (gatt == null) {
            this.log(hilog.LogLevel.ERROR, "setNotifyValue failed for remoteId=" + remoteId + ": device is not connected");
            result.error("setNotifyValue", "device is disconnected", null);
            break;
          }
          let gattServices = await gatt.getServices();
          if (gattServices == null || gattServices == undefined) {
            this.log(hilog.LogLevel.ERROR, "setNotifyValue failed for remoteId=" + remoteId + ": no services discovered");
            result.error("setNotifyValue", "no service ", null);
          }
          let found =
            await this.locateCharacteristic(primaryServiceUuid, serviceUuid, characteristicUuid, instanceId,
              gattServices);
          if (found?.error != null) {
            this.log(hilog.LogLevel.ERROR, "setNotifyValue failed for remoteId=" + remoteId + ": " + found.error);
            result.error("setNotifyValue", found.error, null);
            break;
          }
          let characteristic: ble.BLECharacteristic = found?.characteristic as ble.BLECharacteristic;
          try {
            await gatt.setCharacteristicChangeNotification(characteristic, enable);
          } catch (e) {
            this.log(hilog.LogLevel.ERROR, `setNotifyValue: failed to set characteristic notification for remoteId=${remoteId}: ${JSON.stringify(e)}`);
          }
          let descriptor: ble.BLEDescriptor | null =
            this.getDescriptorFromArray(CCCD, characteristic.descriptors);
          if (descriptor == null) {
            let uuid: string = this.uuidStr(characteristic.serviceUuid);
            result.success(false);
            return;
          }
          let descriptorValue: Uint8Array | null = null;
          if (enable) {
            let canNotify: boolean = characteristic.properties?.notify as boolean
            let canIndicate: boolean = characteristic.properties?.indicate as boolean
            if (!canIndicate && !canNotify) {
              this.log(hilog.LogLevel.ERROR, `setNotifyValue failed for remoteId=${remoteId}: neither NOTIFY nor INDICATE properties are supported for chr=${characteristicUuid}`);
              result.error("setNotifyValue",
                "neither NOTIFY nor INDICATE properties are supported by this BLE characteristic", null);
              break;
            }
            if (forceIndications && !canIndicate) {
              this.log(hilog.LogLevel.ERROR, `setNotifyValue failed for remoteId=${remoteId}: INDICATE not supported for chr=${characteristicUuid}, force_indications requested`);
              result.error("setNotifyValue", "INDICATE not supported by this BLE characteristic", null);
              break;
            }
            if (canIndicate) {
              descriptorValue = this.ENABLE_INDICATION_VALUE;
            }
            if (canNotify) {
              descriptorValue = this.ENABLE_NOTIFICATION_VALUE;
            }
            if (forceIndications) {
              descriptorValue = this.ENABLE_INDICATION_VALUE;
            }
          } else {
            descriptorValue = this.DISABLE_NOTIFICATION_VALUE;
          }
          // remember the data we are writing
          if (primaryServiceUuid == null) {
            primaryServiceUuid = "";
          }
          let key: string = remoteId + ":" + primaryServiceUuid + ":" + serviceUuid + ":" +
            characteristicUuid + ":" + instanceId + ":" + CCCD;
          this.mWriteDesc.set(key, descriptorValue as Uint8Array);
          // write descriptor
          if (descriptorValue) {
            let u8Array: Uint8Array = new Uint8Array(descriptorValue)
            descriptor.descriptorValue = this.typedArrayToBuffer(u8Array)
          }
          gatt.writeDescriptorValue(descriptor).then((writeDescriptor) => {
            // has associated primary service?
            let primaryService = this.getPrimaryService(gattServices, characteristic);
            let respPrimaryServiceUuid: string = primaryService != null ? this.uuidStr(primaryService.serviceUuid) : "";
            let respServiceUuid: string = this.uuidStr(descriptor?.serviceUuid as string);
            let respCharacteristicUuid: string = this.uuidStr(descriptor?.characteristicUuid as string);
            let respInstanceId: number = FlutterBluePlusOhosPlugin.getInstanceId(characteristic, gattServices);
            let respDescriptorUuid: string = this.uuidStr(descriptor?.descriptorUuid as string);
            // what data did we write?
            let key1: string =
              `${remoteId}:${respPrimaryServiceUuid}:${respServiceUuid}:${respCharacteristicUuid}:${respInstanceId}:${respDescriptorUuid}`;
            let value1: Uint8Array | undefined = this.mWriteDesc.get(key1);
            this.mWriteDesc.delete(key1);
            if (value1 == null) {
              value1 = new Uint8Array(0);
            }
            // see: BmDescriptorData
            let response: Map<string, Object> = new Map<string, Object>();
            response.set("remote_id", remoteId);
            if (primaryService != null) {
              response.set("primary_service_uuid", respPrimaryServiceUuid);
            }
            response.set("service_uuid", respServiceUuid);
            response.set("characteristic_uuid", respCharacteristicUuid);
            response.set("descriptor_uuid", respDescriptorUuid);
            response.set("instance_id", respInstanceId);
            response.set("value", value1);
            response.set("success", 1);
            response.set("error_code", 0);
            response.set("error_string", "GATT_SUCCESS");
            this.channel?.invokeMethod("OnDescriptorWritten", response);
            result.success(true);
          }).catch((e: BusinessError) => {
            this.log(hilog.LogLevel.ERROR, `setNotifyValue failed for remoteId=${remoteId}: writeDescriptorValue failed, errCode=${e.code}, errMsg=${e.message}`);
            result.error("setNotifyValue", "gatt.writeDescriptor() returned false", null);
          });
          break;
        }
        case "disconnect": {
          let remoteId: string = call.args;
          this.remoteId = remoteId;
          try {
            let gatt: ble.GattClientDevice | null = null;
            if (gatt == null) {
              gatt = this.mCurrentlyConnectingDevices.get(remoteId) as ble.GattClientDevice;
              if (gatt != null) {
                this.log(hilog.LogLevel.DEBUG, "disconnect: cancelling connection in progress for " + remoteId);
              }
            }
            if (gatt == null) {
              gatt = this.mConnectedDevices.get(remoteId) as ble.GattClientDevice;
            }
            if (gatt == null) {
              gatt = this.mAutoConnected.get(remoteId) as ble.GattClientDevice;
              if (gatt != null) {
                this.log(hilog.LogLevel.DEBUG, "disconnect: already disconnected, disabling autoconnect for " + remoteId);
                this.mAutoConnected.delete(remoteId);
                gatt.off('BLEConnectionStateChange', this.ConnectStateChanged);
                gatt.off('BLEMtuChange', this.onMtuChanged);
                gatt.off('BLECharacteristicChange', this.onCharacteristicChange);
                gatt.disconnect();
                gatt.close();
                this.deviceServicesMap.delete(remoteId);
                result.success(false);
                return;
              }
            }
            if (gatt == null) {
              this.log(hilog.LogLevel.DEBUG, "disconnect: already disconnected for " + remoteId);
              result.success(false);
              return;
            }
            this.mAutoConnected.delete(remoteId);

            // remove event listeners first
            gatt.off('BLEConnectionStateChange', this.ConnectStateChanged);
            gatt.off('BLEMtuChange', this.onMtuChanged);
            gatt.off('BLECharacteristicChange', this.onCharacteristicChange);

            // disconnect
            gatt.disconnect();

            // was connecting?
            if (this.mCurrentlyConnectingDevices.has(remoteId)) {
              // remove from connecting devices
              this.mCurrentlyConnectingDevices.delete(remoteId);

              // cleanup resources
              gatt.close();

              // send disconnection event
              let response: Map<string, string | number> = new Map<string, string>();
              response.set("remote_id", remoteId);
              response.set("connection_state",
                this.bmConnectionStateEnum(constant.ProfileConnectionState.STATE_DISCONNECTED));
              response.set("disconnect_reason_code", 23789258);
              response.set("disconnect_reason_string", "connection canceled");
              this.channel?.invokeMethod("OnConnectionStateChanged", response);

              // cleanup services map
              this.deviceServicesMap.delete(remoteId);
            } else {
              // remove from connected devices
              this.mConnectedDevices.delete(remoteId);

              // cleanup resources
              gatt.close();

              // send disconnection event
              let response: Map<string, string | number> = new Map<string, string>();
              response.set("remote_id", remoteId);
              response.set("connection_state",
                this.bmConnectionStateEnum(constant.ProfileConnectionState.STATE_DISCONNECTED));
              response.set("disconnect_reason_code", 0);
              response.set("disconnect_reason_string", "disconnected normally");
              this.channel?.invokeMethod("OnConnectionStateChanged", response);

              // cleanup services map
              this.deviceServicesMap.delete(remoteId);
            }
            result.success(true);
            break;
          } catch (e) {
            let error = e as BusinessError;
            this.log(hilog.LogLevel.ERROR, "disconnect failed for remoteId=" + remoteId + ": error=" + JSON.stringify(error));
            result.error("disconnect", error.message, null);
          }

        }
        case "requestMtu": {
          let data: Map<string, string | number> = call.args;
          let remoteId: string = data.get("remote_id") as string;
          let mtu: number = data.get("mtu") as number;
          let gatt: ble.GattClientDevice = this.mConnectedDevices.get(remoteId) as ble.GattClientDevice;
          if (gatt == null) {
            this.log(hilog.LogLevel.ERROR, "requestMtu failed for remoteId=" + remoteId + ": device is not connected");
            result.error("requestMtu", "gatt.requestMtu() returned false", null);
            break;
          }
          let mtuFlag: boolean = true;
          let errCode: number = 0;
          let errMsg: string = "GATT_SUCCESS";
          try {
            gatt.setBLEMtuSize(mtu);
          } catch (e) {
            errCode = e.code;
            errMsg = e.message;
            mtuFlag = false;
          }
          if (!mtuFlag) {
            this.log(hilog.LogLevel.ERROR, `requestMtu failed for remoteId=${remoteId}: setBLEMtuSize failed, errCode=${errCode}, errMsg=${errMsg}`);
            result.error("requestMtu", "gatt.requestMtu() returned false", null);
            break;
          }
          this.mMtu.set(remoteId, mtu);
          let response: Map<string, object | string | number> = new Map<string, object>();
          response.set("remote_id", remoteId);
          response.set("mtu", mtu);
          response.set("success", mtuFlag ? 1 : 0);
          response.set("error_code", errCode);
          response.set("error_string", errMsg);
          this.channel?.invokeMethod("OnMtuChanged", response);
          result.success(true);
          break;
        }
        case "readCharacteristic": {
          let data: Map<string, string | number> = call.args;
          let remoteId: string = data.get("remote_id") as string;
          let primaryServiceUuid: string = data.get("primary_service_uuid") as string;
          let serviceUuid: string = data.get("service_uuid") as string;
          let characteristicUuid: string = data.get("characteristic_uuid") as string;
          let instanceId: number = data.get("instance_id") as number;

          this.log(hilog.LogLevel.DEBUG, `readCharacteristic called with params: remoteId=${remoteId}, primaryServiceUuid=${primaryServiceUuid}, serviceUuid=${serviceUuid}, characteristicUuid=${characteristicUuid}, instanceId=${instanceId}`);

          // check connection
          let gatt: ble.GattClientDevice = this.mConnectedDevices.get(remoteId) as ble.GattClientDevice;
          if (gatt == null) {
            this.log(hilog.LogLevel.ERROR, "readCharacteristic failed: device is disconnected");
            result.error("readCharacteristic", "device is disconnected", null);
            break;
          }

          let bondState = connection.getPairState(remoteId);
          this.log(hilog.LogLevel.DEBUG, `readCharacteristic: bond state: ${bondState}`);
          if (bondState == connection.BondState.BOND_STATE_BONDING) {
            bondState = connection.getPairState(remoteId);
          }

          let services: ble.GattService[] = await gatt.getServices();
          this.log(hilog.LogLevel.DEBUG, `readCharacteristic: found ${services.length} services`);
          let found =
            await this.locateCharacteristic(primaryServiceUuid, serviceUuid, characteristicUuid, instanceId, services);
          if (found?.error != null) {
            this.log(hilog.LogLevel.ERROR, `readCharacteristic failed: characteristic not found: ${found.error}`);
            result.error("readCharacteristic", found.error, null);
            break;
          }
          let characteristic: ble.BLECharacteristic = found?.characteristic as ble.BLECharacteristic;

          // check readable
          if (!characteristic.properties?.read) {
            this.log(hilog.LogLevel.ERROR, "readCharacteristic failed: characteristic is not readable");
            result.error("readCharacteristic",
              "The READ property is not supported by this BLE characteristic", null);
            break;
          }

          let readCharacteristic: ble.BLECharacteristic | null = null;
          try {
            this.log(hilog.LogLevel.DEBUG, "readCharacteristic: calling gatt.readCharacteristicValue()");
            readCharacteristic = await gatt.readCharacteristicValue(characteristic);
            this.log(hilog.LogLevel.DEBUG, "readCharacteristic: gatt.readCharacteristicValue() succeeded");
          } catch (e) {
            let error = e as BusinessError;
            this.log(hilog.LogLevel.ERROR, `readCharacteristic failed: gatt.readCharacteristicValue() threw error: ${JSON.stringify(e)}`);

            if (error.code === 2901006) {
              this.log(hilog.LogLevel.ERROR, "readCharacteristic failed: Connection not authenticated. Attempting to bond device...");
              try {
                await connection.pairDevice(remoteId);
                this.log(hilog.LogLevel.DEBUG, "readCharacteristic: Device bonding initiated");
                let newBondState = connection.getPairState(remoteId);
                if (newBondState == connection.BondState.BOND_STATE_BONDED) {
                  this.log(hilog.LogLevel.DEBUG, "readCharacteristic: Device bonded successfully. Retrying read...");
                  readCharacteristic = await gatt.readCharacteristicValue(characteristic);
                  this.log(hilog.LogLevel.DEBUG, "readCharacteristic: gatt.readCharacteristicValue() succeeded after bonding");
                } else {
                  this.log(hilog.LogLevel.ERROR, `readCharacteristic failed: Device bonding failed. errorCode=${error.code}`);
                  result.error("readCharacteristic",
                    `gatt.readCharacteristic() failed with error: Device bonding failed. Error code: ${error.code}`,
                    { errorCode: error.code, errorDetails: JSON.stringify(e) });
                  break;
                }
              } catch (bondError) {
                this.log(hilog.LogLevel.ERROR, `readCharacteristic failed: Device bonding failed: ${JSON.stringify(bondError)}`);
                result.error("readCharacteristic",
                  `gatt.readCharacteristic() failed with error: ${error.message ||
                    "unknown error"}. Failed to bond device.`,
                  { errorCode: error.code, errorDetails: JSON.stringify(e) });
                break;
              }
            } else {
              this.log(hilog.LogLevel.ERROR, `readCharacteristic failed: gatt.readCharacteristic() failed with error: ${error.message || "unknown error"}`);
              result.error("readCharacteristic",
                `gatt.readCharacteristic() failed with error: ${error.message || "unknown error"}`,
                { errorCode: error.code, errorDetails: JSON.stringify(e) });
              break;
            }
          }

          if (readCharacteristic == null) {
            this.log(hilog.LogLevel.ERROR, "readCharacteristic failed: gatt.readCharacteristicValue() returned null");
            result.error("readCharacteristic", "gatt.readCharacteristic() returned null", null);
            break;
          }
          this.deviceServicesMap.set(remoteId, services);
          this.onCharacteristicReceived(remoteId, services, readCharacteristic as ble.BLECharacteristic);
          gatt.on('BLECharacteristicChange', this.onCharacteristicChange);
          this.log(hilog.LogLevel.DEBUG, "readCharacteristic: operation completed successfully");
          result.success(true);
          break;
        }
        case "writeCharacteristic": {
          // see: BmWriteCharacteristicRequest
          let data: Map<string, string | number | Uint8Array> = call.args;
          let remoteId: string = data.get("remote_id") as string;
          let primaryServiceUuid: string = data.get("primary_service_uuid") as string;
          let serviceUuid: string = data.get("service_uuid") as string;
          let characteristicUuid: string = data.get("characteristic_uuid") as string;
          let instanceId: number = data.get("instance_id") as number;
          let value: Uint8Array = data.get("value") as Uint8Array;
          let writeTypeInt: number = data.get("write_type") as number;
          let allowLongWrite: boolean = data.get("allow_long_write") as number != 0;
          let writeType: number = writeTypeInt == 0 ? ble.GattWriteType.WRITE : ble.GattWriteType.WRITE_NO_RESPONSE;
          // check connection
          let gatt: ble.GattClientDevice = this.mConnectedDevices.get(remoteId) as ble.GattClientDevice;
          if (gatt == null) {
            this.log(hilog.LogLevel.ERROR, "writeCharacteristic failed: device is disconnected");
            result.error("writeCharacteristic", "device is disconnected", null);
            break;
          }

          let gattServices: ble.GattService[] = await gatt.getServices();
          let found: ChrFound =
            await this.locateCharacteristic(primaryServiceUuid, serviceUuid, characteristicUuid, instanceId,
              gattServices) as ChrFound;
          if (found?.error != null) {
            this.log(hilog.LogLevel.ERROR, `writeCharacteristic failed: ${found.error}`);
            result.error("writeCharacteristic", found.error, null);
            break;
          }

          let characteristic: ble.BLECharacteristic | null = found.characteristic;
          // Add null check for characteristic
          if (characteristic == null) {
            this.log(hilog.LogLevel.ERROR, "writeCharacteristic failed: characteristic not found");
            result.error("writeCharacteristic", "Characteristic not found", null);
            break;
          }
          if (writeType == ble.GattWriteType.WRITE) {
            if (!characteristic?.properties?.write) {
              this.log(hilog.LogLevel.ERROR, "writeCharacteristic failed: WRITE property not supported");
              result.error("writeCharacteristic",
                "The WRITE property is not supported by this BLE characteristic", null);
              break;
            }
          } else {
            if (!characteristic?.properties?.writeNoResponse) {
              this.log(hilog.LogLevel.ERROR, "writeCharacteristic failed: WRITE_NO_RESPONSE property not supported");
              result.error("writeCharacteristic",
                "The WRITE_NO_RESPONSE property is not supported by this BLE characteristic", null);
              break;
            }
          }
          // check maximum payload
          let maxLen: number = this.getMaxPayload(remoteId, writeType, allowLongWrite);
          let dataLen: number = value.length as number;
          if (dataLen > maxLen) {
            let a: string = writeTypeInt == 0 ? "withResponse" : "withoutResponse";
            let b: string = writeTypeInt == 0 ? (allowLongWrite ? ", allowLongWrite" : ", noLongWrite") : "";
            let str: string =
              "data longer than allowed. dataLen: " + dataLen + " > max: " + maxLen + " (" + a + b + ")";
            this.log(hilog.LogLevel.ERROR, `writeCharacteristic failed: ${str}`);
            result.error("writeCharacteristic", str, null);
            break;
          }
          // remember the data we are writing
          if (primaryServiceUuid == null) {
            primaryServiceUuid = "";
          }
          let key: string =
            remoteId + ":" + primaryServiceUuid + ":" + serviceUuid + ":" + characteristicUuid + ":" + instanceId;
          // write characteristic
          this.mWriteChr.set(key, value);
          let writeFailed: boolean = false;
          let writeValue: ArrayBuffer = this.typedArrayToBuffer(value);
          characteristic.characteristicValue = writeValue;
          let errorMessage: string = "";
          let errorCode: number = 0;
          try {
            await gatt.writeCharacteristicValue(characteristic, writeType);
          } catch (e) {
            let businessError = e as BusinessError;
            errorMessage = businessError.message;
            errorCode = businessError.code;
            writeFailed = true;
          }

          if (writeFailed) {
            this.log(hilog.LogLevel.ERROR, `writeCharacteristic failed: errorCode=${errorCode}, errmessage=${errorMessage}`);
            result.error("writeCharacteristic", `errorCode: ${errorCode} ,  errmessage: ${errorMessage}`, null);
            break;
          }
          // has associated primary service?
          let primaryService = this.getPrimaryService(gattServices, characteristic);
          // onCharacteristicWrite
          // for convenience
          let primaryServiceUuid1 = primaryService != null ? this.uuidStr(primaryService.serviceUuid) : "";
          let serviceUuid1 = this.uuidStr(characteristic.serviceUuid);
          let characteristicUuid1 = this.uuidStr(characteristic.characteristicUuid);
          let instanceId1 = FlutterBluePlusOhosPlugin.getInstanceId(characteristic, gattServices);
          // what data did we write?
          let key1: string = `${remoteId}:${primaryServiceUuid1}:${serviceUuid1}:${characteristicUuid1}:${instanceId1}`;
          let value1: Uint8Array | undefined = this.mWriteChr.get(key1);
          this.mWriteChr.delete(key1);
          if (value1 == null) {
            value1 = new Uint8Array(0);
          }
          // see: BmCharacteristicData
          let response: Map<string, Object> = new Map<string, Object>();
          response.set("remote_id", remoteId);
          if (primaryService != null) {
            response.set("primary_service_uuid", primaryServiceUuid1);
          }
          response.set("service_uuid", serviceUuid1);
          response.set("characteristic_uuid", characteristicUuid1);
          response.set("instance_id", instanceId1);
          response.set("value", value1);
          response.set("success", writeFailed ? 0 : 1);
          response.set("error_code", errorCode);
          response.set("error_string", errorMessage);
          this.channel?.invokeMethod("OnCharacteristicWritten", response);
          result.success(true);
          break;
        }
        case "readDescriptor": {
          let data: Map<string, string | number> = call.args;
          let remoteId: string = data.get("remote_id") as string;
          let primaryServiceUuid: string = data.get("primary_service_uuid") as string;
          let serviceUuid: string = data.get("service_uuid") as string;
          let characteristicUuid: string = data.get("characteristic_uuid") as string;
          let instanceId: number = data.get("instance_id") as number;
          let descriptorUuid: string = data.get("descriptor_uuid") as string;
          // check connection
          let gatt: ble.GattClientDevice = this.mConnectedDevices.get(remoteId) as ble.GattClientDevice;
          if (gatt == null) {
            this.log(hilog.LogLevel.ERROR, "readDescriptor failed: device is disconnected");
            result.error("readDescriptor", "device is disconnected", null);
            break;
          }
          let services: ble.GattService[] = await gatt.getServices();
          // find characteristic
          let found: ChrFound =
            await this.locateCharacteristic(primaryServiceUuid, serviceUuid, characteristicUuid, instanceId,
              services) as ChrFound;
          if (found.error != null) {
            this.log(hilog.LogLevel.ERROR, `readDescriptor failed: ${found.error}`);
            result.error("readDescriptor", found.error, null);
            break;
          }
          let characteristic: ble.BLECharacteristic = found.characteristic as ble.BLECharacteristic;
          // find descriptor
          let descriptor: ble.BLEDescriptor =
            this.getReadDescriptorFromArray(descriptorUuid, characteristic.descriptors) as ble.BLEDescriptor;
          if (descriptor == null) {
            let s: string =
              "descriptor not found on characteristic. (desc: " + descriptorUuid + " chr: " + characteristicUuid + ")";
            this.log(hilog.LogLevel.ERROR, `readDescriptor failed: ${s}`);
            result.error("readDescriptor", s, null);
            break;
          }
          let service: ble.GattService | null = null;
          services.forEach(item => {
            if (this.uuidStr(item.serviceUuid) == serviceUuid) {
              service = item;
            }
          })
          let errorMessage: string = ""
          let errorCode: number = 0;
          let readDescriptor: ble.BLEDescriptor | null = null;
          let readDescriptorFlag: boolean = false;
          try {
            readDescriptor = await gatt.readDescriptorValue(descriptor);
          } catch (e) {
            errorMessage = e.message;
            errorCode = e.code;
            readDescriptorFlag = true;
            this.log(hilog.LogLevel.ERROR, `readDescriptor failed: gatt.readDescriptor() returned false, errorCode=${errorCode}, errorMessage=${errorMessage}`);
            result.error("readDescriptor", "gatt.readDescriptor() returned false", null);
            break;
          }
          // has associated primary service?
          let primaryService: ble.GattService | null = this.getPrimaryService(services, characteristic);
          // see: BmDescriptorData
          let response: Map<string, string | number | object> = new Map<string, string | number | object>();
          if (primaryService != null) {
            response.set("primary_service_uuid", this.uuidStr(primaryService.serviceUuid))
          }
          response.set("remote_id", remoteId);
          response.set("service_uuid", this.uuidStr(readDescriptor.serviceUuid));
          response.set("instance_id", FlutterBluePlusOhosPlugin.getInstanceId(characteristic, services));
          response.set("characteristic_uuid", this.uuidStr(readDescriptor.characteristicUuid));
          response.set("descriptor_uuid", this.uuidStr(readDescriptor.descriptorUuid));
          response.set("value", new Uint8Array(readDescriptor.descriptorValue));
          response.set("success", readDescriptorFlag ? 0 : 1);
          response.set("error_code", errorCode);
          response.set("error_string", errorMessage);
          this.channel?.invokeMethod("OnDescriptorRead", response);
          result.success(true);
          break;
        }
        case "writeDescriptor": {
          // see: BmWriteDescriptorRequest
          let data: Map<string, object | string | number> = call.args;
          let remoteId = data.get("remote_id") as string;
          let primaryServiceUuid = data.get("primary_service_uuid") as string;
          let serviceUuid = data.get("service_uuid") as string;
          let characteristicUuid = data.get("characteristic_uuid") as string;
          let instanceId = data.get("instance_id") as number;
          let descriptorUuid = data.get("descriptor_uuid") as string;
          let value = data.get("value") as Uint8Array;
          let gatt: ble.GattClientDevice = this.mConnectedDevices.get(remoteId) as ble.GattClientDevice;
          if (gatt == null) {
            this.log(hilog.LogLevel.ERROR, "writeDescriptor failed: device is disconnected");
            result.error("writeDescriptor", "device is disconnected", null);
            break;
          }
          let gattService: Array<ble.GattService> = await gatt.getServices();
          let found: ChrFound =
            await this.locateCharacteristic(primaryServiceUuid, serviceUuid, characteristicUuid, instanceId,
              gattService) as ChrFound;
          if (found.error != null) {
            this.log(hilog.LogLevel.ERROR, `writeDescriptor failed: ${found.error}`);
            result.error("writeDescriptor", found.error, null);
            break;
          }
          let characteristic: ble.BLECharacteristic = found.characteristic as ble.BLECharacteristic;
          // find descriptor
          let descriptor: ble.BLEDescriptor =
            this.getReadDescriptorFromArray(descriptorUuid, characteristic.descriptors) as ble.BLEDescriptor;
          if (descriptor == null) {
            let s: string =
              "descriptor not found on characteristic. (desc: " + descriptorUuid + " chr: " + characteristicUuid + ")";
            this.log(hilog.LogLevel.ERROR, `writeDescriptor failed: ${s}`);
            result.error("writeDescriptor", s, null);
            break;
          }
          // check mtu
          let mtu: number = this.mMtu.get(remoteId) as number;
          if ((mtu - 3) < value.length) {
            let s: string = "data longer than mtu allows. dataLength: " + value.length + "> max: " + (mtu - 3);
            this.log(hilog.LogLevel.ERROR, `writeDescriptor failed: ${s}`);
            result.error("writeDescriptor", s, null);
            break;
          }

          // remember the data we are writing
          if (primaryServiceUuid == null) {
            primaryServiceUuid = "";
          }
          let key: string = remoteId + ":" + primaryServiceUuid + ":" + serviceUuid + ":" +
            characteristicUuid + ":" + instanceId + ":" + descriptorUuid;
          this.mWriteDesc.set(key, value);
          // write descriptor
          let writeValue: ArrayBuffer = this.typedArrayToBuffer(value as Uint8Array);
          descriptor.descriptorValue = writeValue;
          let errorCode: number = 0;
          let errorMessage: string = ""
          let writeDescriptorFlags: boolean = true;
          try {
            await gatt.writeDescriptorValue(descriptor);
          } catch (e) {
            writeDescriptorFlags = false;
            errorCode = e.code;
            errorMessage = e.message;
            this.log(hilog.LogLevel.ERROR, `writeDescriptor failed: gatt.writeDescriptor() returned false, errorCode=${errorCode}, errorMessage=${errorMessage}`);
            result.error("writeDescriptor", "gatt.writeDescriptor() returned false", null);
            break;
          }

          // has associated primary service?
          let primaryService = this.getPrimaryService(gattService, characteristic);
          let respPrimaryServiceUuid: string = primaryService != null ? this.uuidStr(primaryService.serviceUuid) : "";
          let respServiceUuid: string = this.uuidStr(descriptor.serviceUuid);
          let respCharacteristicUuid: string = this.uuidStr(descriptor.characteristicUuid) as string;
          let respInstanceId: number = FlutterBluePlusOhosPlugin.getInstanceId(characteristic, gattService);
          let respDescriptorUuid: string = this.uuidStr(descriptor.descriptorUuid);
          // what data did we write?
          let key1: string =
            `${remoteId}:${respPrimaryServiceUuid}:${respServiceUuid}:${respCharacteristicUuid}:${respInstanceId}:${respDescriptorUuid}`;
          let value1: Uint8Array | undefined = this.mWriteDesc.get(key1);
          this.mWriteDesc.delete(key1);
          if (value1 == null) {
            value1 = new Uint8Array(0);
          }
          // see: BmDescriptorData
          let response: Map<string, object | string | number> = new Map();
          response.set("remote_id", remoteId);
          if (primaryService != null) {
            response.set("primary_service_uuid", this.uuidStr(primaryService.serviceUuid));
          }
          response.set("service_uuid", respServiceUuid);
          response.set("characteristic_uuid", respCharacteristicUuid);
          response.set("descriptor_uuid", respDescriptorUuid);
          response.set("instance_id", respInstanceId);
          response.set("value", value1);
          response.set("success", writeDescriptorFlags ? 1 : 0);
          response.set("error_code", errorCode);
          response.set("error_string", errorMessage);
          this.channel?.invokeMethod("OnDescriptorWritten", response);
          result.success(true);
          break;
        }
        case "getBondedDevices": {
          let devices: Array<string> = connection.getPairedDevices();
          let deviceList: List<Map<string, object | string>> = new List();
          devices.forEach(async (device) => {
            let name: string = await ble.createGattClientDevice(device).getDeviceName();
            deviceList.add(this.bmBluetoothDevice(device, name));
          })
          let response: Map<string, object | string> = new Map<string, object | string>();
          response.set("devices", deviceList);
          result.success(response);
          break;
        }
        case "getBondState": {
          let remoteId: string = call.args;
          let res: connection.BondState = connection.getPairState(remoteId);
          let response: Map<string, string | number | null> = new Map();
          response.set("remote_id", remoteId);
          response.set("bond_state", this.bmBondStateEnum(res));
          response.set("prev_state", null);
          result.success(response);
          break;
        }
        case "getPhySupport": {
          try {
            // Get PHY support information from Harmony OS BLE API
            let le1mSupported: boolean = true; // LE_1M is always supported in BLE 5.0+
            let le2mSupported: boolean = false; // Assume not supported for now
            let leCodedSupported: boolean = false; // Assume not supported for now

            let response: Map<string, boolean> = new Map();
            response.set("le_1m", le1mSupported);
            response.set("le_2m", le2mSupported);
            response.set("le_coded", leCodedSupported);

            result.success(response);
          } catch (e) {
            this.log(hilog.LogLevel.ERROR, `getPhySupport failed: ${(e as BusinessError).message}`);
            result.error("getPhySupport", (e as BusinessError).message, null);
          }
          break;
        }
        case "createBond": {
          let data: Map<string, object | string | Uint8Array> = call.args;
          let remoteId: string = data.get('remote_id') as string;
          if (data.get('pin') !== null && data.get('pin') !== undefined) {
            this.mBondingPins.set(remoteId, data.get('pin') as Uint8Array);
          }
          let gatt: ble.GattClientDevice = this.mConnectedDevices.get(remoteId) as ble.GattClientDevice;
          if (gatt == null) {
            this.log(hilog.LogLevel.ERROR, "createBond failed: device is disconnected");
            result.error("createBond", "device is disconnected", null);
            break;
          }
          let res: connection.BondState = connection.getPairState(remoteId);
          // already bonded?
          if (res == connection.BondState.BOND_STATE_BONDED) {
            result.success(false);
            break;
          }
          // bonding already in progress?
          if (res == connection.BondState.BOND_STATE_BONDING) {
            result.success(true);
            break;
          }
          let pairFlag: boolean = false;
          try {
            connection.pairDevice(remoteId)
          } catch (e) {
            this.log(hilog.LogLevel.ERROR, `createBond failed: device.createBond() returned false, error=${JSON.stringify(e)}`);
            result.error("createBond", "device.createBond() returned false", null);
            break;
          }
          result.success(true);
          break;
        }
        case "removeBond": {
          let remoteId: string = call.args;
          let res: connection.BondState = connection.getPairState(remoteId);
          if (res == connection.BondState.BOND_STATE_INVALID) {
            result.success(false);
            break;
          }
          result.success(true);
          break;
        }
        case "clearGattCache": {
          let remoteId: string = call.args;
          let gatt: ble.GattClientDevice = this.mConnectedDevices.get(remoteId) as ble.GattClientDevice;
          if (gatt == null) {
            this.log(hilog.LogLevel.ERROR, "clearGattCache failed: device is disconnected");
            result.error("clearGattCache", "device is disconnected", null);
            break;
          }
          result.success(true);
          break;
        }
        default: {
          result.notImplemented()
          break;
        }
      }
    } catch (e) {
      let error: string = e.message
      return;
    }
  }

  /**
   * Binary channel implementation of writeCharacteristic.
   * Mirrors the "writeCharacteristic" MethodChannel case, returning
   * {success, errorCode, errorString} instead of using MethodResult.
   */
  public async binaryWriteCharacteristic(remoteId: string, primaryServiceUuid: string, serviceUuid: string,
      characteristicUuid: string, instanceId: number, writeType: number, value: Uint8Array):
      Promise<Map<string, number | string>> {
    let result: Map<string, number | string> = new Map<string, number | string>();
    result.set("success", 0);
    result.set("errorCode", 0);
    result.set("errorString", "");
    // check connection
    let gatt: ble.GattClientDevice = this.mConnectedDevices.get(remoteId) as ble.GattClientDevice;
    if (gatt == null) {
      this.log(hilog.LogLevel.ERROR, "binaryWriteCharacteristic failed: device is disconnected");
      result.set("errorCode", 1);
      result.set("errorString", "device is disconnected");
      return result;
    }
    let gattServices: ble.GattService[] = await gatt.getServices();
    let found: ChrFound =
      await this.locateCharacteristic(primaryServiceUuid, serviceUuid, characteristicUuid, instanceId,
        gattServices) as ChrFound;
    if (found?.error != null) {
      this.log(hilog.LogLevel.ERROR, `binaryWriteCharacteristic failed: ${found.error}`);
      result.set("errorCode", 2);
      result.set("errorString", found.error);
      return result;
    }
    let characteristic: ble.BLECharacteristic | null = found.characteristic;
    // Add null check for characteristic
    if (characteristic == null) {
      this.log(hilog.LogLevel.ERROR, "binaryWriteCharacteristic failed: characteristic not found");
      result.set("errorCode", 2);
      result.set("errorString", "Characteristic not found");
      return result;
    }
    let writeTypeInt: number = writeType;
    let allowLongWrite: boolean = false;
    let gattWriteType: number = writeTypeInt == 0 ? ble.GattWriteType.WRITE : ble.GattWriteType.WRITE_NO_RESPONSE;
    if (gattWriteType == ble.GattWriteType.WRITE) {
      if (!characteristic?.properties?.write) {
        this.log(hilog.LogLevel.ERROR, "binaryWriteCharacteristic failed: WRITE property not supported");
        result.set("errorCode", 3);
        result.set("errorString", "The WRITE property is not supported by this BLE characteristic");
        return result;
      }
    } else {
      if (!characteristic?.properties?.writeNoResponse) {
        this.log(hilog.LogLevel.ERROR, "binaryWriteCharacteristic failed: WRITE_NO_RESPONSE property not supported");
        result.set("errorCode", 3);
        result.set("errorString", "The WRITE_NO_RESPONSE property is not supported by this BLE characteristic");
        return result;
      }
    }
    // check maximum payload
    let maxLen: number = this.getMaxPayload(remoteId, gattWriteType, allowLongWrite);
    let dataLen: number = value.length as number;
    if (dataLen > maxLen) {
      let a: string = writeTypeInt == 0 ? "withResponse" : "withoutResponse";
      let str: string =
        "data longer than allowed. dataLen: " + dataLen + " > max: " + maxLen + " (" + a + ")";
      this.log(hilog.LogLevel.ERROR, `binaryWriteCharacteristic failed: ${str}`);
      result.set("errorCode", 4);
      result.set("errorString", str);
      return result;
    }
    // remember the data we are writing
    if (primaryServiceUuid == null) {
      primaryServiceUuid = "";
    }
    let key: string =
      remoteId + ":" + primaryServiceUuid + ":" + serviceUuid + ":" + characteristicUuid + ":" + instanceId;
    // write characteristic
    this.mWriteChr.set(key, value);
    let writeValue: ArrayBuffer = this.typedArrayToBuffer(value);
    characteristic.characteristicValue = writeValue;
    try {
      await gatt.writeCharacteristicValue(characteristic, gattWriteType);
    } catch (e) {
      let businessError = e as BusinessError;
      this.log(hilog.LogLevel.ERROR,
        `binaryWriteCharacteristic failed: errorCode=${businessError.code}, errmessage=${businessError.message}`);
      result.set("errorCode", 4);
      result.set("errorString", `errorCode: ${businessError.code} ,  errmessage: ${businessError.message}`);
      return result;
    }
    // has associated primary service?
    let primaryService = this.getPrimaryService(gattServices, characteristic);
    // onCharacteristicWrite
    // for convenience
    let primaryServiceUuid1 = primaryService != null ? this.uuidStr(primaryService.serviceUuid) : "";
    let serviceUuid1 = this.uuidStr(characteristic.serviceUuid);
    let characteristicUuid1 = this.uuidStr(characteristic.characteristicUuid);
    let instanceId1 = FlutterBluePlusOhosPlugin.getInstanceId(characteristic, gattServices);
    // what data did we write?
    let key1: string = `${remoteId}:${primaryServiceUuid1}:${serviceUuid1}:${characteristicUuid1}:${instanceId1}`;
    let value1: Uint8Array | undefined = this.mWriteChr.get(key1);
    this.mWriteChr.delete(key1);
    if (value1 == null) {
      value1 = new Uint8Array(0);
    }
    // see: BmCharacteristicData
    let response: Map<string, Object> = new Map<string, Object>();
    response.set("remote_id", remoteId);
    if (primaryService != null) {
      response.set("primary_service_uuid", primaryServiceUuid1);
    }
    response.set("service_uuid", serviceUuid1);
    response.set("characteristic_uuid", characteristicUuid1);
    response.set("instance_id", instanceId1);
    response.set("value", value1);
    response.set("success", 1);
    response.set("error_code", 0);
    response.set("error_string", "GATT_SUCCESS");
    this.channel?.invokeMethod("OnCharacteristicWritten", response);
    result.set("success", 1);
    return result;
  }

  /**
   * Binary channel implementation of writeDescriptor.
   * Mirrors the "writeDescriptor" MethodChannel case, returning
   * {success, errorCode, errorString} instead of using MethodResult.
   */
  public async binaryWriteDescriptor(remoteId: string, primaryServiceUuid: string, serviceUuid: string,
      characteristicUuid: string, instanceId: number, descriptorUuid: string, value: Uint8Array):
      Promise<Map<string, number | string>> {
    let result: Map<string, number | string> = new Map<string, number | string>();
    result.set("success", 0);
    result.set("errorCode", 0);
    result.set("errorString", "");
    let gatt: ble.GattClientDevice = this.mConnectedDevices.get(remoteId) as ble.GattClientDevice;
    if (gatt == null) {
      this.log(hilog.LogLevel.ERROR, "binaryWriteDescriptor failed: device is disconnected");
      result.set("errorCode", 1);
      result.set("errorString", "device is disconnected");
      return result;
    }
    let gattService: Array<ble.GattService> = await gatt.getServices();
    let found: ChrFound =
      await this.locateCharacteristic(primaryServiceUuid, serviceUuid, characteristicUuid, instanceId,
        gattService) as ChrFound;
    if (found.error != null) {
      this.log(hilog.LogLevel.ERROR, `binaryWriteDescriptor failed: ${found.error}`);
      result.set("errorCode", 2);
      result.set("errorString", found.error);
      return result;
    }
    let characteristic: ble.BLECharacteristic = found.characteristic as ble.BLECharacteristic;
    // find descriptor
    let descriptor: ble.BLEDescriptor =
      this.getReadDescriptorFromArray(descriptorUuid, characteristic.descriptors) as ble.BLEDescriptor;
    if (descriptor == null) {
      let s: string =
        "descriptor not found on characteristic. (desc: " + descriptorUuid + " chr: " + characteristicUuid + ")";
      this.log(hilog.LogLevel.ERROR, `binaryWriteDescriptor failed: ${s}`);
      result.set("errorCode", 5);
      result.set("errorString", s);
      return result;
    }
    // check mtu
    let mtu: number = this.mMtu.get(remoteId) as number;
    if ((mtu - 3) < value.length) {
      let s: string = "data longer than mtu allows. dataLength: " + value.length + "> max: " + (mtu - 3);
      this.log(hilog.LogLevel.ERROR, `binaryWriteDescriptor failed: ${s}`);
      result.set("errorCode", 4);
      result.set("errorString", s);
      return result;
    }
    // remember the data we are writing
    if (primaryServiceUuid == null) {
      primaryServiceUuid = "";
    }
    let key: string = remoteId + ":" + primaryServiceUuid + ":" + serviceUuid + ":" +
      characteristicUuid + ":" + instanceId + ":" + descriptorUuid;
    this.mWriteDesc.set(key, value);
    // write descriptor
    let writeValue: ArrayBuffer = this.typedArrayToBuffer(value as Uint8Array);
    descriptor.descriptorValue = writeValue;
    try {
      await gatt.writeDescriptorValue(descriptor);
    } catch (e) {
      let businessError = e as BusinessError;
      this.log(hilog.LogLevel.ERROR,
        `binaryWriteDescriptor failed: gatt.writeDescriptor() returned false, errorCode=${businessError.code}, errorMessage=${businessError.message}`);
      result.set("errorCode", 4);
      result.set("errorString", "gatt.writeDescriptor() returned false");
      return result;
    }
    // has associated primary service?
    let primaryService = this.getPrimaryService(gattService, characteristic);
    let respPrimaryServiceUuid: string = primaryService != null ? this.uuidStr(primaryService.serviceUuid) : "";
    let respServiceUuid: string = this.uuidStr(descriptor.serviceUuid);
    let respCharacteristicUuid: string = this.uuidStr(descriptor.characteristicUuid) as string;
    let respInstanceId: number = FlutterBluePlusOhosPlugin.getInstanceId(characteristic, gattService);
    let respDescriptorUuid: string = this.uuidStr(descriptor.descriptorUuid);
    // what data did we write?
    let key1: string =
      `${remoteId}:${respPrimaryServiceUuid}:${respServiceUuid}:${respCharacteristicUuid}:${respInstanceId}:${respDescriptorUuid}`;
    let value1: Uint8Array | undefined = this.mWriteDesc.get(key1);
    this.mWriteDesc.delete(key1);
    if (value1 == null) {
      value1 = new Uint8Array(0);
    }
    // see: BmDescriptorData
    let response: Map<string, object | string | number> = new Map();
    response.set("remote_id", remoteId);
    if (primaryService != null) {
      response.set("primary_service_uuid", this.uuidStr(primaryService.serviceUuid));
    }
    response.set("service_uuid", respServiceUuid);
    response.set("characteristic_uuid", respCharacteristicUuid);
    response.set("descriptor_uuid", respDescriptorUuid);
    response.set("instance_id", respInstanceId);
    response.set("value", value1);
    response.set("success", 1);
    response.set("error_code", 0);
    response.set("error_string", "GATT_SUCCESS");
    this.channel?.invokeMethod("OnDescriptorWritten", response);
    result.set("success", 1);
    return result;
  }

  /**
   * Binary channel implementation of setNotifyValue.
   * Mirrors the "setNotifyValue" MethodChannel case, returning
   * {success, errorCode, errorString} instead of using MethodResult.
   */
  public async binarySetNotifyValue(remoteId: string, primaryServiceUuid: string, serviceUuid: string,
      characteristicUuid: string, instanceId: number, enable: boolean, forceIndications: boolean):
      Promise<Map<string, number | string>> {
    let result: Map<string, number | string> = new Map<string, number | string>();
    result.set("success", 0);
    result.set("errorCode", 0);
    result.set("errorString", "");
    let gatt: ble.GattClientDevice = this.mConnectedDevices.get(remoteId) as ble.GattClientDevice;
    if (gatt == null) {
      this.log(hilog.LogLevel.ERROR, "binarySetNotifyValue failed for remoteId=" + remoteId + ": device is not connected");
      result.set("errorCode", 1);
      result.set("errorString", "device is disconnected");
      return result;
    }
    let gattServices = await gatt.getServices();
    if (gattServices == null || gattServices == undefined) {
      this.log(hilog.LogLevel.ERROR, "binarySetNotifyValue failed for remoteId=" + remoteId + ": no services discovered");
      result.set("errorCode", 2);
      result.set("errorString", "no service");
      return result;
    }
    let found =
      await this.locateCharacteristic(primaryServiceUuid, serviceUuid, characteristicUuid, instanceId,
        gattServices);
    if (found?.error != null) {
      this.log(hilog.LogLevel.ERROR, "binarySetNotifyValue failed for remoteId=" + remoteId + ": " + found.error);
      result.set("errorCode", 2);
      result.set("errorString", found.error);
      return result;
    }
    let characteristic: ble.BLECharacteristic = found?.characteristic as ble.BLECharacteristic;
    try {
      await gatt.setCharacteristicChangeNotification(characteristic, enable);
    } catch (e) {
      this.log(hilog.LogLevel.ERROR,
        `binarySetNotifyValue: failed to set characteristic notification for remoteId=${remoteId}: ${JSON.stringify(e)}`);
    }
    let descriptor: ble.BLEDescriptor | null =
      this.getDescriptorFromArray(CCCD, characteristic.descriptors);
    if (descriptor == null) {
      this.log(hilog.LogLevel.ERROR,
        "binarySetNotifyValue failed for remoteId=" + remoteId + ": CCCD descriptor not found");
      result.set("errorCode", 7);
      result.set("errorString", "CCCD descriptor not found");
      return result;
    }
    let descriptorValue: Uint8Array | null = null;
    if (enable) {
      let canNotify: boolean = characteristic.properties?.notify as boolean
      let canIndicate: boolean = characteristic.properties?.indicate as boolean
      if (!canIndicate && !canNotify) {
        this.log(hilog.LogLevel.ERROR,
          `binarySetNotifyValue failed for remoteId=${remoteId}: neither NOTIFY nor INDICATE properties are supported for chr=${characteristicUuid}`);
        result.set("errorCode", 6);
        result.set("errorString",
          "neither NOTIFY nor INDICATE properties are supported by this BLE characteristic");
        return result;
      }
      if (forceIndications && !canIndicate) {
        this.log(hilog.LogLevel.ERROR,
          `binarySetNotifyValue failed for remoteId=${remoteId}: INDICATE not supported for chr=${characteristicUuid}, force_indications requested`);
        result.set("errorCode", 6);
        result.set("errorString", "INDICATE not supported by this BLE characteristic");
        return result;
      }
      if (canIndicate) {
        descriptorValue = this.ENABLE_INDICATION_VALUE;
      }
      if (canNotify) {
        descriptorValue = this.ENABLE_NOTIFICATION_VALUE;
      }
      if (forceIndications) {
        descriptorValue = this.ENABLE_INDICATION_VALUE;
      }
    } else {
      descriptorValue = this.DISABLE_NOTIFICATION_VALUE;
    }
    // remember the data we are writing
    if (primaryServiceUuid == null) {
      primaryServiceUuid = "";
    }
    let key: string = remoteId + ":" + primaryServiceUuid + ":" + serviceUuid + ":" +
      characteristicUuid + ":" + instanceId + ":" + CCCD;
    this.mWriteDesc.set(key, descriptorValue as Uint8Array);
    // write descriptor
    if (descriptorValue) {
      let u8Array: Uint8Array = new Uint8Array(descriptorValue)
      descriptor.descriptorValue = this.typedArrayToBuffer(u8Array)
    }
    try {
      await gatt.writeDescriptorValue(descriptor);
    } catch (e) {
      let businessError = e as BusinessError;
      this.log(hilog.LogLevel.ERROR,
        `binarySetNotifyValue failed for remoteId=${remoteId}: writeDescriptorValue failed, errCode=${businessError.code}, errMsg=${businessError.message}`);
      result.set("errorCode", 4);
      result.set("errorString", "gatt.writeDescriptor() returned false");
      return result;
    }
    // has associated primary service?
    let primaryService = this.getPrimaryService(gattServices, characteristic);
    let respPrimaryServiceUuid: string = primaryService != null ? this.uuidStr(primaryService.serviceUuid) : "";
    let respServiceUuid: string = this.uuidStr(descriptor?.serviceUuid as string);
    let respCharacteristicUuid: string = this.uuidStr(descriptor?.characteristicUuid as string);
    let respInstanceId: number = FlutterBluePlusOhosPlugin.getInstanceId(characteristic, gattServices);
    let respDescriptorUuid: string = this.uuidStr(descriptor?.descriptorUuid as string);
    // what data did we write?
    let key1: string =
      `${remoteId}:${respPrimaryServiceUuid}:${respServiceUuid}:${respCharacteristicUuid}:${respInstanceId}:${respDescriptorUuid}`;
    let value1: Uint8Array | undefined = this.mWriteDesc.get(key1);
    this.mWriteDesc.delete(key1);
    if (value1 == null) {
      value1 = new Uint8Array(0);
    }
    // see: BmDescriptorData
    let response: Map<string, Object> = new Map<string, Object>();
    response.set("remote_id", remoteId);
    if (primaryService != null) {
      response.set("primary_service_uuid", respPrimaryServiceUuid);
    }
    response.set("service_uuid", respServiceUuid);
    response.set("characteristic_uuid", respCharacteristicUuid);
    response.set("descriptor_uuid", respDescriptorUuid);
    response.set("instance_id", respInstanceId);
    response.set("value", value1);
    response.set("success", 1);
    response.set("error_code", 0);
    response.set("error_string", "GATT_SUCCESS");
    this.channel?.invokeMethod("OnDescriptorWritten", response);
    result.set("success", 1);
    return result;
  }

  bmBondStateEnum(bs: number): number {
    switch (bs) {
      case connection.BondState.BOND_STATE_INVALID:
        return 0;
      case connection.BondState.BOND_STATE_BONDING:
        return 1;
      case connection.BondState.BOND_STATE_BONDED:
        return 2;
      default:
        return 0;
    }
  }

  descriptorReadServicePair(service: ble.GattService, services: ble.GattService[]): ServicePair {
    let result: ServicePair = new ServicePair();
    if (service.isPrimary) {
      result.primary = service.serviceUuid;
      return result;
    }
    for (let i = 0; i < services.length; i++) {
      let includeService: ble.GattService[] = services[i].includeServices as ble.GattService[]
      for (let j = 0; j < includeService.length; j++) {
        if (includeService[j].serviceUuid == service.serviceUuid) {
          result.primary = services[i].serviceUuid;
          result.secondary = includeService[i].serviceUuid;
          return result
        }
      }
    }
    return result;
  }

  getMaxPayload(remoteId: string, writeType: number, allowLongWrite: boolean): number {
    let maxAttrLen: number = 512;
    // if no response, we can only write up to MTU-3.
    // This is the same limitation as iOS, and ensures transfer reliability.
    if (writeType == ble.GattWriteType.WRITE_NO_RESPONSE || allowLongWrite == false) {
      let mtu: number = this.mMtu.get(remoteId) as number;
      if (mtu == null) {
        mtu = 23;
      }
      return Math.min(mtu - 3, maxAttrLen);
    } else {
      return maxAttrLen;
    }
  }

  // called for both notifications & reads
  onCharacteristicReceived(address: string, services: ble.GattService[],
    characteristic: ble.BLECharacteristic) {
    // Generic Attribute service 0x1801
    if (this.uuidStr(characteristic.serviceUuid) == "1801") {
      // Service Changed 0x2A05
      if (this.uuidStr(characteristic.characteristicUuid).toUpperCase() == "2A05") {
        let response: Map<string, Object> = this.bmBluetoothDevice(address);
        this.channel?.invokeMethod("OnServicesReset", response);
      }
    }
    // has associated primary service?
    let primaryService: ble.GattService | null = this.getPrimaryService(services, characteristic);

    // see: BmCharacteristicData
    let response: Map<string, Object> = new Map<string, Object>();
    response.set("remote_id", address);
    if (primaryService != null) {
      response.set("primary_service_uuid", this.uuidStr(primaryService.serviceUuid));
    }
    response.set("service_uuid", this.uuidStr(characteristic.serviceUuid));
    response.set("characteristic_uuid", this.uuidStr(characteristic.characteristicUuid));
    let instanceId: number = FlutterBluePlusOhosPlugin.getInstanceId(characteristic, services);
    response.set("instance_id", instanceId);
    response.set("value", new Uint8Array(characteristic.characteristicValue));
    response.set("success", 1);
    response.set("error_code", 0);
    response.set("error_string", "GATT_SUCCESS");
    this.channel?.invokeMethod("OnCharacteristicReceived", response)
  }

  getPrimaryService(services: ble.GattService[], characteristic: ble.BLECharacteristic): ble.GattService | null {
    let service: ble.GattService | null = null;
    for (let i = 0; i < services.length; i++) {
      if (services[i].serviceUuid === characteristic.serviceUuid) {
        service = services[i]
      }
    }
    if (!service) {
      return null;
    }
    if (service?.isPrimary) {
      return null;
    }
    for (let i = 0; i < services.length; i++) {
      let primaryService = services[i];
      if (primaryService.includeServices) {
        for (let j = 0; j < primaryService.includeServices.length; j++) {
          let secondaryService = primaryService.includeServices[j];
          if (secondaryService.serviceUuid === service?.serviceUuid) {
            return primaryService;
          }
        }
      }
    }
    return null;
  }

  readAndWriteServicePair(services: ble.GattService[], characteristic: ble.BLECharacteristic): ServicePair {
    let result: ServicePair = new ServicePair();
    let service: ble.GattService | null = null;
    for (let i = 0; i < services.length; i++) {
      if (services[i].serviceUuid === characteristic.serviceUuid) {
        service = services[i]
      }
    }
    if (service?.isPrimary) {
      result.primary = service.serviceUuid;
      return result;
    }
    for (let i = 0; i < services.length; i++) {
      if (services[i].includeServices) {
        let secondService: ble.GattService[] = services[i].includeServices as ble.GattService[]
        for (let j = 0; j < secondService.length; j++) {
          if (secondService[i].serviceUuid === service?.serviceUuid) {
            result.primary = services[i].serviceUuid
            result.secondary = secondService[j].serviceUuid
          }
        }
      }
    }
    return result;
  }


  typedArrayToBuffer(array: Uint8Array): ArrayBuffer {
    return array.buffer.slice(array.byteOffset, array.byteLength + array.byteOffset)
  }

  getDescriptorFromArray(uuid: string, array: Array<ble.BLEDescriptor>): ble.BLEDescriptor | null {
    for (let i = 0; i < array.length; i++) {
      if (this.uuid128(array[i].descriptorUuid) === this.uuid128(uuid)) {
        return array[i]
      }
    }
    return null;
  }

  getReadDescriptorFromArray(uuid: string, array: Array<ble.BLEDescriptor>): ble.BLEDescriptor | null {
    for (let i = 0; i < array.length; i++) {
      if (this.uuid128(array[i].descriptorUuid) === this.uuid128(uuid)) {
        return array[i]
      }
    }
    return null;
  }

  private static getInstanceId(target: ble.BLECharacteristic, services: Array<ble.GattService>): number {
    let targetService: ble.GattService | undefined;
    let indexForTarget = 0;
    const apiVersion: number = deviceInfo.sdkApiVersion;
    for (let service of services) {
      if (service.characteristics) {
        for (let i = 0; i < service.characteristics.length; i++) {
          let char = service.characteristics[i];
          let isMatch = false;

          if (char.characteristicUuid === target.characteristicUuid) {
            if (apiVersion >= 18) {
              isMatch = char.characteristicValueHandle === target.characteristicValueHandle;
            } else {
              isMatch = (
                char.properties?.toString() === target.properties?.toString() &&
                  char.descriptors?.length === target.descriptors?.length
              );
            }
          }

          if (isMatch) {
            targetService = service;
            indexForTarget = i;
            break;
          }
        }
        if (targetService) {
          break;
        }
      }
    }

    if (!targetService || !targetService.characteristics) {
      return 0;
    }
    const needle = target.characteristicUuid;
    const list = targetService.characteristics;
    let sameUuidCount = 0;

    for (let c of list) {
      if (c.characteristicUuid === needle) {
        sameUuidCount++;
      }
    }
    return (sameUuidCount > 1) ? indexForTarget + 1 : 0;
  }

  async locateCharacteristic(primaryServiceUuid: string, serviceUuid: string,
    characteristicUuid: string, instanceId: number, gattServices: ble.GattService[]): Promise<ChrFound | undefined> {
    // remember this
    let isSecondaryService: boolean = primaryServiceUuid != null;
    // primary service
    if (primaryServiceUuid == null) {
      primaryServiceUuid = serviceUuid;
    }
    // primary
    let primaryService = this.getServiceFromArray(primaryServiceUuid, gattServices);
    if (primaryService == null) {
      let result: ChrFound = new ChrFound(null, "primary service not found '" + primaryServiceUuid + "'");
      return result;
    }
    // secondary
    let secondaryService: ble.GattService | null = null;
    if (isSecondaryService) {
      if (primaryService.includeServices) {
        secondaryService = this.getServiceFromArray(serviceUuid, primaryService.includeServices);
      }
      if (secondaryService == null) {
        return new ChrFound(null,
          "secondary service not found '" + serviceUuid + "' (primary service '" + primaryServiceUuid + "')");
      }
    }
    // which service?
    let service: ble.GattService = (secondaryService != null) ? secondaryService : primaryService;
    // characteristic
    let characteristic: ble.BLECharacteristic | null =
      this.getCharacteristicFromArray(characteristicUuid, service.characteristics, gattServices, instanceId);
    if (characteristic == null) {
      return new ChrFound(null, "characteristic not found in service " +
        "(chr: '" + characteristicUuid + "' svc: '" + serviceUuid + "')");
    }
    return new ChrFound(characteristic, null);
  }

  getServiceFromArray(uuid: string, array: Array<ble.GattService>): ble.GattService | null {
    for (let i = 0; i < array.length; i++) {
      if (this.uuid128(uuid) === this.uuid128(array[i].serviceUuid)) {
        return array[i];
      }
    }
    return null;
  }

  getCharacteristicFromArray(uuid: string, array: Array<ble.BLECharacteristic>, services: Array<ble.GattService>,
    instanceId: number): ble.BLECharacteristic | null {
    let targetUuid = this.uuid128(uuid);
    let matchingChars: Array<ble.BLECharacteristic> = [];
    for (let characteristic of array) {
      if (this.uuid128(characteristic.characteristicUuid) === targetUuid) {
        matchingChars.push(characteristic);
      }
    }
    if (matchingChars.length === 0) {
      return null;
    }
    if (matchingChars.length === 1) {
      return matchingChars[0];
    }
    if (instanceId === 0) {
      return matchingChars[0];
    }
    for (let characteristic of matchingChars) {
      let charInstanceId: number = FlutterBluePlusOhosPlugin.getInstanceId(characteristic, services);
      if (charInstanceId === instanceId) {
        return characteristic;
      }
    }
    let index = instanceId - 1;
    if (index >= 0 && index < matchingChars.length) {
      return matchingChars[index];
    }
    return matchingChars[0];
  }

  uuid128(uuid: string): string {
    if (uuid.length === 4) {
      // 16-bit uuid
      return `0000${uuid}-0000-1000-8000-00805f9b34fb`.toLowerCase();
    } else if (uuid.length === 8) {
      // 32-bit uuid
      return `${uuid}-0000-1000-8000-00805f9b34fb`.toLowerCase();
    } else {
      // 128-bit uuid
      return uuid.toLowerCase();
    }
  }

  uuidStr(uuid: string): string {
    uuid = this.uuid128(uuid)
    let starts: boolean = uuid.startsWith("0000");
    let ends: boolean = uuid.endsWith("-0000-1000-8000-00805f9b34fb");
    if (starts && ends) {
      // 16-bit
      return uuid.substring(4, 8);
    } else if (ends) {
      // 32-bit
      return uuid.substring(0, 8);
    } else {
      // 128-bit
      return uuid;
    }
  }

  private deviceServicesMap: Map<string, ble.GattService[]> = new Map();
  onScanResult = async (data: Array<ble.ScanResult>) => {
    await this.scanCallback(data);
  }
  onCharacteristicChange = async (characteristicChangeReq: ble.BLECharacteristic) => {
    let entries = this.mConnectedDevices.entries();
    let entry = entries.next();
    while (!entry.done) {
      let deviceId = entry.value[0];
      let gatt = entry.value[1];
      try {
        let services = this.deviceServicesMap.get(deviceId);
        if (!services) {
          services = await gatt.getServices();
          this.deviceServicesMap.set(deviceId, services);
        }
        let serviceIndex = 0;
        while (serviceIndex < services.length) {
          let service = services[serviceIndex];
          if (service.characteristics) {
            let charIndex = 0;
            while (charIndex < service.characteristics.length) {
              let char = service.characteristics[charIndex];
              if (char.characteristicUuid === characteristicChangeReq.characteristicUuid &&
                char.serviceUuid === characteristicChangeReq.serviceUuid) {
                this.onCharacteristicReceived(deviceId, services, characteristicChangeReq);
                return;
              }
              charIndex++;
            }
          }
          serviceIndex++;
        }
      } catch (e) {
        this.log(hilog.LogLevel.ERROR, `onCharacteristicChanged: Failed to process characteristic change: ${JSON.stringify(e)}`);
      }
      entry = entries.next();
    }
  }
  ConnectStateChanged = (state: ble.BLEConnectionChangeState) => {
    if (state.state != constant.ProfileConnectionState.STATE_CONNECTED &&
      state.state != constant.ProfileConnectionState.STATE_DISCONNECTED) {
      return;
    }
    if (state.state == constant.ProfileConnectionState.STATE_CONNECTED) {
      this.mConnectedDevices.set(state.deviceId as string, this.clientDevice as ble.GattClientDevice);
      this.mCurrentlyConnectingDevices.delete(this.remoteId as string);
      this.mMtu.set(this.remoteId as string, 23)
      if (this.clientDevice != null) {
        this.clientDevice.on('BLEMtuChange', this.onMtuChanged);
      }
      this.readDeviceName(state.deviceId as string);
    }

    if (state.state == constant.ProfileConnectionState.STATE_DISCONNECTED) {
      if (this.clientDevice != null) {
        this.clientDevice.off('BLEMtuChange', this.onMtuChanged);
        this.clientDevice.off('BLEConnectionStateChange', this.ConnectStateChanged);
        this.clientDevice.off('BLECharacteristicChange', this.onCharacteristicChange);
      }
      this.mConnectedDevices.delete(this.remoteId as string);
      this.mCurrentlyConnectingDevices.delete(this.remoteId as string);
      this.mBondingDevices.delete(this.remoteId as string);
      this.mBondingPins.delete(this.remoteId as string);
      if (!this.mAutoConnected.has(this.remoteId as string)) {
        if (this.clientDevice != null) {
          this.clientDevice.close();
        }
      }
    }
    let response: Map<string, string | number> = new Map();
    let connectState: number = this.bmConnectionStateEnum(state.state);
    response.set("remote_id", this.remoteId as string);
    response.set("connection_state", connectState);

    if (state.state != constant.ProfileConnectionState.STATE_CONNECTED) {
      response.set("disconnect_reason_code", 1)
      response.set("disconnect_reason_string", TextUtils.hciStatusString(1))
    }
    this.channel?.invokeMethod("OnConnectionStateChanged", response);
  }
  onMtuChanged = (mtu: number) => {
    let remoteId: string = this.remoteId as string;
    this.mMtu.set(remoteId, mtu);
    let response: Map<string, object | string | number> = new Map<string, object>();
    response.set("remote_id", remoteId);
    response.set("mtu", mtu);
    response.set("success", 1);
    response.set("error_code", 0);
    response.set("error_string", "GATT_SUCCESS");
    this.channel?.invokeMethod("OnMtuChanged", response);
  }

  async readDeviceName(remoteId: string) {
    try {
      let gatt: ble.GattClientDevice | undefined = this.mConnectedDevices.get(remoteId);
      if (gatt == null) {
        return;
      }
      let services: ble.GattService[] = await gatt.getServices();
      let gapService: ble.GattService | undefined;
      for (let service of services) {
        if (this.uuidStr(service.serviceUuid) == "1800") {
          gapService = service;
          break;
        }
      }
      if (gapService == null) {
        return;
      }
      let deviceNameChar: ble.BLECharacteristic | undefined;
      for (let characteristic of gapService.characteristics) {
        if (this.uuidStr(characteristic.characteristicUuid) == "2a00") {
          deviceNameChar = characteristic;
          break;
        }
      }
      if (deviceNameChar == null) {
        return;
      }
      let readCharacteristic: ble.BLECharacteristic = await gatt.readCharacteristicValue(deviceNameChar);
      let deviceName: string =
        this.utf8BytesToString(Array.from(new Uint8Array(readCharacteristic.characteristicValue)));
      let response: Map<string, string> = new Map();
      response.set("remote_id", remoteId);
      response.set("name", deviceName);
      this.channel?.invokeMethod("OnNameChanged", response);
    } catch (e) {
      this.log(hilog.LogLevel.ERROR, `readDeviceName: Failed to read device name: ${JSON.stringify(e)}`);
    }
  }

  delay(milliseconds: number) {
    return new Promise<void>((resolve) => {
      setTimeout(() => {
        resolve();
      }, milliseconds);
    });
  }

  bmConnectionStateEnum(cs: number): number {
    switch (cs) {
      case constant.ProfileConnectionState.STATE_DISCONNECTED:
        return 0;
      case constant.ProfileConnectionState.STATE_CONNECTED:
        return 1;
      default:
        return 0;
    }
  }

  bmBluetoothDevice(deviceAddress: string, name?: string): Map<string, string> {
    let map: Map<string, string> = new Map();
    map.set("remote_id", deviceAddress)
    if (name) {
      map.set("platform_name", name);
    }
    return map;
  }

  async ensurePermissions(result: MethodResult, errorCode: string): Promise<boolean> {
    let checkPermissionStatus = await this.checkSelfPermission(FlutterBluePlusOhosPlugin.ACCESS_BLUETOOTH_PERMISSION);
    let permissionStatus: boolean = true;
    if (checkPermissionStatus) {
      let isPermission = await this.requestPermissions()
      if (typeof isPermission === 'boolean' && !(isPermission as boolean)) {
        result.success(false);
        permissionStatus = false;
      } else if (typeof isPermission === 'string') {
        result.error(errorCode, isPermission as string, null);
        permissionStatus = false;
      }
    }
    return permissionStatus;
  }

  async requestPermissions(): Promise<boolean | string> {
    let result: boolean | string = false
    let atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    await atManager.requestPermissionsFromUser(this.context, [FlutterBluePlusOhosPlugin.ACCESS_BLUETOOTH_PERMISSION])
      .then((data) => {
        let grantStatus: Array<number> = data.authResults;
        if (grantStatus.length > 0 && grantStatus[0] === 0) {
          result = true;
        } else {
          result = "FlutterBluePlus requires ohos Permission ohos.permission.ACCESS_BLUETOOTH";
        }
      })
      .catch((err: BusinessError) => {
        result = `Failed to request permissions from user. Code is ${err.code}, message is ${err.message}`;
      })
    return result;
  }

  stringToArrayBuffer(str: string): ArrayBuffer {
    const buffers = buffer.from(str, 'utf8');
    return buffers.buffer.slice(buffers.byteOffset, buffers.byteOffset + buffers.length);
  }

  async checkSelfPermission(permission: Permissions): Promise<boolean> {
    let tokenId: number = 0;
    let grantStatus: abilityAccessCtrl.GrantStatus = abilityAccessCtrl.GrantStatus.PERMISSION_DENIED;
    let atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    let bundleInfo: bundleManager.BundleInfo =
      await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
    let appInfo: bundleManager.ApplicationInfo = bundleInfo.appInfo;
    tokenId = appInfo.accessTokenId;
    grantStatus = await atManager.checkAccessToken(tokenId, permission);
    return grantStatus == -1;
  }

  OnDiscoveredServices(gattServices: Array<ble.GattService>, remoteId: string) {
    let services: List<object> = new List<object>();
    gattServices.forEach(s => {
      services.add(this.bmBluetoothService(s, null, remoteId, gattServices));
      s.includeServices?.forEach(s2 => {
        services.add(this.bmBluetoothService(s2, s, remoteId, gattServices))
      })
    })
    // see: BmDiscoverServicesResult
    let response: Map<string, object | string | number> = new Map();
    response.set("remote_id", remoteId as string);
    response.set("services", services);
    response.set("success", 1);
    response.set("error_code", 0);
    response.set("error_string", "GATT_SUCCESS");
    this.channel?.invokeMethod("OnDiscoveredServices", response);
  }

  bmBluetoothService(service: ble.GattService, primaryService: ble.GattService | null, remoteId: string,
    gattServices: Array<ble.GattService>): Map<string, object | string | number> {
    let characteristics: List<object> = new List<object>();
    service.characteristics.forEach((characteristic) => {
      characteristics.add(this.bmBluetoothCharacteristic(remoteId, characteristic, gattServices));
    })
    // See: BmBluetoothService
    let map: Map<string, object | string | number> = new Map();
    map.set("remote_id", remoteId);
    if (primaryService != null) {
      map.set("primary_service_uuid", this.uuidStr(primaryService.serviceUuid));
    }
    map.set("service_uuid", this.uuidStr(service.serviceUuid));
    map.set("characteristics", characteristics);
    return map;
  }

  bmBluetoothCharacteristic(remoteId: string, characteristic: ble.BLECharacteristic,
    gattServices: Array<ble.GattService>): Map<string, object | string | number> {
    let descriptors: List<object> = new List<object>();
    characteristic.descriptors?.forEach((d) => {
      descriptors.add(this.bmBluetoothDescriptor(remoteId, characteristic, d, gattServices));
    })
    // has associated primary service?
    let primaryService: ble.GattService | null = null;
    if (gattServices) {
      primaryService = this.getPrimaryService(gattServices, characteristic);
    }
    let map: Map<string, object | string | number> = new Map<string, object | string | number>();
    map.set("remote_id", remoteId);
    if (primaryService != null) {
      map.set("primary_service_uuid", this.uuidStr(primaryService.serviceUuid));
    }
    map.set("service_uuid", this.uuidStr(characteristic.serviceUuid));
    map.set("characteristic_uuid", this.uuidStr(characteristic.characteristicUuid));
    let instanceId: number = 0;
    if (gattServices) {
      instanceId = FlutterBluePlusOhosPlugin.getInstanceId(characteristic, gattServices);
    }
    map.set("instance_id", instanceId);
    map.set("descriptors", descriptors);
    map.set("properties", this.bmCharacteristicProperties(characteristic));
    return map;
  }

  bmCharacteristicProperties(characteristic: ble.BLECharacteristic): Map<string, Object> {
    let props: Map<string, object | number> = new Map<string, object | number>();
    if (characteristic.properties) {
      characteristic.properties.write ? props.set("write", 1) : props.set("write", 0);
      characteristic.properties.writeNoResponse ? props.set("write_without_response", 1) :
        props.set("write_without_response", 0);
      characteristic.properties.read ? props.set("read", 1) : props.set("read", 0);
      characteristic.properties.notify ? props.set("notify", 1) : props.set("notify", 0);
      characteristic.properties.indicate ? props.set("indicate", 1) : props.set("indicate", 0);
      props.set("broadcast", 0);
      props.set("authenticated_signed_writes", 0);
      props.set("extended_properties", 0);
      props.set("notify_encryption_required", 0);
      props.set("indicate_encryption_required", 0);
    }
    return props
  }

  getServicePair(service: ble.GattService,
    gattServices?: Array<ble.GattService>): ServicePair {
    let result: ServicePair = new ServicePair();
    if (service.isPrimary) {
      result.primary = service.serviceUuid;
      return result;
    }
    if (gattServices) {
      for (let i = 0; i < gattServices.length; i++) {
        let secondary: Array<ble.GattService> = gattServices[i].includeServices as Array<ble.GattService>;
        for (let j = 0; j < secondary.length; j++) {
          if (secondary[j].serviceUuid == service.serviceUuid) {
            result.primary = gattServices[i].serviceUuid;
            result.secondary = secondary[j].serviceUuid;
            return result;
          }
        }
      }
    }
    return result;
  }

  disconnectAllDevices(func: string) {
    // merge connected & autoconnected
    let allDevices: Map<string, ble.GattClientDevice> = new Map();
    this.mConnectedDevices.forEach((value, key) => {
      allDevices.set(key, value);
    });
    this.mAutoConnected.forEach((value, key) => {
      allDevices.set(key, value);
    });
    // request disconnections
    allDevices.forEach((value, key) => {
      if (func == "adapterTurnOff") {
        let state: number = constant.ProfileConnectionState.STATE_DISCONNECTED;
        if (state != constant.ProfileConnectionState.STATE_DISCONNECTED &&
          state != constant.ProfileConnectionState.STATE_CONNECTED) {
          return;
        }
        if (state == constant.ProfileConnectionState.STATE_DISCONNECTED) {
          this.mConnectedDevices.delete(this.remoteId as string);
          this.mCurrentlyConnectingDevices.delete(this.remoteId as string);
          this.mBondingDevices.delete(this.remoteId as string);
          this.mBondingPins.delete(this.remoteId as string);
          if (!this.mAutoConnected.has(key)) {
            value.close();
          }
        }
        let response: Map<string, string | number> = new Map();
        let connectState: number = this.bmConnectionStateEnum(state);
        response.set("remote_id", this.remoteId as string);
        response.set("connection_state", connectState);
        response.set("disconnect_reason_code", 0);
        response.set("disconnect_reason", TextUtils.hciStatusString(0))
        this.channel?.invokeMethod("OnConnectionStateChanged", response);
      } else {
        value.disconnect();
        value.close();
      }
      this.mConnectedDevices.clear();
      this.mCurrentlyConnectingDevices.clear();
      this.mBondingDevices.clear();
      this.mBondingPins.clear();
      this.mMtu.clear();
      this.mWriteChr.clear();
      this.mWriteDesc.clear();
      this.mAutoConnected.clear();
    })
  }

  bmBluetoothDescriptor(remote_id: string, characteristic: ble.BLECharacteristic, descriptor: ble.BLEDescriptor,
    gattServices: Array<ble.GattService>): Map<string, object | string | number> {
    // has associated primary service?
    let primaryService: ble.GattService | null = this.getPrimaryService(gattServices, characteristic);
    let map: Map<string, object | string | number> = new Map<string, object | string | number>();
    map.set("remote_id", remote_id);
    if (primaryService != null) {
      map.set("primary_service_uuid", this.uuidStr(primaryService.serviceUuid));
    }
    map.set("descriptor_uuid", this.uuidStr(descriptor.descriptorUuid));
    map.set("characteristic_uuid", this.uuidStr(descriptor.characteristicUuid));
    map.set("service_uuid", this.uuidStr(descriptor.serviceUuid));
    let instanceId = FlutterBluePlusOhosPlugin.getInstanceId(characteristic!, gattServices);
    map.set("instance_id", instanceId);
    return map;
  }

  bytesToHexArrayBuffer(bytes: Uint8Array): string {
    if (bytes == null) {
      return "";
    }
    let hexString = '';
    for (let i = 0; i < bytes.length; i++) {
      const hex = bytes[i].toString(16);
      hexString += (hex.length === 1 ? '0' : '') + hex;
    }
    return hexString;
  }

  getManufacturerSpecificData(advBytes: Uint8Array): Uint8Array {
    const bytes: Uint8Array = advBytes;
    let output: number[] = [];
    let n = 0;
    while (n < bytes.byteLength) {
      const fieldLen = bytes[n] & 0xFF;
      if (fieldLen <= 0) {
        break;
      }
      if (n + fieldLen >= bytes.byteLength) {
        break;
      }
      const dataType = bytes[n + 1] & 0xFF;
      if (dataType === 0xFF && fieldLen >= 2) {
        const dataStartIndex = n + 2;
        const dataLength = fieldLen - 1;
        for (let i = 0; i < dataLength; i++) {
          output.push(bytes[dataStartIndex + i]);
        }
      }
      n += fieldLen + 1;
    }
    return new Uint8Array(output);
  }

  bytesToHexScan(bytes: Uint8Array): string {
    if (bytes == null) {
      return "";
    }
    let hexString = '';
    for (let i = 0; i < bytes.length; i++) {
      const hex = bytes[i].toString(16);
      hexString += (hex.length === 1 ? '0' : '') + hex;
    }
    return hexString;
  }

  parseAdvHexData(hexString: string): AdvData {
    let result = new AdvData()
    let index: number = 0
    result.serviceUUIDs = []
    result.serviceData = new Map<string, string>()

    while (index < hexString.length) {
      const length = Number.parseInt(hexString.substring(index, index + 2), 16)
      if (length === 0) {
        break
      }
      const type = Number.parseInt(hexString.substring(index + 2, index + 4), 16)
      const data = hexString.substring(index + 4, index + 4 + (length * 2 - 2))
      switch (type) {
        case 0x01:
          result.flags = data
          break
        case 0x02: // Incomplete List of 16-bit Service UUIDs
        case 0x03: // Complete List of 16-bit Service UUIDs
          for (let i = 0; i < data.length; i += 4) {
            if (i + 4 <= data.length) {
              let uuid16LittleEndian = data.substring(i, i + 4)
              let uuid16BigEndian = uuid16LittleEndian.substring(2, 4) + uuid16LittleEndian.substring(0, 2)
              let fullUuid = this.uuid128(uuid16BigEndian)
              result.serviceUUIDs?.push(fullUuid)
            }
          }
          break
        case 0x04: // Incomplete List of 32-bit Service UUIDs
        case 0x05: // Complete List of 32-bit Service UUIDs
          for (let i = 0; i < data.length; i += 8) {
            if (i + 8 <= data.length) {
              let uuid32LittleEndian = data.substring(i, i + 8)
              let uuid32BigEndian = uuid32LittleEndian.substring(6, 8) + uuid32LittleEndian.substring(4, 6) +
              uuid32LittleEndian.substring(2, 4) + uuid32LittleEndian.substring(0, 2)
              let fullUuid = this.uuid128(uuid32BigEndian)
              result.serviceUUIDs?.push(fullUuid)
            }
          }
          break
        case 0x06: // Incomplete List of 128-bit Service UUIDs
        case 0x07: // Complete List of 128-bit Service UUIDs
          for (let i = 0; i < data.length; i += 32) {
            if (i + 32 <= data.length) {
              let uuid128LittleEndian = data.substring(i, i + 32)
              let reversedBytes = "";
              for (let j = uuid128LittleEndian.length - 2; j >= 0; j -= 2) {
                reversedBytes += uuid128LittleEndian.substring(j, j + 2);
              }
              let formattedUuid =
                `${reversedBytes.substring(0, 8)}-${reversedBytes.substring(8, 12)}-${reversedBytes.substring(12,
                  16)}-${reversedBytes.substring(16, 20)}-${reversedBytes.substring(20, 32)}`;
              result.serviceUUIDs?.push(formattedUuid.toLowerCase());
            }
          }
          break
        case 0x08: // Short Local Name
        case 0x09: // Complete Local Name
          let nameBytes: number[] = [];
          for (let i = 0; i < data.length; i += 2) {
            nameBytes.push(Number.parseInt(data.substring(i, i + 2), 16));
          }
          let name: string = this.utf8BytesToString(nameBytes);
          result.localName = name
          break
        case 0x0A: // TX Power Level
          if (data.length >= 2) {
            let txPower = Number.parseInt(data.substring(0, 2), 16)
            if (txPower > 127) {
              txPower -= 256
            }
            result.txPowerLevel = txPower
          }
          break
        case 0x16: // Service Data - 16-bit UUID
          if (data.length >= 4) {
            let uuid16LittleEndian = data.substring(0, 4)
            let uuid16BigEndian = uuid16LittleEndian.substring(2, 4) + uuid16LittleEndian.substring(0, 2)
            let fullUuid = this.uuid128(uuid16BigEndian)
            let serviceDataHex = data.substring(4)
            result.serviceData?.set(fullUuid, serviceDataHex)
          }
          break
        case 0x20: // Service Data - 32-bit UUID
          if (data.length >= 8) {
            let uuid32LittleEndian = data.substring(0, 8)
            let uuid32BigEndian = uuid32LittleEndian.substring(6, 8) + uuid32LittleEndian.substring(4, 6) +
            uuid32LittleEndian.substring(2, 4) + uuid32LittleEndian.substring(0, 2)
            let fullUuid = this.uuid128(uuid32BigEndian)
            let serviceDataHex = data.substring(8)
            result.serviceData?.set(fullUuid, serviceDataHex)
          }
          break
        case 0x21: // Service Data - 128-bit UUID
          if (data.length >= 32) {
            let uuid128LittleEndian = data.substring(0, 32)
            let reversedBytes = "";
            for (let j = uuid128LittleEndian.length - 2; j >= 0; j -= 2) {
              reversedBytes += uuid128LittleEndian.substring(j, j + 2);
            }
            let formattedUuid =
              `${reversedBytes.substring(0, 8)}-${reversedBytes.substring(8, 12)}-${reversedBytes.substring(12,
                16)}-${reversedBytes.substring(16, 20)}-${reversedBytes.substring(20, 32)}`;
            let serviceDataHex = data.substring(32)
            result.serviceData?.set(formattedUuid.toLowerCase(), serviceDataHex)
          }
          break
        case 0x19: // Appearance
          if (data.length >= 4) {
            let appearanceLittleEndian = data.substring(0, 4)
            let appearanceBigEndian = appearanceLittleEndian.substring(2, 4) + appearanceLittleEndian.substring(0, 2)
            let appearance = Number.parseInt(appearanceBigEndian, 16)
            result.appearance = appearance
          }
          break
        default:
          break
      }
      index += (length + 1) * 2
    }
    return result
  }

  async scanCallback(data: Array<ble.ScanResult>) {
    let item = data[0];
    let remoteId: string = item.deviceId;
    let scanData: Uint8Array = new Uint8Array(item.data);
    let advHex: string = HexUtil.formatHexString(scanData);
    if (this.mScanFilters.get("continuous_updates") as boolean == false) {
      if (this.mAdvSeen.has(remoteId)) {
        return;
      }
      this.mAdvSeen.set(remoteId, advHex);
    }
    let device: BleDevice =
      new BleDevice(item.deviceId, "", item.rssi, scanData, new Date().getTime(),
        item.connectable);
    let advDataSource = this.parseAdvHexData(advHex);
    let deviceName: string = advDataSource.localName || "";
    if (deviceName === "") {
      try {
        let gattClient = ble.createGattClientDevice(device.getMac());
        deviceName = await gattClient.getDeviceName();
      } catch (e) {
        deviceName = "";
      }
    }
    device.setName(deviceName);
    let name: string = device.getName() != null ? device.getName() : "";
    let keywords: List<string> = this.mScanFilters.get("with_keywords") as List<string>;
    if (this.filterKeywords(keywords, name) == false) {
      return;
    }
    if (this.mScanFilters.get("continuous_updates") as boolean != false) {
      let count: number = this.scanCountIncrement(remoteId);
      let divisor: number = this.mScanFilters.get("continuous_divisor") as number;
      if ((count % divisor) != 0) {
        return;
      }
    }
    let manufDataB: Map<number, Uint8Array> = new Map<number, Uint8Array>();

    let uint8_msg = scanData;
    let rawMsd: Uint8Array = this.getManufacturerSpecificData(uint8_msg);
    if (rawMsd != null && rawMsd.length >= 2) {
      let manufacturerId = (rawMsd[0] & 0xFF) | ((rawMsd[1] & 0xFF) << 8);
      let payload: Uint8Array = new Uint8Array(0);
      let payloadLen: number = rawMsd.length - 2;
      payload = new Uint8Array(payloadLen);
      for (let i = 0; i < payloadLen; i++) {
        payload[i] = rawMsd[i + 2];
      }
      manufDataB.set(manufacturerId, payload);
    }
    let response: Map<string, Object> = new Map<string, Object>();
    let deviceList: List<Map<string, Object>> = new List<Map<string, Object>>();
    let map: Map<string, Object> = new Map();
    map.set("manufacturer_data", manufDataB);
    if (device.getName() != null) {
      map.set("platform_name", device.getName());
    } else {
      map.set("platform_name", "");
    }
    if (device.getMac() != null) {
      map.set("remote_id", device.getMac());
    }
    if (device.getConnectable()) {
      map.set("connectable", device.getConnectable());
    }
    if (device.getRssi() != 0) {
      map.set("rssi", device.getRssi());
    }
    if (advDataSource.localName != null) {
      map.set("adv_name", advDataSource.localName);
    }
    const min: number = -2147483648;
    if (advDataSource.txPowerLevel != null && advDataSource.txPowerLevel != min) {
      map.set("tx_power_level", advDataSource.txPowerLevel);
    }
    if (advDataSource.appearance != null && advDataSource.appearance != 0) {
      map.set("appearance", advDataSource.appearance);
    }
    if (advDataSource.serviceUUIDs != null && advDataSource.serviceUUIDs.length > 0) {
      let serviceUuidsList: List<string> = new List<string>();
      for (let uuid of advDataSource.serviceUUIDs) {
        serviceUuidsList.add(uuid);
      }
      map.set("service_uuids", serviceUuidsList);
    }
    if (advDataSource.serviceData != null && advDataSource.serviceData.size > 0) {
      let serviceDataMap: Map<string, Uint8Array> = new Map<string, Uint8Array>();
      advDataSource.serviceData.forEach((hexValue, uuid) => {
        let byteArray: number[] = [];
        for (let i = 0; i < hexValue.length; i += 2) {
          if (i + 2 <= hexValue.length) {
            let byte = Number.parseInt(hexValue.substring(i, i + 2), 16);
            byteArray.push(byte);
          }
        }
        serviceDataMap.set(uuid, new Uint8Array(byteArray));
      });
      map.set("service_data", serviceDataMap);
    }

    try {
      deviceList.add(map);
    } catch (error) {
      this.log(hilog.LogLevel.ERROR, `addDeviceToList: Failed to add device to list: ${JSON.stringify(error)}`);
    }
    response.set("advertisements", deviceList);
    if (this.channel != null) {
      this.channel.invokeMethod("OnScanResponse", response);
    }
  }

  bmAdapterStateEnum(as: number): number {
    switch (as) {
      case access.BluetoothState.STATE_OFF:
        return 6;
      case access.BluetoothState.STATE_ON:
        return 4;
      case access.BluetoothState.STATE_TURNING_OFF:
        return 5;
      case access.BluetoothState.STATE_TURNING_ON:
        return 3;
      default:
        return 0;
    }
  }

  isAdapterOn(): boolean {
    try {
      return access.getState() == access.BluetoothState.STATE_ON;
    } catch (e) {
      return false;
    }
  }

  utf8BytesToString(bytes: number[]): string {
    let result = '';
    let i = 0;
    while (i < bytes.length) {
      let byte = bytes[i];
      let codePoint: number;

      if (byte < 0x80) {
        codePoint = byte;
        i++;
      } else if (byte < 0xE0) {
        codePoint = ((byte & 0x1F) << 6) | (bytes[i + 1] & 0x3F);
        i += 2;
      } else if (byte < 0xF0) {
        codePoint = ((byte & 0x0F) << 12) | ((bytes[i + 1] & 0x3F) << 6) | (bytes[i + 2] & 0x3F);
        i += 3;
      } else {
        codePoint =
          ((byte & 0x07) << 18) | ((bytes[i + 1] & 0x3F) << 12) | ((bytes[i + 2] & 0x3F) << 6) | (bytes[i + 3] & 0x3F);
        i += 4;
      }

      result += String.fromCodePoint(codePoint);
    }
    return result;
  }

  onReceiveEvent(data: access.BluetoothState) {
    if (this.isAdapterOn()) {
      let map: Map<string, boolean> = new Map();
      map.set("user_accepted", true);
      this.channel?.invokeMethod("OnTurnOnResponse", map);
    }
    let map: Map<string, object | number> = new Map();
    map.set("adapter_state", this.bmAdapterStateEnum(data));
    this.channel?.invokeMethod("OnAdapterStateChanged", map);
    if (data == access.BluetoothState.STATE_BLE_TURNING_OFF ||
      data == access.BluetoothState.STATE_OFF) {
      this.disconnectAllDevices("adapterTurnOff");
    }
  }

  scanCountIncrement(remoteId: string) {
    if (this.mScanCounts.get(remoteId) == null) {
      this.mScanCounts.set(remoteId, 0);
    }
    let count: number = this.mScanCounts.get(remoteId) as number;
    this.mScanCounts.set(remoteId, count + 1);
    return count;
  }

  filterKeywords(keywords: List<string>, target: string): boolean {
    if (keywords.length == 0 || keywords == null) {
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

  log(level: hilog.LogLevel, message: string) {
    if (level < this.loglevel) {
      return;
    }
    switch (level) {
      case hilog.LogLevel.DEBUG:
        hilog.debug(DOMAIN, TAG, message);
        break;
      case hilog.LogLevel.INFO:
        hilog.info(DOMAIN, TAG, message);
        break;
      case hilog.LogLevel.WARN:
        hilog.warn(DOMAIN, TAG, message);
        break;
      case hilog.LogLevel.ERROR:
        hilog.error(DOMAIN, TAG, message);
        break;
      case hilog.LogLevel.FATAL:
        hilog.fatal(DOMAIN, TAG, message);
        break;
      default:
        hilog.debug(DOMAIN, TAG, message);
        break;
    }
  }
}

class ChrFound {
  public characteristic: ble.BLECharacteristic | null = null;
  public error: string | null = null;

  constructor(characteristic: ble.BLECharacteristic | null, error: string | null) {
    this.characteristic = characteristic;
    this.error = error;
  }
}

class ServicePair {
  primary: string | null = null;
  secondary: string | null = null;
}

class AdvData {
  flags: string | null = null;
  serviceUUIDs: string[] | null = null;
  localName: string | null = null;
  txPowerLevel: number | null = null;
  appearance: number | null = null;
  serviceData: Map<string, string> | null = null;
}
