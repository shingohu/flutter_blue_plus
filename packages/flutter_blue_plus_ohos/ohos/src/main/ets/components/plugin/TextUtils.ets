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
/**
 * 文本工具类。
 *
 * 提供空串判断、字符数组转换、忽略大小写的相等/比较，
 * 以及 HCI 状态码到字符串的映射，
 * 供 BLE 操作的断连原因码（disconnect_reason_string）等场景使用。
 */
export default class TextUtils {
  /**
   * 判断字符串是否为 null/undefined/空串。
   * @param text - 待判断字符串
   * @returns 为空返回 true
   */
  public static isEmpty(text: string): boolean {
    return text == null || text == undefined || text.length == 0;
  }

  /**
   * 将字符串拆分为单字符数组。
   * @param text - 源字符串
   * @returns 字符数组
   */
  public static toCharArray(text: string): string[] {
    let arr: string[] = new Array(text.length);
    for (let i = 0; i < text.length; i++) {
      arr[i] = text.charAt(i);
    }
    return arr;
  }

  /**
   * 忽略大小写比较两字符串是否相等。
   * @param s1 - 字符串 1
   * @param s2 - 字符串 2
   * @returns 忽略大小写后相等返回 true
   */
  public static equalsIgnoreCase(s1: string, s2: string): boolean {
    return s1.toLowerCase() == s2.toLowerCase();
  }

  /**
   * 忽略大小写比较两字符串的字典序差值。
   * 先逐字符比较（大小写折算为大写后比对码点），全部相等时按长度差返回。
   * @param s1 - 字符串 1
   * @param s2 - 字符串 2
   * @returns 负数表示 s1<s2，0 表示相等，正数表示 s1>s2
   */
  public static compareToIgnoreCase(s1: string, s2: string): number {
    let n1 = s1.length;
    let n2 = s2.length;
    let min = Math.min(n1, n2);
    for (let i = 0; i < min; i++) {
      let c1 = s1.charAt(i);
      let c2 = s2.charAt(i);
      if (c1 != c2) {
        // 仅当原始字符不同时再折算为大写，避免对相同字符无谓调用 toUpperCase
        c1 = c1.toUpperCase();
        c2 = c2.toUpperCase();
        if (c1 != c2) {
          // 折算后仍不等，按码点差值即时返回比较结果
          return c1.charCodeAt(0) - c2.charCodeAt(0);
        }
      }
    }
    // 公共前缀完全相等时，以长度差决定先后（较短的字符串排在前）
    return n1 - n2;
  }

  /**
   * 将 HCI 状态码映射为可读字符串。
   * @param value - HCI 状态码
   * @returns 状态字符串（如 "SUCCESS"）
   */
  public static hciStatusString(value: number): string {
    switch (value) {
      case 0x00:
        return 'SUCCESS';
      default:
        return 'UNKNOWN_HCI_ERROR (' + value + ')';
    }
  }
}
