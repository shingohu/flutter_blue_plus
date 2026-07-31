package com.jmx.flutter_blue_plus;

import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattDescriptor;
import android.os.Build;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;

import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.BinaryCodec;

/**
 * Handles binary protocol for efficient BLE write operations.
 * <p>
 * Protocol format (request):
 * [0]     cmd (1 byte)
 * [1]     flags (1 byte)
 * [2-3]   instanceId (uint16 BE)
 * [4]     remoteIdLen (1 byte)
 * [5..]   remoteId (N bytes UTF-8)
 * [..]    serviceUuidLen (1 byte)
 * [..]    serviceUuid (M bytes UTF-8)
 * [..]    characteristicUuidLen (1 byte)
 * [..]    characteristicUuid (P bytes UTF-8)
 * [..]    primaryServiceUuidLen (1 byte)
 * [..]    primaryServiceUuid (Q bytes UTF-8)
 * [..]    descriptorUuidLen (1 byte)
 * [..]    descriptorUuid (R bytes UTF-8)
 * [..]    valueLen (uint16 BE)
 * [..]    value (S bytes)
 * <p>
 * Response:
 * [0]     success (1 byte, 0 or 1)
 * [1-4]   errorCode (int32 BE)
 * [5-6]   errorStrLen (uint16 BE)
 * [7..]   errorStr (N bytes UTF-8)
 */
public class BinaryProtocolHandler implements BinaryMessenger.BinaryMessageHandler {

    private static final String CHANNEL_NAME = "flutter_blue_plus/binary";

    // Command IDs
    private static final int CMD_WRITE_CHARACTERISTIC = 0x01;
    private static final int CMD_WRITE_DESCRIPTOR = 0x02;
    private static final int CMD_SET_NOTIFY_VALUE = 0x03;

    // Write flags
    private static final int FLAG_WITHOUT_RESPONSE = 1 << 0;
    private static final int FLAG_ALLOW_LONG_WRITE = 1 << 1;

    // Notify flags
    private static final int FLAG_ENABLE = 1 << 0;
    private static final int FLAG_FORCE_INDICATIONS = 1 << 1;

    private final FlutterBluePlusPlugin plugin;

    public BinaryProtocolHandler(FlutterBluePlusPlugin plugin) {
        this.plugin = plugin;
    }

    /**
     * Register the binary message handler on the given messenger.
     */
    public void register(BinaryMessenger messenger) {
        messenger.setMessageHandler(CHANNEL_NAME, this);
    }

    /**
     * Unregister the binary message handler.
     */
    public void unregister(BinaryMessenger messenger) {
        messenger.setMessageHandler(CHANNEL_NAME, null);
    }

    @Override
    public void onMessage(@Nullable ByteBuffer message, @NonNull BinaryMessenger.BinaryReply reply) {
        if (message == null || message.remaining() < 2) {
            reply.reply(encodeError(-1, "invalid message"));
            return;
        }

        try {
            byte cmd = message.get();
            byte flags = message.get();

            // instanceId (uint16 BE)
            int instanceId = 0;
            if (message.remaining() >= 2) {
                instanceId = (message.get() & 0xFF) << 8 | (message.get() & 0xFF);
            }

            // remoteId
            String remoteId = readString(message);
            if (remoteId == null) {
                reply.reply(encodeError(-1, "missing remoteId"));
                return;
            }

            // serviceUuid
            String serviceUuid = readString(message);
            if (serviceUuid == null) {
                reply.reply(encodeError(-1, "missing serviceUuid"));
                return;
            }

            // characteristicUuid
            String characteristicUuid = readString(message);
            if (characteristicUuid == null) {
                reply.reply(encodeError(-1, "missing characteristicUuid"));
                return;
            }

            // primaryServiceUuid (may be empty)
            String primaryServiceUuid = readString(message);
            if (primaryServiceUuid == null) primaryServiceUuid = "";

            // descriptorUuid (may be empty for characteristic ops)
            String descriptorUuid = readString(message);
            if (descriptorUuid == null) descriptorUuid = "";

            // Process based on command
            switch (cmd) {
                case CMD_WRITE_CHARACTERISTIC: {
                    handleWriteCharacteristic(remoteId, primaryServiceUuid, serviceUuid,
                            characteristicUuid, instanceId, flags, message, reply);
                    break;
                }
                case CMD_WRITE_DESCRIPTOR: {
                    handleWriteDescriptor(remoteId, primaryServiceUuid, serviceUuid,
                            characteristicUuid, instanceId, descriptorUuid, message, reply);
                    break;
                }
                case CMD_SET_NOTIFY_VALUE: {
                    handleSetNotifyValue(remoteId, primaryServiceUuid, serviceUuid,
                            characteristicUuid, instanceId, flags, message, reply);
                    break;
                }
                default: {
                    reply.reply(encodeError(-1, "unknown command: " + cmd));
                }
            }
        } catch (Exception e) {
            reply.reply(encodeError(-1, e.getMessage()));
        }
    }

