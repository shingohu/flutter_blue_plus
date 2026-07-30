import Flutter
import UIKit
import CoreBluetooth

public class BLEPermissionPlugin: NSObject, FlutterPlugin {
    
    
    
 var bluetoothAdapterCallback:PermissionCallback?
    var bluetoothPermissionCallback:PermissionCallback?
    
    var channel:FlutterMethodChannel?
    
    
    
    
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "ble_permission", binaryMessenger: registrar.messenger())
    let instance = BLEPermissionPlugin()
    instance.channel = channel
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.addApplicationDelegate(instance)
    BLEPermissionManager.INSTANCE.setStateCallbackListener { state in
          channel.invokeMethod("onBluetoothAdapterStateChanged", arguments: state == .poweredOn)
    }
  }
    


    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let method = call.method
        if(method == "isBluetoothAdapterEnable"){
            
            BLEPermissionManager.INSTANCE.isBluetoothAdapterEnable { state in
                result(state == .poweredOn)
            }
        }else if(method == "requestPermission"){
            requestPermission(result: result)
        }else if(method == "openBluetoothAdapter"){
            openBluetoothAdapter(result: result)
        }else if(method == "isReady"){
            let hasPermission = BLEPermissionManager.INSTANCE.hasPermission()
            BLEPermissionManager.INSTANCE.isBluetoothAdapterEnable { state in
                result(hasPermission&&state == .poweredOn)
            }
        }else if(method == "checkPermission"){
            result(BLEPermissionManager.INSTANCE.hasPermission())
        }else if(method == "openPermission"){
            openBluetoothPermission(result: result)
        }else if(method == "isPersonalHotspotEnabled"){
            result(self.isPersonalHotspotEnabled)
        }

    }
    
    public func applicationDidBecomeActive(_ application: UIApplication) {
        if(bluetoothAdapterCallback != nil){
            bluetoothAdapterCallback!(BLEPermissionManager.INSTANCE.isBluetoothAdapterEnable())
            bluetoothAdapterCallback = nil
        }
        if(bluetoothPermissionCallback != nil){
            bluetoothPermissionCallback!(BLEPermissionManager.INSTANCE.hasPermission())
            bluetoothPermissionCallback = nil
        }
    }
    
   
    
    
    
    private func openBluetoothAdapter(result:@escaping FlutterResult){
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            result(false)
            return
        }
        if (UIApplication.shared.canOpenURL(url)) {
            bluetoothAdapterCallback = { hasOpen in
                result(hasOpen)
            }
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }else{
            result(false)
        }
        
    }
    
    
    private func openBluetoothPermission(result:@escaping FlutterResult){
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            result(false)
            return
        }
        if (UIApplication.shared.canOpenURL(url)) {
            bluetoothPermissionCallback = { hasPermission in
                result(hasPermission)
            }
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }else{
            result(false)
        }
        
    }
    
   
    
    
    func requestPermission(result:@escaping FlutterResult){
        BLEPermissionManager.INSTANCE.requestPermission { hasPermission in
               result(hasPermission)
           }
       }
    
    
    
    
    /// 判断当前是否开启了个人热点（最准确：检测 bridge 虚拟网卡）
        var isPersonalHotspotEnabled: Bool {
            var isHotspotOn = false
            var interfaces: UnsafeMutablePointer<ifaddrs>? = nil
            
            // 获取网卡列表
            guard getifaddrs(&interfaces) == 0 else { return false }
            defer { freeifaddrs(interfaces) } // 确保释放内存
            
            var currentInterface = interfaces
            while currentInterface != nil {
                defer { currentInterface = currentInterface?.pointee.ifa_next }
                guard let name = currentInterface?.pointee.ifa_name else {
                    continue
                }
                
                let interfaceName = String(cString: name)
                // 个人热点开启时，系统会创建 bridge 开头的虚拟网卡
                if interfaceName.hasPrefix("bridge") {
                    isHotspotOn = true
                    break
                }
            }
            
            return isHotspotOn
        }
    
    
}
