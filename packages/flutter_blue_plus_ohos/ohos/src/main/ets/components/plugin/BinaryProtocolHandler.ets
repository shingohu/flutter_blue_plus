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

import { FlutterPluginBinding, BasicMessageChannel, BinaryCodec, ByteBuffer, Reply } from '@ohos/flutter_ohos';
import { buffer } from '@kit.ArkTS';

// Binary protocol command IDs
const CMD_WRITE_CHARACTERISTIC: number = 0x01;
const CMD_WRITE_DESCRIPTOR: number = 0x02;
const CMD_SET_NOTIFY_VALUE: number = 0x03;

// Write flags
const FLAG_WITHOUT_RESPONSE: number = 1 << 0;
const FLAG_ALLOW_LONG_WRITE: number = 1 << 1;

// Notify flags
const FLAG_ENABLE: number = 1 << 0;
const FLAG_FORCE_INDICATIONS: number = 1 << 1;

const BINARY_CHANNEL: string = "flutter_blue_plus/binary";

/**
 * Interface implemented by FlutterBluePlusOhosPlugin for binary write operations.
 *
 * Declared here (instead of importing the plugin class) to keep the dependency
 * direction one-way: FlutterBluePlusOhosPlugin imports BinaryProtocolHandler,
 * the handler only depends on this interface.
 */
export interface BinaryPlugin {
  binaryWriteCharacteristic(remoteId: string, primaryServiceUuid: string, serviceUuid: string,
    characteristicUuid: string, instanceId: number, writeType: number, value: Uint8Array):
    Promise<Map<string, number | string>>;
  binaryWriteDescriptor(remoteId: string, primaryServiceUuid: string, serviceUuid: string,
    characteristicUuid: string, instanceId: number, descriptorUuid: string, value: Uint8Array):
    Promise<Map<string, number | string>>;
  binarySetNotifyValue(remoteId: string, primaryServiceUuid: string, serviceUuid: string,
    characteristicUuid: string, instanceId: number, enable: boolean, forceIndications: boolean):
    Promise<Map<string, number | string>>;
}

/**
 * Binary protocol handler for low-latency BLE write operations on OHOS.
 *
 * Handles binary-encoded BLE write requests via BasicMessageChannel,
 * bypassing MethodChannel serialization overhead.
 *
 * The OHOS Flutter SDK (@ohos/flutter_ohos) ships a BinaryCodec (raw bytes,
 * compatible with the Dart BinaryCodec) plus BasicMessageChannel
 * setMessageHandler, so the binary channel can be implemented natively.
 */
export default class BinaryProtocolHandler {
  private channel: BasicMessageChannel<ArrayBuffer> | null = null;
  private plugin: BinaryPlugin | null = null;

  /**
   * Register the binary message handler.
   */
  public register(binding: FlutterPluginBinding, plugin: BinaryPlugin): void {
    this.plugin = plugin;
    this.channel = new BasicMessageChannel<ArrayBuffer>(
      binding.getBinaryMessenger(),
      BINARY_CHANNEL,
      new BinaryCodec(false),
    );
    this.channel.setMessageHandler({
      onMessage: (message: ArrayBuffer, reply: Reply<ArrayBuffer>) => {
        this.handleMessage(message, reply);
      }
    });
    console.info("[BinaryProtocolHandler] registered");
  }

  /**
   * Unregister the binary message handler.
   */
  public unregister(): void {
    this.channel?.setMessageHandler(null);
    this.channel = null;
    this.plugin = null;
  }

