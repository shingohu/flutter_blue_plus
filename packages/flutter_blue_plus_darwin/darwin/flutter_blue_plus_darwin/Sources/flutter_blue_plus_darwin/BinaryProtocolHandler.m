#import "BinaryProtocolHandler.h"
#import "FlutterBluePlusPlugin.h"

@interface BinaryProtocolHandler ()

@property (nonatomic, weak) FlutterBluePlusPlugin *plugin;
@property (nonatomic, strong) NSMutableDictionary<NSString *, FlutterBinaryReply> *pendingReplies;

@end

// Command IDs
static const uint8_t CMD_WRITE_CHARACTERISTIC = 0x01;
static const uint8_t CMD_WRITE_DESCRIPTOR     = 0x02;
static const uint8_t CMD_SET_NOTIFY_VALUE      = 0x03;

// Write flags
static const uint8_t FLAG_WITHOUT_RESPONSE    = 1 << 0;
static const uint8_t FLAG_ALLOW_LONG_WRITE    = 1 << 1;

// Notify flags
static const uint8_t FLAG_ENABLE              = 1 << 0;
static const uint8_t FLAG_FORCE_INDICATIONS   = 1 << 1;

@implementation BinaryProtocolHandler

- (instancetype)initWithPlugin:(FlutterBluePlusPlugin *)plugin {
    self = [super init];
    if (self) {
        _plugin = plugin;
        _pendingReplies = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)registerWithMessenger:(NSObject<FlutterBinaryMessenger> *)messenger {
    [messenger setMessageHandlerOnChannel:@"flutter_blue_plus/binary"
                    binaryMessageHandler:^(NSData *message, FlutterBinaryReply reply) {
        [self handleMessage:message reply:reply];
    }];
}

- (void)unregisterWithMessenger:(NSObject<FlutterBinaryMessenger> *)messenger {
    [messenger setMessageHandlerOnChannel:@"flutter_blue_plus/binary" binaryMessageHandler:nil];
}

- (void)handleMessage:(NSData *)message reply:(FlutterBinaryReply)reply {
    if (message.length < 2) {
        reply([self encodeError:-1 message:@"invalid message"]);
        return;
    }

    const uint8_t *bytes = (const uint8_t *)message.bytes;
    NSUInteger offset = 0;

    uint8_t cmd = bytes[offset++];
    uint8_t flags = bytes[offset++];

    uint16_t instanceId = 0;
    if (offset + 2 <= message.length) {
        instanceId = (bytes[offset] << 8) | bytes[offset + 1];
        offset += 2;
    }

    NSString *remoteId = [self readString:message offset:&offset];
    if (!remoteId) { reply([self encodeError:-1 message:@"missing remoteId"]); return; }

    NSString *serviceUuid = [self readString:message offset:&offset];
    if (!serviceUuid) { reply([self encodeError:-1 message:@"missing serviceUuid"]); return; }

    NSString *characteristicUuid = [self readString:message offset:&offset];
    if (!characteristicUuid) { reply([self encodeError:-1 message:@"missing characteristicUuid"]); return; }

    NSString *primaryServiceUuid = [self readString:message offset:&offset] ?: @"";
    NSString *descriptorUuid = [self readString:message offset:&offset] ?: @"";

    CBPeripheral *peripheral = [self.plugin getConnectedPeripheral:remoteId];
    if (!peripheral) {
        reply([self encodeError:1 message:@"device is disconnected"]);
        return;
    }

    CBCharacteristic *characteristic = [self findCharacteristic:peripheral
                                                    serviceUuid:serviceUuid
                                              characteristicUuid:characteristicUuid
                                                     instanceId:instanceId];
    if (!characteristic && cmd != CMD_WRITE_DESCRIPTOR) {
        reply([self encodeError:2 message:@"characteristic not found"]);
        return;
    }

    switch (cmd) {
        case CMD_WRITE_CHARACTERISTIC: {
            [self handleWriteCharacteristic:peripheral
                              characteristic:characteristic
                           primaryServiceUuid:primaryServiceUuid
                                     remoteId:remoteId
                                   serviceUuid:serviceUuid
                             characteristicUuid:characteristicUuid
                                    instanceId:instanceId
                                       flags:flags
                                     message:message
                                       reply:reply];
            break;
        }
        case CMD_WRITE_DESCRIPTOR: {
            [self handleWriteDescriptor:peripheral
                          characteristic:characteristic
                       primaryServiceUuid:primaryServiceUuid
                                 remoteId:remoteId
                               serviceUuid:serviceUuid
                         characteristicUuid:characteristicUuid
                                instanceId:instanceId
                            descriptorUuid:descriptorUuid
                                  message:message
                                    reply:reply];
            break;
        }
        case CMD_SET_NOTIFY_VALUE: {
            [self handleSetNotifyValue:peripheral
                         characteristic:characteristic
                      primaryServiceUuid:primaryServiceUuid
                                remoteId:remoteId
                              serviceUuid:serviceUuid
                        characteristicUuid:characteristicUuid
                               instanceId:instanceId
                                   flags:flags
                                   reply:reply];
            break;
        }
        default:
            reply([self encodeError:-1 message:[NSString stringWithFormat:@"unknown cmd: %d", cmd]]);
    }
}

- (void)handleWriteCharacteristic:(CBPeripheral *)peripheral
                    characteristic:(CBCharacteristic *)characteristic
                 primaryServiceUuid:(NSString *)primaryServiceUuid
                           remoteId:(NSString *)remoteId
                         serviceUuid:(NSString *)serviceUuid
                   characteristicUuid:(NSString *)characteristicUuid
                          instanceId:(uint16_t)instanceId
                               flags:(uint8_t)flags
                             message:(NSData *)message
                               reply:(FlutterBinaryReply)reply {
    BOOL withoutResponse = (flags & FLAG_WITHOUT_RESPONSE) != 0;

    NSData *value = [self readValue:message];
    if (!value) { reply([self encodeError:-1 message:@"missing value"]); return; }

    // Check writable
    if (withoutResponse) {
        if ((characteristic.properties & CBCharacteristicPropertyWriteWithoutResponse) == 0) {
            reply([self encodeError:3 message:@"WRITE_NO_RESPONSE not supported"]);
            return;
        }
    } else {
        if ((characteristic.properties & CBCharacteristicPropertyWrite) == 0) {
            reply([self encodeError:3 message:@"WRITE not supported"]);
            return;
        }
    }

    // CoreBluetooth silently drops writes longer than the allowed payload
    // (notably withoutResponse) without any callback. Fail fast instead of
    // replying success for a write that never happened.
    CBCharacteristicWriteType writeType = withoutResponse
        ? CBCharacteristicWriteWithoutResponse
        : CBCharacteristicWriteWithResponse;
    NSInteger maxLength = [peripheral maximumWriteValueLengthForType:writeType];
    if (value.length > (NSUInteger)maxLength) {
        reply([self encodeError:4 message:@"data longer than allowed"]);
        return;
    }

    if (withoutResponse) {
        // writeWithoutResponse: CoreBluetooth does NOT call didWriteValueForCharacteristic.
        // Reply immediately after submitting.
        [peripheral writeValue:value forCharacteristic:characteristic type:CBCharacteristicWriteWithoutResponse];
        reply([self encodeSuccess]);
    } else {
        // writeWithResponse: store reply for didWriteValueForCharacteristic callback.
        // Normalize UUIDs to 128-bit to match the completion-side keys, which use
        // [CBUUID UUIDString] (always full 128-bit). Dart sends shortest form
        // ("180d") for 16/32-bit UUIDs; without normalization the keys never match.
        NSString *key = [NSString stringWithFormat:@"write:%@:%@:%@:%@:%d",
                         remoteId,
                         [self uuid128:primaryServiceUuid],
                         [self uuid128:serviceUuid],
                         [self uuid128:characteristicUuid],
                         instanceId];
        FlutterBinaryReply superseded = nil;
        @synchronized(self) {
            superseded = self.pendingReplies[key];
            self.pendingReplies[key] = reply;
        }
        if (superseded) {
            superseded([self encodeError:4 message:@"operation superseded"]);
        }
        [peripheral writeValue:value forCharacteristic:characteristic type:CBCharacteristicWriteWithResponse];
    }
}

- (void)handleWriteDescriptor:(CBPeripheral *)peripheral
                characteristic:(CBCharacteristic *)characteristic
             primaryServiceUuid:(NSString *)primaryServiceUuid
                       remoteId:(NSString *)remoteId
                     serviceUuid:(NSString *)serviceUuid
               characteristicUuid:(NSString *)characteristicUuid
                      instanceId:(uint16_t)instanceId
                  descriptorUuid:(NSString *)descriptorUuid
                        message:(NSData *)message
                          reply:(FlutterBinaryReply)reply {
    NSData *value = [self readValue:message];
    if (!value) { reply([self encodeError:-1 message:@"missing value"]); return; }

    CBDescriptor *descriptor = [self findDescriptorInCharacteristic:characteristic
                                                     descriptorUuid:descriptorUuid];
    if (!descriptor) {
        reply([self encodeError:5 message:@"descriptor not found"]);
        return;
    }

    // Store reply for didWriteValueForDescriptor callback.
    // Normalize UUIDs to 128-bit to match the completion-side keys (see
    // handleWriteCharacteristic above).
    NSString *key = [NSString stringWithFormat:@"desc:%@:%@:%@:%@:%d:%@",
                     remoteId,
                     [self uuid128:primaryServiceUuid],
                     [self uuid128:serviceUuid],
                     [self uuid128:characteristicUuid],
                     instanceId,
                     [self uuid128:descriptorUuid]];
    FlutterBinaryReply superseded = nil;
    @synchronized(self) {
        superseded = self.pendingReplies[key];
        self.pendingReplies[key] = reply;
    }
    if (superseded) {
        superseded([self encodeError:4 message:@"operation superseded"]);
    }

    [peripheral writeValue:value forDescriptor:descriptor];
}

- (void)handleSetNotifyValue:(CBPeripheral *)peripheral
               characteristic:(CBCharacteristic *)characteristic
            primaryServiceUuid:(NSString *)primaryServiceUuid
                      remoteId:(NSString *)remoteId
                    serviceUuid:(NSString *)serviceUuid
              characteristicUuid:(NSString *)characteristicUuid
                     instanceId:(uint16_t)instanceId
                         flags:(uint8_t)flags
                         reply:(FlutterBinaryReply)reply {
    BOOL enable = (flags & FLAG_ENABLE) != 0;

    // Store reply for didUpdateNotificationStateForCharacteristic callback.
    // Normalize UUIDs to 128-bit to match the completion-side keys (see
    // handleWriteCharacteristic above).
    NSString *key = [NSString stringWithFormat:@"notify:%@:%@:%@:%@:%d",
                     remoteId,
                     [self uuid128:primaryServiceUuid],
                     [self uuid128:serviceUuid],
                     [self uuid128:characteristicUuid],
                     instanceId];
    FlutterBinaryReply superseded = nil;
    @synchronized(self) {
        superseded = self.pendingReplies[key];
        self.pendingReplies[key] = reply;
    }
    if (superseded) {
        superseded([self encodeError:4 message:@"operation superseded"]);
    }

    [peripheral setNotifyValue:enable forCharacteristic:characteristic];
}

// MARK: - Called from FlutterBluePlusPlugin callbacks

- (void)completeWriteCharacteristic:(NSString *)remoteId
                   primaryServiceUuid:(NSString *)primaryServiceUuid
                         serviceUuid:(NSString *)serviceUuid
                   characteristicUuid:(NSString *)characteristicUuid
                          instanceId:(NSInteger)instanceId
                             success:(BOOL)success
                           errorCode:(int32_t)errorCode
                         errorString:(NSString *)errorString {
    NSString *key = [NSString stringWithFormat:@"write:%@:%@:%@:%@:%ld",
                     remoteId, primaryServiceUuid, serviceUuid, characteristicUuid, (long)instanceId];
    [self completeReply:key success:success errorCode:errorCode errorString:errorString];
}

- (void)completeWriteDescriptor:(NSString *)remoteId
               primaryServiceUuid:(NSString *)primaryServiceUuid
                     serviceUuid:(NSString *)serviceUuid
               characteristicUuid:(NSString *)characteristicUuid
                      instanceId:(NSInteger)instanceId
                  descriptorUuid:(NSString *)descriptorUuid
                         success:(BOOL)success
                       errorCode:(int32_t)errorCode
                     errorString:(NSString *)errorString {
    NSString *key = [NSString stringWithFormat:@"desc:%@:%@:%@:%@:%ld:%@",
                     remoteId, primaryServiceUuid, serviceUuid, characteristicUuid, (long)instanceId, descriptorUuid];
    [self completeReply:key success:success errorCode:errorCode errorString:errorString];
}

- (void)completeSetNotifyValue:(NSString *)remoteId
              primaryServiceUuid:(NSString *)primaryServiceUuid
                    serviceUuid:(NSString *)serviceUuid
              characteristicUuid:(NSString *)characteristicUuid
                     instanceId:(NSInteger)instanceId
                        success:(BOOL)success
                      errorCode:(int32_t)errorCode
                    errorString:(NSString *)errorString {
    NSString *key = [NSString stringWithFormat:@"notify:%@:%@:%@:%@:%ld",
                     remoteId, primaryServiceUuid, serviceUuid, characteristicUuid, (long)instanceId];
    [self completeReply:key success:success errorCode:errorCode errorString:errorString];
}

- (void)completeReply:(NSString *)key success:(BOOL)success errorCode:(int32_t)errorCode errorString:(NSString *)errorString {
    FlutterBinaryReply reply;
    @synchronized(self) {
        reply = self.pendingReplies[key];
        if (reply) {
            [self.pendingReplies removeObjectForKey:key];
        }
    }
    if (reply) {
        if (success) {
            reply([self encodeSuccess]);
        } else {
            reply([self encodeError:errorCode message:errorString]);
        }
    }
}

- (void)clearPendingRepliesForRemoteId:(NSString *)remoteId {
    // Keys are "<type>:<remoteId>:<...>" (e.g. "write:UUID:...",
    // "desc:UUID:...", "notify:UUID:..."), so the remoteId segment is always
    // followed by a colon.
    NSString *prefixSegment = [NSString stringWithFormat:@":%@:", remoteId];
    NSMutableArray<FlutterBinaryReply> *cancelled = [NSMutableArray array];
    @synchronized(self) {
        for (NSString *key in [self.pendingReplies allKeys]) {
            if ([key rangeOfString:prefixSegment].location != NSNotFound) {
                [cancelled addObject:self.pendingReplies[key]];
                [self.pendingReplies removeObjectForKey:key];
            }
        }
    }
    for (FlutterBinaryReply reply in cancelled) {
        reply([self encodeError:1 message:@"device disconnected"]);
    }
}

// MARK: - Peripheral service/characteristic lookup

- (CBCharacteristic *)findCharacteristic:(CBPeripheral *)peripheral
                             serviceUuid:(NSString *)serviceUuid
                       characteristicUuid:(NSString *)characteristicUuid
                              instanceId:(uint16_t)instanceId {
    // Collect ALL services matching serviceUuid. instanceId semantics must
    // mirror FlutterBluePlusPlugin getInstanceId / locateCharacteristic:
    //   - single matching service: per-service count of same-UUID
    //     characteristics, starting at 0 (getLocalInstanceId).
    //   - multiple matching services: global count across EVERY characteristic
    //     of every matching service (getInstanceId increments idx per
    //     characteristic, not per matching UUID; locateCharacteristic matches
    //     idx == instanceId && UUID match).
    NSMutableArray<CBService *> *matches = [NSMutableArray array];
    for (CBService *service in peripheral.services) {
        if ([self uuid128:service.UUID isEqual:serviceUuid]) {
            [matches addObject:service];
        }
    }
    if (matches.count == 0) {
        return nil;
    }

    if (matches.count <= 1) {
        NSInteger idx = 0;
        for (CBCharacteristic *chr in matches.firstObject.characteristics) {
            if ([self uuid128:chr.UUID isEqual:characteristicUuid]) {
                if (idx == instanceId) return chr;
                idx++;
            }
        }
        return nil;
    }

    NSInteger idx = 0;
    for (CBService *service in matches) {
        for (CBCharacteristic *chr in service.characteristics) {
            if (idx == instanceId && [self uuid128:chr.UUID isEqual:characteristicUuid]) {
                return chr;
            }
            idx++;
        }
    }
    return nil;
}

- (CBDescriptor *)findDescriptorInCharacteristic:(CBCharacteristic *)characteristic
                                   descriptorUuid:(NSString *)descriptorUuid {
    for (CBDescriptor *desc in characteristic.descriptors) {
        if ([self uuid128:desc.UUID isEqual:descriptorUuid]) return desc;
    }
    return nil;
}

- (BOOL)uuid128:(CBUUID *)uuidA isEqual:(NSString *)uuidB {
    NSString *strA = [uuidA uuidStr];
    return [[self stripUuid:strA] isEqualToString:[self stripUuid:uuidB]];
}

- (NSString *)stripUuid:(NSString *)uuid {
    NSString *s = [uuid uppercaseString];
    s = [s stringByReplacingOccurrencesOfString:@"-" withString:@""];
    if ([s hasPrefix:@"0000"] && [s hasSuffix:@"00001000800000805F9B34FB"] && s.length == 32) {
        s = [s substringWithRange:NSMakeRange(4, 4)];
    }
    return s;
}

// Normalize a UUID string to its 128-bit lowercase representation,
// matching [CBUUID UUIDString] lowercaseString on the completion side.
// Accepts 16-bit ("180d"), 32-bit ("12345678"), or full 128-bit input.
- (NSString *)uuid128:(NSString *)uuid {
    if (uuid.length == 0) return @"";
    NSString *s = [self stripUuid:uuid];
    if (s.length == 4) {
        return [NSString stringWithFormat:@"0000%@-0000-1000-8000-00805f9b34fb", s].lowercaseString;
    }
    if (s.length == 8) {
        return [NSString stringWithFormat:@"%@-0000-1000-8000-00805f9b34fb", s].lowercaseString;
    }
    if (s.length == 32) {
        return [NSString stringWithFormat:@"%@-%@-%@-%@-%@",
                [s substringWithRange:NSMakeRange(0, 8)],
                [s substringWithRange:NSMakeRange(8, 4)],
                [s substringWithRange:NSMakeRange(12, 4)],
                [s substringWithRange:NSMakeRange(16, 4)],
                [s substringWithRange:NSMakeRange(20, 12)]].lowercaseString;
    }
    return [uuid lowercaseString];
}

// MARK: - String reading from binary buffer

- (NSString *)readString:(NSData *)data offset:(NSUInteger *)offset {
    if (*offset >= data.length) return nil;
    uint8_t len = ((const uint8_t *)data.bytes)[*offset];
    *offset += 1;
    if (len == 0) return @"";
    if (*offset + len > data.length) return nil;
    NSString *str = [[NSString alloc] initWithBytes:((const uint8_t *)data.bytes) + *offset
                                             length:len encoding:NSUTF8StringEncoding];
    *offset += len;
    return str;
}

- (NSData *)readValue:(NSData *)data {
    NSUInteger offset = 1 + 1 + 2; // cmd + flags + instanceId
    // Skip 5 strings (remoteId, serviceUuid, characteristicUuid, primaryServiceUuid, descriptorUuid)
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    for (int i = 0; i < 5; i++) {
        if (offset >= data.length) return nil;
        uint8_t len = bytes[offset];
        offset += 1 + len;
    }
    if (offset + 2 > data.length) return nil;
    uint16_t valueLen = (bytes[offset] << 8) | bytes[offset + 1];
    offset += 2;
    if (offset + valueLen > data.length) return nil;
    return [data subdataWithRange:NSMakeRange(offset, valueLen)];
}

// MARK: - Response encoding

- (NSData *)encodeSuccess {
    uint8_t buffer[7] = {1, 0, 0, 0, 0, 0, 0};
    return [NSData dataWithBytes:buffer length:7];
}

- (NSData *)encodeError:(int32_t)errorCode message:(NSString *)message {
    NSData *msgData = [message dataUsingEncoding:NSUTF8StringEncoding];
    uint16_t msgLen = (uint16_t)msgData.length;
    NSMutableData *data = [NSMutableData dataWithCapacity:7 + msgLen];
    uint8_t header[7];
    header[0] = 0;
    header[1] = (errorCode >> 24) & 0xFF;
    header[2] = (errorCode >> 16) & 0xFF;
    header[3] = (errorCode >> 8) & 0xFF;
    header[4] = errorCode & 0xFF;
    header[5] = (msgLen >> 8) & 0xFF;
    header[6] = msgLen & 0xFF;
    [data appendBytes:header length:7];
    if (msgData.length > 0) {
        [data appendData:msgData];
    }
    return data;
}

@end
