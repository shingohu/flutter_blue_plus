/*
 * Copyright (C) 2026 Huawei Device Co., Ltd.
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

import { MethodResult } from '@ohos/flutter_ohos';
import { abilityAccessCtrl, bundleManager, Permissions, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import BleUtils from './BleUtils';

/**
 * 蓝牙权限管理器。
 *
 * 封装 OHOS ACCESS_BLUETOOTH 权限的检测、申请与状态查询。
 * 在 Ability 附加时由 Plugin 注入 context；各业务 handler 调用
 * ensurePermissions 在执行 BLE 操作前完成权限校验与申请。
 */
export default class BlePermissionManager {
  /** 鸿蒙蓝牙访问权限名。 */
  public static readonly ACCESS_BLUETOOTH_PERMISSION: Permissions = 'ohos.permission.ACCESS_BLUETOOTH';

  /** Ability context，用于 requestPermissionsFromUser。由 Plugin 在 onAttachedToAbility 注入。 */
  public context: common.Context | null = null;

  /**
   * 确保拥有蓝牙权限：若已授予则直接返回 true；否则向用户申请，
   * 申请失败/被拒时通过 result 回调错误并返回 false。
   * @param result - MethodChannel 结果回调，用于权限失败时向 Flutter 端返回
   * @param errorCode - 权限失败时回传给 Flutter 端的错误码（通常为方法名）
   * @returns 是否已获得权限
   */
  async ensurePermissions(result: MethodResult, errorCode: string): Promise<boolean> {
    // checkSelfPermission 返回 true 表示当前未授权（PERMISSION_DENIED），
    // 需要发起申请；返回 false 则视为已授权，直返 true
    let checkPermissionStatus = await this.checkSelfPermission(BlePermissionManager.ACCESS_BLUETOOTH_PERMISSION);
    let permissionStatus: boolean = true;
    if (checkPermissionStatus) {
      let isPermission = await this.requestPermissions();
      if (typeof isPermission === 'boolean' && !(isPermission as boolean)) {
        // requestPermissions 返回 false（未知失败）：按未授权以 success(false) 回传
        result.success(false);
        permissionStatus = false;
      } else if (typeof isPermission === 'string') {
        // requestPermissions 返回字符串（失败/拒绝原因）：以 error 形式上抛给 Flutter 端
        result.error(errorCode, isPermission as string, null);
        permissionStatus = false;
      }
    }
    return permissionStatus;
  }

  /**
   * 弹窗向用户申请 ACCESS_BLUETOOTH 权限。
   * @returns true 表示已授予；字符串表示失败原因；false 表示未知失败
   */
  async requestPermissions(): Promise<boolean | string> {
    let result: boolean | string = false;
    let atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    await atManager.requestPermissionsFromUser(this.context, [BlePermissionManager.ACCESS_BLUETOOTH_PERMISSION])
      .then((data) => {
        let grantStatus: number[] = data.authResults;
        // authResults[0] === 0 即 PERMISSION_GRANTED，表示用户已授权
        if (grantStatus.length > 0 && grantStatus[0] === 0) {
          result = true;
        } else {
          result = 'FlutterBluePlus requires ohos Permission ohos.permission.ACCESS_BLUETOOTH';
        }
      })
      .catch((err: BusinessError) => {
        result = `Failed to request permissions from user. Code is ${err.code}, message is ${err.message}`;
      });
    return result;
  }

  /**
   * 检查指定权限当前授予状态。
   * @param permission - 权限名
   * @returns 是否需要向用户申请（grantStatus == -1 即 PERMISSION_DENIED 时返回 true）
   */
  async checkSelfPermission(permission: Permissions): Promise<boolean> {
    let tokenId: number = 0;
    let grantStatus: abilityAccessCtrl.GrantStatus = abilityAccessCtrl.GrantStatus.PERMISSION_DENIED;
    let atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    let bundleInfo: bundleManager.BundleInfo =
      await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
    let appInfo: bundleManager.ApplicationInfo = bundleInfo.appInfo;
    tokenId = appInfo.accessTokenId;
    grantStatus = await atManager.checkAccessToken(tokenId, permission);
    // 返回 true 表示权限被拒绝（grantStatus == -1 / PERMISSION_DENIED），
    // 即需要向用户申请；语义与字段名相反，调用方据此决定是否弹窗
    return grantStatus == -1;
  }
}