  private handleMessage(message: ArrayBuffer, reply: Reply<ArrayBuffer>): void {
    try {
      if (message == null || message.byteLength < 2) {
        reply.reply(this.encodeError(-1, "invalid message"));
        return;
      }
      const bb = ByteBuffer.from(message);
      const cmd = bb.readUint8();
      const flags = bb.readUint8();
      const instanceId = bb.readUint16();

      const remoteId = this.readStringField(bb);
      if (remoteId == null) {
        reply.reply(this.encodeError(-1, "missing remoteId"));
        return;
      }
      const serviceUuid = this.readStringField(bb);
      if (serviceUuid == null) {
        reply.reply(this.encodeError(-1, "missing serviceUuid"));
        return;
      }
      const characteristicUuid = this.readStringField(bb);
      if (characteristicUuid == null) {
        reply.reply(this.encodeError(-1, "missing characteristicUuid"));
        return;
      }
      const primaryServiceUuid = this.readStringField(bb) ?? "";
      const descriptorUuid = this.readStringField(bb) ?? "";

      const plugin = this.plugin;
      if (plugin == null) {
        reply.reply(this.encodeError(-1, "binary handler not registered"));
        return;
      }

      if (cmd === CMD_WRITE_CHARACTERISTIC || cmd === CMD_WRITE_DESCRIPTOR) {
        if (bb.bytesRemaining < 2) {
          reply.reply(this.encodeError(-1, "missing valueLen"));
          return;
        }
        const valueLen = bb.readUint16();
        const value = bb.readUint8Array(valueLen);
        if (cmd === CMD_WRITE_CHARACTERISTIC) {
          plugin.binaryWriteCharacteristic(
            remoteId, primaryServiceUuid, serviceUuid, characteristicUuid,
            instanceId, (flags & FLAG_WITHOUT_RESPONSE) !== 0 ? 1 : 0, value,
          ).then((r: Map<string, number | string>) => {
            reply.reply(this.fromResult(r));
          }).catch((e: Error) => {
            reply.reply(this.encodeError(4, e.message));
          });
        } else {
          plugin.binaryWriteDescriptor(
            remoteId, primaryServiceUuid, serviceUuid, characteristicUuid,
            instanceId, descriptorUuid, value,
          ).then((r: Map<string, number | string>) => {
            reply.reply(this.fromResult(r));
          }).catch((e: Error) => {
            reply.reply(this.encodeError(4, e.message));
          });
        }
      } else if (cmd === CMD_SET_NOTIFY_VALUE) {
        plugin.binarySetNotifyValue(
          remoteId, primaryServiceUuid, serviceUuid, characteristicUuid,
          instanceId, (flags & FLAG_ENABLE) !== 0, (flags & FLAG_FORCE_INDICATIONS) !== 0,
        ).then((r: Map<string, number | string>) => {
          reply.reply(this.fromResult(r));
        }).catch((e: Error) => {
          reply.reply(this.encodeError(4, e.message));
        });
      } else {
        reply.reply(this.encodeError(-1, "unknown cmd: " + cmd));
      }
    } catch (e) {
      reply.reply(this.encodeError(-1, "invalid message: " + JSON.stringify(e)));
    }
  }

  /** Reads a length-prefixed (1B len + UTF-8) string field, or null if truncated. */
  private readStringField(bb: ByteBuffer): string | null {
    if (!bb.hasRemaining()) {
      return null;
    }
    const len = bb.readUint8();
    if (len === 0) {
      return "";
    }
    if (bb.bytesRemaining < len) {
      return null;
    }
    return bb.readString(len);
  }

  /** Map {success, errorCode, errorString} to protocol response bytes */
  private fromResult(r: Map<string, number | string>): ArrayBuffer {
    const success = r.get("success") as number;
    if (success === 1) {
      return this.encodeSuccess();
    }
    return this.encodeError(r.get("errorCode") as number, r.get("errorString") as string);
  }

  /**
   * Encode a success response.
   * Layout: success(1B) + errorCode(int32 BE) + errorStrLen(uint16 BE) + errorStr
   */
  private encodeSuccess(): ArrayBuffer {
    const out = new Uint8Array(7);
    const view = new DataView(out.buffer);
    view.setUint8(0, 1);
    view.setInt32(1, 0);
    view.setUint16(5, 0);
    return out.buffer;
  }

  /**
   * Encode an error response.
   * Layout: success(1B) + errorCode(int32 BE) + errorStrLen(uint16 BE) + errorStr
   */
  private encodeError(errorCode: number, errorString: string): ArrayBuffer {
    const msg = buffer.from(errorString ?? "", 'utf8');
    const out = new Uint8Array(7 + msg.length);
    const view = new DataView(out.buffer);
    view.setUint8(0, 0);
    view.setInt32(1, errorCode);
    view.setUint16(5, msg.length);
    out.set(msg, 7);
    return out.buffer;
  }
}
