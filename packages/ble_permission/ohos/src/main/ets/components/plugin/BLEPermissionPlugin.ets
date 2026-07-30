import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
  AbilityAware,
  AbilityPluginBinding
} from '@ohos/flutter_ohos';
import { access } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { abilityAccessCtrl, bundleManager, common, Context, Permissions } from '@kit.AbilityKit';

/** BLEPermissionPlugin **/
export default class BLEPermissionPlugin implements FlutterPlugin, MethodCallHandler,AbilityAware {
  private channel: MethodChannel | null = null;
  private context: Context | null = null;

  constructor() {
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    this.context = binding.getAbility().context;
  }

  onDetachedFromAbility(): void {
    this.context = null
  }

  getUniqueClassName(): string {
    return "BLEPermissionPlugin"
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), "ble_permission");
    this.channel.setMethodCallHandler(this)
    this.registerBluetoothState()
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.channel != null) {
      this.channel.setMethodCallHandler(null)
    }
    this.unRegisterBluetoothState()
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method == "isBluetoothAdapterEnable") {
      ///判断蓝牙适配器是否已开启
      result.success(this.isBluetoothAdapterEnable())
    } else if (call.method == "openBluetoothAdapter") {
      ///打开蓝牙适配器
      result.success(this.openBluetoothAdapter())
    } else if (call.method == "checkPermission") {
      ///判断是否有权限
      result.success(this.checkPermission())
    } else if (call.method == "isReady") {
      ///判断权限和适配器都处于开启状态
      result.success(this.isReady())
    } else if (call.method == "requestPermission") {
      ///请求蓝牙权限
      this.requestPermission().then((grant) => {
        result.success(grant)
      })
    } else if (call.method == "openPermission") {
      ///打开蓝牙设置页面
      this.openPermission().then((grant) => {
        result.success(grant)
      });
    } else {
      result.notImplemented()
    }
  }

  ///打开蓝牙设置页面
  async openPermission() {
    try {
      let atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      if (this.context != null) {
        let results = await atManager.requestPermissionOnSetting(this.context, ['ohos.permission.ACCESS_BLUETOOTH'])
        if (results.length > 0) {
          let grant = results[0]
          return grant == abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED
        }
      }
    } catch (err) {
      console.error('errCode: ' + (err as BusinessError).code + ', errMessage: ' + (err as BusinessError).message);
    }
    return this.checkPermission()
  }


  async requestPermission() {
    try {
      let atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      if (this.context != null) {
        let results = await atManager.requestPermissionsFromUser(this.context, ['ohos.permission.ACCESS_BLUETOOTH'])
        if (results.authResults.length > 0) {
          let grant = results.authResults[0]
          return grant == abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED
        }
      }
    } catch (err) {
      console.error('errCode: ' + (err as BusinessError).code + ', errMessage: ' + (err as BusinessError).message);
    }
    return false
  }


  ///判断是否有蓝牙权限
  checkPermission(): boolean {
    let grantStatus: abilityAccessCtrl.GrantStatus =
      this.checkPermissionGrant("ohos.permission.ACCESS_BLUETOOTH");
    return grantStatus == abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
  }


  isReady(): boolean {
    if (this.checkPermission()) {
      return this.isBluetoothAdapterEnable()
    }
    return false
  }


  checkPermissionGrant(permission: Permissions): abilityAccessCtrl.GrantStatus {
    let atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    let grantStatus: abilityAccessCtrl.GrantStatus = abilityAccessCtrl.GrantStatus.PERMISSION_DENIED;

    // 获取应用程序的accessTokenID。
    let tokenId: number = 0;
    try {
      let bundleInfo: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      let appInfo: bundleManager.ApplicationInfo = bundleInfo.appInfo;
      tokenId = appInfo.accessTokenId;
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      console.error(`Failed to get bundle info for self. Code is ${err.code}, message is ${err.message}`);
    }

    // 校验应用是否被授予权限。
    try {
      grantStatus = atManager.checkAccessTokenSync(tokenId, permission);
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      console.error(`Failed to check access token. Code is ${err.code}, message is ${err.message}`);
    }

    return grantStatus;
  }


  isBluetoothAdapterEnable(): boolean {
    try {
      let state = access.getState();
      if (state == access.BluetoothState.STATE_OFF || state == access.BluetoothState.STATE_TURNING_OFF) {
        return false
      } else if (state == access.BluetoothState.STATE_TURNING_ON || state == access.BluetoothState.STATE_ON) {
        return true
      }
    } catch (err) {
      console.error('errCode: ' + (err as BusinessError).code + ', errMessage: ' + (err as BusinessError).message);
    }
    return false
  }

  openBluetoothAdapter(): boolean {
    try {
      if (this.isBluetoothAdapterEnable()) {
        return true
      }
      access.enableBluetooth()
    } catch (err) {
      console.error('errCode: ' + (err as BusinessError).code + ', errMessage: ' + (err as BusinessError).message);
    }
    return this.isBluetoothAdapterEnable()

  }


  registerBluetoothState() {
    try {
      // 发起订阅
      access.on('stateChange', this.onReceiveEvent);
    } catch (err) {
      console.error('errCode: ' + (err as BusinessError).code + ', errMessage: ' + (err as BusinessError).message);
    }
  }


  // 定义蓝牙开关状态变化函数回调
  onReceiveEvent(data: access.BluetoothState) {
    if (data == access.BluetoothState.STATE_OFF) {
      this.channel?.invokeMethod("onBluetoothAdapterStateChanged", false)
    } else if (data == access.BluetoothState.STATE_ON) {
      this.channel?.invokeMethod("onBluetoothAdapterStateChanged", true)
    }
  }


  unRegisterBluetoothState() {
    try {
      access.off('stateChange')
    } catch (err) {
      console.error('errCode: ' + (err as BusinessError).code + ', errMessage: ' + (err as BusinessError).message);
    }
  }
}