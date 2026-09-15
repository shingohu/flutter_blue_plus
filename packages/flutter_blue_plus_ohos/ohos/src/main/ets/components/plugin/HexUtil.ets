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

import TextUtils from './TextUtils'

type char = string;
type byte = number;

/**
 * 十六进制工具类。
 *
 * 提供字节数组与十六进制字符串之间的双向转换（encodeHex/encodeHexStr/
 * decodeHex/hexStringToBytes）、
 * 广播字节的十六进制格式化（formatHexString，供 BleScanManager 解析广播使用），
 * 以及单字节提取等辅助方法。大小写通过 toLowerCase 开关控制。
 */
export default class HexUtil {
  /** 小写十六进制字符表。 */
  private static readonly DIGITS_LOWER: char[] = ['0', '1', '2', '3', '4', '5',
    '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'];
  /** 大写十六进制字符表。 */
  private static readonly DIGITS_UPPER: char[] = ['0', '1', '2', '3', '4', '5',
    '6', '7', '8', '9', 'A', 'B', 'C', 'D', 'E', 'F'];

  /**
   * 将字节数组编码为十六进制字符数组。
   * @param data - 字节数组
   * @param toLowerCase - 是否使用小写（默认 true）
   * @returns 十六进制字符数组
   */
  public static encodeHex(data: byte[], toLowerCase: boolean = true): char[] {
    return HexUtil.encodeHexInner(data, toLowerCase ? HexUtil.DIGITS_LOWER : HexUtil.DIGITS_UPPER);
  }

  /**
   * 内部：按指定字符表将字节数组编码为十六进制字符数组。
   * @param data - 字节数组
   * @param toDigits - 十六进制字符表
   * @returns 十六进制字符数组
   */
  protected static encodeHexInner(data: byte[], toDigits: char[]): char[] {
    if (!data)
      return [];
    let l: number = data.length;
    let out: char[] = new Array(l << 1);
    for (let i = 0, j = 0; i < l; i++) {
      // 高 4 位（>>> 4 无符号右移）和低 4 位（& 0x0F）分别映射为一个十六进制字符
      out[j++] = toDigits[(0xF0 & data[i]) >>> 4];
      out[j++] = toDigits[0x0F & data[i]];
    }
    return out;
  }

  /**
   * 将字符数组拼接为字符串。
   * @param data - 字符数组
   * @returns 拼接后的字符串
   */
  private static byteToString(data: char[]): string {
    let str = '';
    for (let i = 0; i < data.length; i++) {
      str += data[i];
    }
    return str;
  }


  /**
   * 将字节数组编码为十六进制字符串。
   * @param data - 字节数组
   * @param toLowerCase - 是否使用小写（默认 true）
   * @returns 十六进制字符串
   */
  public static encodeHexStr(data: byte[], toLowerCase: boolean = true): string {
    return HexUtil.encodeHexStrInner(data, toLowerCase ? HexUtil.DIGITS_LOWER : HexUtil.DIGITS_UPPER);
  }


  /**
   * 内部：按指定字符表将字节数组编码为十六进制字符串。
   * @param data - 字节数组
   * @param toDigits - 十六进制字符表
   * @returns 十六进制字符串
   */
  protected static encodeHexStrInner(data: byte[], toDigits: char[]): string {
    return HexUtil.byteToString(HexUtil.encodeHexInner(data, toDigits));
  }

  /**
   * 将 Uint8Array 格式化为十六进制字符串（BleScanManager
   * 用于把原始广播字节转为 hex 供解析）。
   * @param data - 字节数组
   * @param addSpace - 字节间是否加空格（默认 false）
   * @returns 十六进制字符串；入参为空返回空串
   */
  public static formatHexString(data: Uint8Array, addSpace: boolean = false): string {
    if (!data || data.length < 1)
      return '';
    let sb: string = '';
    for (let i: number = 0; i < data.length; i++) {
      // 0xFF 屏蔽符号位，确保单字节（0-255）按无符号值转 16 进制
      let hex: String = (data[i] & 0xFF).toString(16);
      if (hex.length == 1) {
        // 单字符（如 f）需补前导 0，凑成两位十六进制表示一个字节
        hex = '0' + hex;
      }
      sb = sb + hex;
      if (addSpace)
        sb = sb + ' ';
    }
    return sb;
  }

  /**
   * 将十六进制字符数组解码为字节数组。
   * @param data - 十六进制字符数组
   * @returns 字节数组
   * @throws Error 字符数为奇数或含非法十六进制字符时抛出
   */
  public static decodeHex(data: char[]): byte[] {
    let len: number = data.length;

    if ((len & 0x01) != 0) {
      throw new Error('Odd number of characters.');
    }

    let out: byte[] = new Array(len >> 1);

    // 两个十六进制字符拼成一个字节：高位字符左移 4 位，再与低位字符按位或
    for (let i: number = 0, j = 0; j < len; i++) {
      let f: number = HexUtil.toDigit(data[j], j) << 4;
      j++;
      f = f | HexUtil.toDigit(data[j], j);
      j++;
      // 0xFF 截断为单字节范围（0-255），避免符号位扩展
      out[i] = (f & 0xFF);
    }

    return out;
  }


  /**
   * 将单个十六进制字符转为数值。
   * @param ch - 十六进制字符
   * @param index - 字符所在下标（仅用于异常信息）
   * @returns 0-15 的数值
   * @throws Error 非法字符时抛出
   */
  protected static toDigit(ch: char, index: number): number {
    let digit: number = HexUtil.charToByte(ch.toUpperCase()); //Character.digit(ch, 16);
    if (digit == -1) {
      throw new Error('Illegal hexadecimal character ' + ch
        + ' at index ' + index);
    }
    return digit;
  }


  /**
   * 将十六进制字符串转为 Uint8Array。
   * 自动去除空白、补齐奇数长度前导 0、转大写后解析。
   * @param hexString - 十六进制字符串
   * @returns 字节数组；入参为空返回 null
   */
  public static hexStringToBytes(hexString: string): Uint8Array | null {
    if (TextUtils.isEmpty(hexString)) {
      return null;
    }
    hexString = hexString.trim();
    hexString = hexString.toUpperCase();
    // 去除所有空格，兼容 "AA BB" 这类带分隔的写法
    hexString = hexString.replace(new RegExp(' ', 'g'), '');
    // 字符数为奇数时（如 "A"），在前面补一个 0 凑成 "0A" 以保证整字节数量
    hexString = hexString.length % 2 == 1 ? '0' + hexString : hexString;
    let length: number = hexString.length / 2;
    let hexChars: char[] = TextUtils.toCharArray(hexString);
    let d: byte[] = new Array(length);
    for (let i = 0; i < length; i++) {
      // 每两个字符表示一个字节：高位字符左移 4 位，再与低位字符按位或
      let pos = i * 2;
      d[i] = (HexUtil.charToByte(hexChars[pos]) << 4 | HexUtil.charToByte(hexChars[pos + 1]));
    }
    return new Uint8Array(d);
  }

  /**
   * 将单个十六进制字符转为 0-15 的数值（非法字符返回 -1）。
   * @param c - 十六进制字符
   * @returns 数值；非法字符返回 -1
   */
  public static charToByte(c: char): byte {
    return '0123456789ABCDEF'.indexOf(c);
  }

  /**
   * 提取字节数组中指定位置单字节的十六进制字符串。
   * @param data - 字节数组
   * @param position - 字节下标
   * @returns 单字节十六进制字符串
   */
  public static extractData(data: Uint8Array, position: number): String {
    return HexUtil.formatHexString(new Uint8Array([data[position]]));
  }
}
