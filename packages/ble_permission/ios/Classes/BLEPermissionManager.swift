//
//  BLEManager.swift
//  ble
//
//  Created by shingohu on 2023/9/22.
//

import UIKit
import CoreBluetooth


typealias PermissionCallback = (Bool) -> ()
typealias CBManagerStateCallback = (CBManagerState) -> ()

class BLEPermissionManager: NSObject,CBCentralManagerDelegate {
    
    
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if(self.stateCallback != nil){
            self.stateCallback!(central.state)
        }
        if(self.stateCallbackListener != nil){
            self.stateCallbackListener!(central.state)
        }
        if(self.stateAdapterCallback != nil){
            self.stateAdapterCallback!(central.state)
            self.stateAdapterCallback = nil
        }
    }
    

    
    static let INSTANCE:BLEPermissionManager = BLEPermissionManager()
    
    
    
    private lazy var centralManager = { () -> CBCentralManager in
           let bundleId =  Bundle.main.bundleIdentifier!
        return CBCentralManager(delegate: self, queue: .main,options:[
            CBCentralManagerOptionShowPowerAlertKey : true,//弹出链接新设备的系统弹窗
        ])
       }()
    
    
    
    
    
    public func isBluetoothAdapterEnable()->Bool{
        return centralManager.state == .poweredOn
    }
    
    
    
    ///有可能第一次是unknown
    public func isBluetoothAdapterEnable(stateCallback:@escaping CBManagerStateCallback){
        if(centralManager.state == CBManagerState.unknown){
            ///第一次可能为unknown
            self.stateAdapterCallback = { state in
                stateCallback(state)
            }
        }else{
            stateCallback(centralManager.state)
        }
    }
    
    public func hasPermission()->Bool{
        if #available(iOS 13.1, *) {
            if( CBCentralManager.authorization == .allowedAlways || CBCentralManager.authorization == .restricted){
                return true
            }else{
                return false
            }
        } else if #available(iOS 13.0, *) {
            
            if(CBCentralManager().authorization == CBManagerAuthorization.allowedAlways || CBCentralManager().authorization == CBManagerAuthorization.restricted){
              return true
            }else{
              return false
            }
        }else{
            // Before iOS 13, Bluetooth permissions are not required
           return true
        }
    }
    
    
    private var permissionCallback:PermissionCallback?
    private var stateCallback:CBManagerStateCallback?
    private var stateCallbackListener:CBManagerStateCallback?
    private var stateAdapterCallback:CBManagerStateCallback?
    
    func setStateCallbackListener(listener:@escaping CBManagerStateCallback)  {
        self.stateCallbackListener = listener
    }
    
    
    
    func requestPermission( permissionCallback:@escaping PermissionCallback){
           
           self.permissionCallback = permissionCallback
          
           var notDetermined = true
           
           if #available(iOS 13.1, *) {
               if( CBCentralManager.authorization == .allowedAlways || CBCentralManager.authorization == .restricted){
                   permissionCallback(true)
                   notDetermined = false
               }else  if(CBCentralManager.authorization == .denied){
                   permissionCallback(false)
                   notDetermined = false
               }
           } else if #available(iOS 13.0, *) {
               if(CBCentralManager().authorization == CBManagerAuthorization.allowedAlways || CBCentralManager().authorization == CBManagerAuthorization.restricted){
                   permissionCallback(true)
                   notDetermined = false
                   
               }else if(CBCentralManager().authorization == CBManagerAuthorization.denied){
                   permissionCallback(false)
                   notDetermined = false
               }
           }else{
               // Before iOS 13, Bluetooth permissions are not required
               permissionCallback(true)
               notDetermined = false
           }
           
           if(notDetermined){
               
               stateCallback = { state in
                   if(self.permissionCallback != nil){
                       self.requestPermission(permissionCallback: self.permissionCallback!)
                   }
               }
               ///还未授权时获取下状态,让系统自动调用授权框
               centralManager.state
           }else{
               self.permissionCallback = nil
               self.stateCallback = nil
               ///已经有权限结果的时候 也需要获取下
               centralManager.state
           }
              
             
          
           
       }

}
