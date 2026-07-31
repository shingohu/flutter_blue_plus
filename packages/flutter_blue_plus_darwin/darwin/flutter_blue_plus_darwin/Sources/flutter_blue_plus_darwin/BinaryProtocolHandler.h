#import <Flutter/Flutter.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Binary protocol handler for low-latency BLE write operations.
 *
 * Uses BasicMessageChannel + BinaryCodec to avoid MethodChannel
 * serialization overhead for write operations.
 *
 * Responses are completed asynchronously via callbacks from
 * FlutterBluePlusPlugin's CoreBlooth delegate methods.
 */
@interface BinaryProtocolHandler : NSObject

- (instancetype)initWithPlugin:(FlutterBluePlusPlugin *)plugin;
- (void)registerWithMessenger:(NSObject<FlutterBinaryMessenger> *)messenger;
- (void)unregisterWithMessenger:(NSObject<FlutterBinaryMessenger> *)messenger;

/// Called from FlutterBluePlusPlugin's didWriteValueForCharacteristic: callback.
- (void)completeWriteCharacteristic:(NSString *)remoteId
                   primaryServiceUuid:(NSString *)primaryServiceUuid
                         serviceUuid:(NSString *)serviceUuid
                   characteristicUuid:(NSString *)characteristicUuid
                          instanceId:(NSInteger)instanceId
                             success:(BOOL)success
                           errorCode:(int32_t)errorCode
                         errorString:(NSString *)errorString;

/// Called from FlutterBluePlusPlugin's didWriteValueForDescriptor: callback.
- (void)completeWriteDescriptor:(NSString *)remoteId
               primaryServiceUuid:(NSString *)primaryServiceUuid
                     serviceUuid:(NSString *)serviceUuid
               characteristicUuid:(NSString *)characteristicUuid
                      instanceId:(NSInteger)instanceId
                  descriptorUuid:(NSString *)descriptorUuid
                         success:(BOOL)success
                       errorCode:(int32_t)errorCode
                     errorString:(NSString *)errorString;

/// Called from FlutterBluePlusPlugin's didUpdateNotificationStateForCharacteristic: callback.
- (void)completeSetNotifyValue:(NSString *)remoteId
              primaryServiceUuid:(NSString *)primaryServiceUuid
                    serviceUuid:(NSString *)serviceUuid
              characteristicUuid:(NSString *)characteristicUuid
                     instanceId:(NSInteger)instanceId
                        success:(BOOL)success
                      errorCode:(int32_t)errorCode
                    errorString:(NSString *)errorString;

/// Clear all pending replies for a given remoteId (e.g. on disconnect).
- (void)clearPendingRepliesForRemoteId:(NSString *)remoteId;

@end

NS_ASSUME_NONNULL_END