    private void handleWriteCharacteristic(String remoteId, String primaryServiceUuid,
                                           String serviceUuid, String characteristicUuid,
                                           int instanceId, int flags,
                                           ByteBuffer message, BinaryMessenger.BinaryReply reply) {
        boolean withoutResponse = (flags & FLAG_WITHOUT_RESPONSE) != 0;
        boolean allowLongWrite = (flags & FLAG_ALLOW_LONG_WRITE) != 0;

        byte[] value = readValue(message);
        if (value == null) {
            reply.reply(encodeError(-1, "missing value"));
            return;
        }

        int writeType = withoutResponse
                ? BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                : BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT;

        BluetoothGatt gatt = plugin.getConnectedDevice(remoteId);
        if (gatt == null) {
            reply.reply(encodeError(1, "device is disconnected"));
            return;
        }

        FlutterBluePlusPlugin.ChrFound found = plugin.locateCharacteristic(
                gatt, primaryServiceUuid, serviceUuid, characteristicUuid, instanceId);
        if (found.error != null) {
            reply.reply(encodeError(2, found.error));
            return;
        }

        BluetoothGattCharacteristic characteristic = found.characteristic;

        // Check writable
        if (withoutResponse) {
            if ((characteristic.getProperties() & BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE) == 0) {
                reply.reply(encodeError(3, "WRITE_NO_RESPONSE not supported"));
                return;
            }
        } else {
            if ((characteristic.getProperties() & BluetoothGattCharacteristic.PROPERTY_WRITE) == 0) {
                reply.reply(encodeError(3, "WRITE not supported"));
                return;
            }
        }

        // Write characteristic
        boolean success;
        if (Build.VERSION.SDK_INT >= 33) {
            int rv = gatt.writeCharacteristic(characteristic, value, writeType);
            success = (rv == android.bluetooth.BluetoothStatusCodes.SUCCESS);
        } else {
            characteristic.setValue(value);
            success = gatt.writeCharacteristic(characteristic);
        }

        if (success) {
            // Store the reply so it can be completed when onCharacteristicWrite fires.
            // This provides flow control: the callback fires when the BLE stack has
            // processed the write and has buffer space for the next one.
            String key = remoteId + ":" + primaryServiceUuid + ":" + serviceUuid + ":"
                    + characteristicUuid + ":" + instanceId;
            plugin.storeBinaryReply(key, reply);
            plugin.storeWriteValue(key, value);
        } else {
            reply.reply(encodeError(4, "writeCharacteristic failed"));
        }
    }

    private void handleWriteDescriptor(String remoteId, String primaryServiceUuid,
                                       String serviceUuid, String characteristicUuid,
                                       int instanceId, String descriptorUuid,
                                       ByteBuffer message, BinaryMessenger.BinaryReply reply) {
        byte[] value = readValue(message);
        if (value == null) {
            reply.reply(encodeError(-1, "missing value"));
            return;
        }

        BluetoothGatt gatt = plugin.getConnectedDevice(remoteId);
        if (gatt == null) {
            reply.reply(encodeError(1, "device is disconnected"));
            return;
        }

        FlutterBluePlusPlugin.ChrFound found = plugin.locateCharacteristic(
                gatt, primaryServiceUuid, serviceUuid, characteristicUuid, instanceId);
        if (found.error != null) {
            reply.reply(encodeError(2, found.error));
            return;
        }

        BluetoothGattDescriptor descriptor = plugin.locateDescriptor(
                descriptorUuid, found.characteristic);
        if (descriptor == null) {
            reply.reply(encodeError(5, "descriptor not found"));
            return;
        }

        descriptor.setValue(value);
        boolean success = gatt.writeDescriptor(descriptor);

        if (success) {
            String key = remoteId + ":" + primaryServiceUuid + ":" + serviceUuid + ":"
                    + characteristicUuid + ":" + instanceId + ":" + descriptorUuid;
            plugin.storeBinaryReply(key, reply);
        } else {
            reply.reply(encodeError(4, "writeDescriptor failed"));
        }
    }

    private void handleSetNotifyValue(String remoteId, String primaryServiceUuid,
                                      String serviceUuid, String characteristicUuid,
                                      int instanceId, int flags,
                                      ByteBuffer message, BinaryMessenger.BinaryReply reply) {
        boolean enable = (flags & FLAG_ENABLE) != 0;
        boolean forceIndications = (flags & FLAG_FORCE_INDICATIONS) != 0;

        BluetoothGatt gatt = plugin.getConnectedDevice(remoteId);
        if (gatt == null) {
            reply.reply(encodeError(1, "device is disconnected"));
            return;
        }

        FlutterBluePlusPlugin.ChrFound found = plugin.locateCharacteristic(
                gatt, primaryServiceUuid, serviceUuid, characteristicUuid, instanceId);
        if (found.error != null) {
            reply.reply(encodeError(2, found.error));
            return;
        }

        // Enable notification on the characteristic
        boolean success = gatt.setCharacteristicNotification(found.characteristic, enable);
        if (!success) {
            reply.reply(encodeError(6, "setCharacteristicNotification failed"));
            return;
        }

        // Write to CCCD descriptor
        BluetoothGattDescriptor cccd = found.characteristic.getDescriptor(
                java.util.UUID.fromString("00002902-0000-1000-8000-00805f9b34fb"));
        if (cccd == null) {
            reply.reply(encodeError(7, "CCCD descriptor not found"));
            return;
        }

        byte[] cccdValue;
        if (enable) {
            cccdValue = forceIndications
                    ? BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
                    : BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE;
        } else {
            cccdValue = BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE;
        }

        cccd.setValue(cccdValue);
        boolean written = gatt.writeDescriptor(cccd);

        if (written) {
            // Include the CCCD descriptorUuid so the key matches the one built in
            // FlutterBluePlusPlugin.onDescriptorWrite (which appends descriptorUuid).
            String key = remoteId + ":" + primaryServiceUuid + ":" + serviceUuid + ":"
                    + characteristicUuid + ":" + instanceId + ":" + plugin.uuidStr(cccd.getUuid());
            plugin.storeBinaryReply(key, reply);
        } else {
            reply.reply(encodeError(4, "writeDescriptor(CCCD) failed"));
        }
    }

    // --- Helper methods ---

    @Nullable
    private static String readString(ByteBuffer buffer) {
        if (buffer.remaining() < 1) return null;
        int len = buffer.get() & 0xFF;
        if (len == 0) return "";
        if (buffer.remaining() < len) return null;
        byte[] bytes = new byte[len];
        buffer.get(bytes);
        return new String(bytes, StandardCharsets.UTF_8);
    }

    @Nullable
    private static byte[] readValue(ByteBuffer buffer) {
        if (buffer.remaining() < 2) return null;
        int len = (buffer.get() & 0xFF) << 8 | (buffer.get() & 0xFF);
        if (len == 0) return new byte[0];
        if (buffer.remaining() < len) return null;
        byte[] value = new byte[len];
        buffer.get(value);
        return value;
    }

    @NonNull
    private static ByteBuffer encodeError(int errorCode, String errorString) {
        byte[] errorStrBytes = errorString != null
                ? errorString.getBytes(StandardCharsets.UTF_8)
                : new byte[0];
        ByteBuffer response = ByteBuffer.allocate(1 + 4 + 2 + errorStrBytes.length);
        response.order(ByteOrder.BIG_ENDIAN);
        response.put((byte) 0); // success = false
        response.putInt(errorCode);
        response.putShort((short) errorStrBytes.length);
        if (errorStrBytes.length > 0) {
            response.put(errorStrBytes);
        }
        response.flip();
        return response;
    }

    @NonNull
    static ByteBuffer encodeSuccess() {
        ByteBuffer response = ByteBuffer.allocate(1 + 4 + 2);
        response.order(ByteOrder.BIG_ENDIAN);
        response.put((byte) 1); // success = true
        response.putInt(0);     // errorCode
        response.putShort((short) 0); // errorStrLen
        response.flip();
        return response;
    }
}
