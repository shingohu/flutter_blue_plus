// Copyright 2017-2023, Charles Weinberger
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of '../flutter_blue_plus.dart';

class BluetoothDevice {
  // A timed-out native connect can still submit work later (e.g. after a
  // permission dialog). Keep its cancellation barrier until that call settles
  // and native confirms disconnection; a new connect must not overtake it.
  static final Map<DeviceIdentifier, _PendingConnection> _pendingConnections = {};

  Future<void> _cancelPendingConnection(_PendingConnection pending, {int androidDelay = 2000}) {
    pending.cancelled = true;
    return pending.cleanup ??= _finishConnectionCancellation(pending, androidDelay).whenComplete(() {
      pending.cleanup = null; // Failed cleanup may be retried, but stays fenced.
    });
  }

  Future<void> _finishConnectionCancellation(_PendingConnection pending, int androidDelay) async {
    await _ensureAndroidDisconnectionDelay(androidDelay);
    final earlyCancel = FlutterBluePlus._invokePlatform(
        () => FlutterBluePlusPlatform.instance.disconnect(BmDisconnectRequest(remoteId: remoteId)));
    // Try to interrupt promptly, then cancel again after any late submission.
    await Future.wait<void>([
      pending.invocation.then<void>((_) {}, onError: (Object _) {}),
      earlyCancel.then<void>((_) {}, onError: (Object _) {}),
    ]);
    final scope =
        _OperationScope(this, "cancelConnection", const Duration(seconds: 35), connected: false, adapter: false);
    try {
      final disconnected = scope.first(_responseStreams.disconnected);
      final changed = await scope.invoke(() => FlutterBluePlus._invokePlatform(
          () => FlutterBluePlusPlatform.instance.disconnect(BmDisconnectRequest(remoteId: remoteId))));
      if (changed) await scope.wait(disconnected);
      if (identical(_pendingConnections[remoteId], pending)) _pendingConnections.remove(remoteId);
      _OperationScope._needsReconnect.remove(remoteId);
      if (!kIsWeb && Platform.isAndroid) FlutterBluePlus._connectTimestamp.remove(remoteId);
    } finally {
      await scope.close();
    }
  }

  final DeviceIdentifier remoteId;
  _BluetoothDeviceResponseStreams? _cachedResponseStreams;

  _BluetoothDeviceResponseStreams get _responseStreams =>
      _cachedResponseStreams ??= _BluetoothDeviceResponseStreams(remoteId);

  BluetoothDevice({
    required this.remoteId,
  });

  @override
  bool operator ==(Object other) {
    return identical(this, other) || other is BluetoothDevice && remoteId == other.remoteId;
  }

  @override
  int get hashCode => remoteId.hashCode;

  /// Create a device from an id
  ///   - to connect, this device must have been discovered by your app in a previous scan
  ///   - iOS uses 128-bit uuids the remoteId, e.g. e006b3a7-ef7b-4980-a668-1f8005f84383
  ///   - Android uses 48-bit mac addresses as the remoteId, e.g. 06:E5:28:3B:FD:E0
  BluetoothDevice.fromId(String remoteId) : remoteId = DeviceIdentifier(remoteId);

  /// platform name
  /// - this name is kept track of by the platform
  /// - this name usually persist between app restarts
  /// - iOS: after you connect, iOS uses the GAP name characteristic (0x2A00)
  ///        if it exists. Otherwise iOS use the advertised name.
  /// - Android: always uses the advertised name
  String get platformName => FlutterBluePlus._platformNames[remoteId] ?? "";

  /// Advertised Named
  ///  - this is the name advertised by the device during scanning
  ///  - it is only available after you scan with FlutterBluePlus
  ///  - it is cleared when the app restarts.
  ///  - not all devices advertise a name
  String get advName => FlutterBluePlus._advNames[remoteId] ?? "";

  /// Get services
  ///  returns empty when:
  ///   - disconnected
  ///   - discoverServices() has not been called
  ///   - your device does not have services (rare)
  List<BluetoothService> get servicesList {
    BmDiscoverServicesResult? result = FlutterBluePlus._knownServices[remoteId];
    if (result == null) {
      return [];
    } else {
      return _bmToPrimaryServices(result.services);
    }
  }

  /// Register a subscription to be canceled when the device is disconnected.
  /// This function simplifies cleanup, so you can prevent creating duplicate stream subscriptions.
  ///   - this is an optional convenience function
  ///   - prevents accidentally creating duplicate subscriptions on each reconnection.
  ///   - [next] if true, the the stream will be canceled only on the *next* disconnection.
  ///     This is useful if you setup your subscriptions before you connect.
  ///   - [delayed] Note: This option is only meant for `connectionState` subscriptions.
  ///     When `true`, we cancel after a small delay. This ensures the `connectionState`
  ///     listener receives the `disconnected` event.
  void cancelWhenDisconnected(StreamSubscription subscription, {bool next = false, bool delayed = false}) {
    if (isConnected == false && next == false) {
      subscription.cancel(); // cancel immediately if already disconnected.
    } else if (delayed) {
      FlutterBluePlus._delayedSubscriptions[remoteId] ??= [];
      FlutterBluePlus._delayedSubscriptions[remoteId]!.add(subscription);
    } else {
      FlutterBluePlus._deviceSubscriptions[remoteId] ??= [];
      FlutterBluePlus._deviceSubscriptions[remoteId]!.add(subscription);
    }
  }

  /// Returns true if autoConnect is currently enabled for this device
  bool get isAutoConnectEnabled {
    return FlutterBluePlus._autoConnect.contains(remoteId);
  }

  /// Returns true if this device is currently connected to your app
  bool get isConnected {
    if (FlutterBluePlus._connectionStates[remoteId] == null) {
      return false;
    } else {
      var state = FlutterBluePlus._connectionStates[remoteId]!.connectionState;
      return state == BmConnectionStateEnum.connected;
    }
  }

  /// Returns true if this device is currently disconnected from your app
  bool get isDisconnected => isConnected == false;

  /// Establishes a connection to the Bluetooth Device.
  ///   [timeout] if timeout occurs, cancel the connection request and throw exception
  ///   [mtu] Android & OHOS only. Request a larger mtu right after connection, if set.
  ///   [autoConnect] reconnect whenever the device is found
  ///      - if true, this function always returns immediately.
  ///      - you must listen to `connectionState` to know when connection occurs.
  ///      - auto connect is turned off by calling `disconnect`
  ///      - auto connect results in a slower connection process compared to a direct connection
  ///        because it relies on the internal scheduling of background scans.
  Future<void> connect({
    Duration timeout = const Duration(seconds: 35),
    int? mtu = 512,
    bool autoConnect = false,
  }) async {
    // If you hit this assert, you must set `mtu:null`, i.e `device.connect(mtu:null, autoConnect:true)`
    // and you'll have to call `requestMtu` yourself. `autoConnect` is not compatibile with `mtu`.
    assert((mtu == null) || !autoConnect, "mtu and auto connect are incompatible");

    // make sure no one else is calling disconnect on this device
    _Mutex dmtx = _MutexFactory.getMutexForKey(FlutterBluePlus._disconnectMutexKey(remoteId));
    bool dtook = await dmtx.take(timeout: timeout, function: "connect");

    // Only allow a single BLE operation to be underway per device.
    _Mutex mtx = _MutexFactory.getMutexForKey(FlutterBluePlus._bleOperationMutexKey(remoteId));
    try {
      await mtx.take(timeout: timeout, function: "connect");
    } catch (_) {
      dmtx.give();
      rethrow;
    }
    final scope = _OperationScope(this, "connect", timeout, connected: false);
    _PendingConnection? attempt;
    try {
      final pending = _pendingConnections[remoteId];
      if (pending != null) await scope.wait(_cancelPendingConnection(pending));
      // remember auto connect value
      if (autoConnect) {
        FlutterBluePlus._autoConnect.add(remoteId);
      }

      var request = BmConnectRequest(
        remoteId: remoteId,
        autoConnect: autoConnect,
      );

      // Start listening now, before invokeMethod, to ensure we don't miss the response
      Future<BmConnectionStateResponse> futureState = scope.first(_responseStreams.connectionState);

      // record connection time
      if (!kIsWeb && Platform.isAndroid) {
        FlutterBluePlus._connectTimestamp[remoteId] = DateTime.now();
      }

      // invoke
      bool changed = false;
      if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on && autoConnect && !kIsWeb) {
        // we'll initiate the autoconnect later when the adapter is turned on
        // note(web): we cannot get adapter state, so we must try the connection anyway
      } else {
        changed = await scope.invoke(() {
          final invocation = FlutterBluePlus._invokePlatform(() => FlutterBluePlusPlatform.instance.connect(request));
          attempt = _PendingConnection(invocation);
          _pendingConnections[remoteId] = attempt!;
          return invocation;
        });
      }

      // we return the disconnect mutex now so that this
      // connection attempt can be canceled by calling disconnect
      dtook = dmtx.give();

      // only wait for connection if we weren't already connected
      if (changed && !autoConnect) {
        BmConnectionStateResponse response = await scope.wait(futureState);

        // failure?
        if (response.connectionState == BmConnectionStateEnum.disconnected) {
          if (response.disconnectReasonCode == bmUserCanceledErrorCode) {
            throw FlutterBluePlusException(
                ErrorPlatform.fbp, "connect", FbpErrorCode.connectionCanceled.index, "connection canceled");
          } else {
            throw FlutterBluePlusException(
                _nativeError, "connect", response.disconnectReasonCode, response.disconnectReasonString);
          }
        }
      }
      if (attempt?.cancelled == true) {
        throw FlutterBluePlusException(
            ErrorPlatform.fbp, "connect", FbpErrorCode.connectionCanceled.index, "connection canceled");
      }
      if (attempt != null && identical(_pendingConnections[remoteId], attempt)) {
        _pendingConnections.remove(remoteId);
      }
    } catch (_) {
      if (attempt != null && identical(_pendingConnections[remoteId], attempt)) {
        FlutterBluePlus._autoConnect.remove(remoteId);
        _cancelPendingConnection(attempt!).ignore();
      }
      rethrow;
    } finally {
      await scope.close();
      if (dtook) {
        dmtx.give();
      }
      mtx.give();
    }

    // request larger mtu
    if (!kIsWeb && (Platform.isAndroid || Platform.operatingSystem == 'ohos') && isConnected && mtu != null) {
      await requestMtu(mtu);
    }
  }

  /// Cancels connection to the Bluetooth Device
  ///   - [queue] If true, this disconnect request will be executed after all other operations complete.
  ///     If false, this disconnect request will be executed right now, i.e. skipping to the front
  ///     of the fbp operation queue, which is useful to cancel an in-progress connection attempt.
  ///   - [androidDelay] Android only. Minimum gap in milliseconds between connect and disconnect to
  ///     workaround a race condition that leaves connection stranded. A stranded connection in this case
  ///     refers to a connection that FBP and Android Bluetooth stack are not aware of and thus cannot be
  ///     disconnected because there is no gatt handle.
  ///     https://issuetracker.google.com/issues/37121040
  ///     From testing, 2 second delay appears to be enough.
  Future<void> disconnect({
    Duration timeout = const Duration(seconds: 35),
    bool queue = true,
    int androidDelay = 2000,
  }) async {
    // Only allow a single disconnect operation at a time on this device
    _Mutex dtx = _MutexFactory.getMutexForKey(FlutterBluePlus._disconnectMutexKey(remoteId));
    await dtx.take(timeout: timeout, function: "disconnect");

    // Queue behind other operations for this device only.
    final mtx = queue ? _MutexFactory.getMutexForKey(FlutterBluePlus._bleOperationMutexKey(remoteId)) : null;
    try {
      if (queue) await mtx!.take(timeout: timeout, function: "disconnect");
    } catch (_) {
      dtx.give();
      rethrow;
    }
    final scope = _OperationScope(this, "disconnect", timeout, connected: false, adapter: false);
    try {
      // remove from auto connect list if there
      FlutterBluePlus._autoConnect.remove(remoteId);

      final pending = _pendingConnections[remoteId];
      if (pending != null) {
        await scope.wait(_cancelPendingConnection(pending, androidDelay: androidDelay));
        _OperationScope._needsReconnect.remove(remoteId);
        return;
      }

      // Start listening now, before invokeMethod, to ensure we don't miss the response
      Future<BmConnectionStateResponse> futureState = scope.first(_responseStreams.disconnected);

      // Workaround Android race condition
      await scope.wait(_ensureAndroidDisconnectionDelay(androidDelay));

      // invoke
      bool changed = await scope.invoke(() => FlutterBluePlus._invokePlatform(
          () => FlutterBluePlusPlatform.instance.disconnect(BmDisconnectRequest(remoteId: remoteId))));

      // only wait for disconnection if weren't already disconnected
      if (changed) {
        await scope.wait(futureState);
      }

      _OperationScope._needsReconnect.remove(remoteId);
      if (!kIsWeb && Platform.isAndroid) {
        // Disconnected, remove connect timestamp
        FlutterBluePlus._connectTimestamp.remove(remoteId);
      }
    } finally {
      await scope.close();
      dtx.give();
      if (queue) {
        mtx!.give();
      }
    }
  }

  /// Discover services, characteristics, and descriptors of the remote device
  ///   - Note: `discoverServices` must be re-called after *every* connection!
  ///   - [subscribeToServicesChanged] Android & Linux Only: If true, after discovering services we will subscribe
  ///     to the Services Changed Characteristic (0x2A05) used for the `device.onServicesReset` stream.
  ///     Note: this behavior happens automatically on iOS and cannot be disabled
  Future<List<BluetoothService>> discoverServices(
      {bool subscribeToServicesChanged = true, Duration timeout = const Duration(seconds: 15)}) async {
    // check connected
    if (isDisconnected) {
      throw FlutterBluePlusException(
          ErrorPlatform.fbp, "discoverServices", FbpErrorCode.deviceIsDisconnected.index, "device is not connected");
    }

    // Only allow a single BLE operation to be underway per device.
    _Mutex mtx = _MutexFactory.getMutexForKey(FlutterBluePlus._bleOperationMutexKey(remoteId));
    await mtx.take(timeout: timeout, function: "discoverServices");

    List<BluetoothService> result = [];

    final scope = _OperationScope(this, "discoverServices", timeout);
    try {
      // Start listening now, before invokeMethod, to ensure we don't miss the response
      Future<BmDiscoverServicesResult> futureResponse = scope.first(_responseStreams.discoveredServices);

      // invoke
      await scope.invoke(() => FlutterBluePlus._invokePlatform(
          () => FlutterBluePlusPlatform.instance.discoverServices(BmDiscoverServicesRequest(remoteId: remoteId))));

      // wait for response
      BmDiscoverServicesResult response = await scope.wait(futureResponse);

      // failed?
      if (!response.success) {
        throw FlutterBluePlusException(_nativeError, "discoverServices", response.errorCode, response.errorString);
      }

      // return primary services
      result = _bmToPrimaryServices(response.services);

      result = result;
    } finally {
      await scope.close();
      mtx.give();
    }

    // in order to match iOS behavior on all platforms (except web),
    // we always listen to the Services Changed characteristic if it exists.
    if (subscribeToServicesChanged) {
      if (!kIsWeb && !Platform.isIOS && !Platform.isMacOS) {
        BluetoothCharacteristic? c = _servicesChangedCharacteristic;
        if (c != null && (c.properties.notify || c.properties.indicate) && c.isNotifying == false) {
          await c.setNotifyValue(true);
        }
      }
    }

    return result;
  }

  /// The most recent disconnection reason
  DisconnectReason? get disconnectReason {
    if (FlutterBluePlus._connectionStates[remoteId] == null) {
      return null;
    }
    int? code = FlutterBluePlus._connectionStates[remoteId]!.disconnectReasonCode;
    String? description = FlutterBluePlus._connectionStates[remoteId]!.disconnectReasonString;
    return DisconnectReason(_nativeError, code, description);
  }

  /// The current connection state *of our app* to the device
  Stream<BluetoothConnectionState> get connectionState {
    // initial value - Note: we only care about the current connection state of
    // *our* app, which is why we can use our cached value, or assume disconnected
    BluetoothConnectionState initialValue = BluetoothConnectionState.disconnected;
    if (FlutterBluePlus._connectionStates[remoteId] != null) {
      initialValue = _bmToConnectionState(FlutterBluePlus._connectionStates[remoteId]!.connectionState);
    }
    return FlutterBluePlusPlatform.instance.onConnectionStateChanged
        .where((p) => p.remoteId == remoteId)
        .map((p) => _bmToConnectionState(p.connectionState))
        .newStreamWithInitialValue(initialValue);
  }

  /// The current MTU size in bytes
  int get mtuNow {
    // get initial value from our cache
    return FlutterBluePlus._mtuValues[remoteId]?.mtu ?? 23;
  }

  /// Stream emits a value:
  ///   - immediately when first listened to
  ///   - whenever the mtu changes
  Stream<int> get mtu {
    // get initial value from our cache
    int initialValue = FlutterBluePlus._mtuValues[remoteId]?.mtu ?? 23;
    return FlutterBluePlusPlatform.instance.onMtuChanged
        .where((p) => p.remoteId == remoteId)
        .map((p) => p.mtu)
        .newStreamWithInitialValue(initialValue);
  }

  /// Services Reset Stream
  ///  - uses the GAP Services Changed characteristic (0x2A05)
  ///  - you must re-call discoverServices() when services are reset
  Stream<void> get onServicesReset {
    return FlutterBluePlusPlatform.instance.onServicesReset
        .where((p) => p.remoteId == remoteId)
        .map<void>((_) {/* no return, so this is a void callback */});
  }

  /// Read the RSSI of connected remote device
  Future<int> readRssi({Duration timeout = const Duration(seconds: 15)}) async {
    // check connected
    if (isDisconnected) {
      throw FlutterBluePlusException(
          ErrorPlatform.fbp, "readRssi", FbpErrorCode.deviceIsDisconnected.index, "device is not connected");
    }

    // Only allow a single BLE operation to be underway per device.
    _Mutex mtx = _MutexFactory.getMutexForKey(FlutterBluePlus._bleOperationMutexKey(remoteId));
    await mtx.take(timeout: timeout, function: "readRssi");

    int rssi = 0;

    final scope = _OperationScope(this, "readRssi", timeout);
    try {
      // Start listening now, before invokeMethod, to ensure we don't miss the response
      Future<BmReadRssiResult> futureResponse = scope.first(_responseStreams.readRssi);

      // invoke
      await scope.invoke(() => FlutterBluePlus._invokePlatform(
          () => FlutterBluePlusPlatform.instance.readRssi(BmReadRssiRequest(remoteId: remoteId))));

      // wait for response
      BmReadRssiResult response = await scope.wait(futureResponse);

      // failed?
      if (!response.success) {
        throw FlutterBluePlusException(_nativeError, "readRssi", response.errorCode, response.errorString);
      }
      rssi = response.rssi;
    } finally {
      await scope.close();
      mtx.give();
    }

    return rssi;
  }

  /// Request to change MTU (Android & OHOS only)
  ///  - returns new MTU
  ///  - [predelay] adds delay to avoid race conditions on some peripherals. see comments below.
  Future<int> requestMtu(int desiredMtu,
      {double predelay = 0.35, Duration timeout = const Duration(seconds: 15)}) async {
    // check platform
    if (kIsWeb || (!Platform.isAndroid && Platform.operatingSystem != 'ohos')) {
      throw FlutterBluePlusException(ErrorPlatform.fbp, "requestMtu", FbpErrorCode.androidOnly.index, "android-only");
    }

    // check connected
    if (isDisconnected) {
      throw FlutterBluePlusException(
          ErrorPlatform.fbp, "requestMtu", FbpErrorCode.deviceIsDisconnected.index, "device is not connected");
    }

    // Only allow a single BLE operation to be underway per device.
    _Mutex mtx = _MutexFactory.getMutexForKey(FlutterBluePlus._bleOperationMutexKey(remoteId));
    await mtx.take(timeout: timeout, function: "requestMtu");

    // predelay
    if (predelay > 0) {
      // hack: By adding delay before we call `requestMtu`, we can avoid
      // a race condition that can cause `discoverServices` to timeout or fail.
      //
      // Note: This hack is only needed for peripherals that automatically send an
      // MTU update right after connection. If your peripherals does not do that,
      // you can set this delay to zero. Other people may need to increase it.
      //
      // The race condition goes like this:
      //  1. you call `requestMtu` right after connection
      //  2. some peripherals automatically send a new MTU right after connection, without being asked
      //  3. your call to `requestMtu` confuses the results from step 1 and step 2, and returns to early
      //  4. the user then calls `discoverServices`, thinking that `requestMtu` has finished
      //  5. in reality, `requestMtu` is still happening, and the call to `discoverServices` will fail/timeout
      //
      // Adding delay before we call `requestMtu` helps ensure
      // that the automatic mtu update has already happened.
      await Future.delayed(Duration(milliseconds: (predelay * 1000).toInt()));
    }

    var mtu = 0;

    final scope = _OperationScope(this, "requestMtu", timeout);
    try {
      var request = BmMtuChangeRequest(
        remoteId: remoteId,
        mtu: desiredMtu,
      );

      // Start listening now, before invokeMethod, to ensure we don't miss the response
      Future<int> futureResponse = scope.first(_responseStreams.mtu);

      // invoke
      await scope
          .invoke(() => FlutterBluePlus._invokePlatform(() => FlutterBluePlusPlatform.instance.requestMtu(request)));

      // wait for response
      mtu = await scope.wait(futureResponse);
    } finally {
      await scope.close();
      mtx.give();
    }

    return mtu;
  }

  /// Request connection priority update (Android only)
  Future<void> requestConnectionPriority({required ConnectionPriority connectionPriorityRequest}) async {
    // check android
    if (kIsWeb || !Platform.isAndroid) {
      throw FlutterBluePlusException(
          ErrorPlatform.fbp, "requestConnectionPriority", FbpErrorCode.androidOnly.index, "android-only");
    }

    // check connected
    if (isDisconnected) {
      throw FlutterBluePlusException(ErrorPlatform.fbp, "requestConnectionPriority",
          FbpErrorCode.deviceIsDisconnected.index, "device is not connected");
    }

    var request = BmConnectionPriorityRequest(
      remoteId: remoteId,
      connectionPriority: _bmFromConnectionPriority(connectionPriorityRequest),
    );

    // invoke
    await FlutterBluePlus._invokePlatform(() => FlutterBluePlusPlatform.instance.requestConnectionPriority(request));
  }

  /// Set the preferred connection (Android Only)
  ///   - [txPhy] bitwise OR of all allowed phys for Tx, e.g. (Phy.le2m.mask | Phy.leCoded.mask)
  ///   - [txPhy] bitwise OR of all allowed phys for Rx, e.g. (Phy.le2m.mask | Phy.leCoded.mask)
  ///   - [option] preferred coding to use when transmitting on Phy.leCoded
  /// Please note that this is just a recommendation given to the system.
  Future<void> setPreferredPhy({
    required int txPhy,
    required int rxPhy,
    required PhyCoding option,
  }) async {
    // check android
    if (kIsWeb || !Platform.isAndroid) {
      throw FlutterBluePlusException(
          ErrorPlatform.fbp, "setPreferredPhy", FbpErrorCode.androidOnly.index, "android-only");
    }

    // check connected
    if (isDisconnected) {
      throw FlutterBluePlusException(
          ErrorPlatform.fbp, "setPreferredPhy", FbpErrorCode.deviceIsDisconnected.index, "device is not connected");
    }

    var request = BmPreferredPhy(
      remoteId: remoteId,
      txPhy: txPhy,
      rxPhy: rxPhy,
      phyOptions: option.index,
    );

    // invoke
    await FlutterBluePlus._invokePlatform(() => FlutterBluePlusPlatform.instance.setPreferredPhy(request));
  }

  /// Force the bonding popup to show now (Android & OHOS only)
  /// Note! calling this is usually not necessary!! The platform does it automatically.
  /// On OHOS, [pin] is ignored and pairing is handled by the system popup.
  Future<void> createBond({Duration timeout = const Duration(seconds: 90), Uint8List? pin}) async {
    // check platform
    if (kIsWeb || (!Platform.isAndroid && Platform.operatingSystem != 'ohos')) {
      throw FlutterBluePlusException(ErrorPlatform.fbp, "createBond", FbpErrorCode.androidOnly.index, "android-only");
    }

    // check connected
    if (isDisconnected) {
      throw FlutterBluePlusException(
          ErrorPlatform.fbp, "createBond", FbpErrorCode.deviceIsDisconnected.index, "device is not connected");
    }

    // Only allow a single BLE operation to be underway per device.
    _Mutex mtx = _MutexFactory.getMutexForKey(FlutterBluePlus._bleOperationMutexKey(remoteId));
    await mtx.take(timeout: timeout, function: "createBond");

    final scope = _OperationScope(this, "createBond", timeout);
    try {
      // Start listening now, before invokeMethod, to ensure we don't miss the response
      Future<BmBondStateResponse> futureResponse = scope.first(_responseStreams.bondStateChange);

      // invoke
      bool changed = await scope.invoke(() => FlutterBluePlus._invokePlatform(
          () => FlutterBluePlusPlatform.instance.createBond(BmCreateBondRequest(remoteId: remoteId, pin: pin))));

      // only wait for 'bonded' if we weren't already bonded
      if (changed) {
        BmBondStateResponse bs = await scope.wait(futureResponse);

        // success?
        if (bs.bondState != BmBondStateEnum.bonded) {
          throw FlutterBluePlusException(ErrorPlatform.fbp, "createBond", FbpErrorCode.createBondFailed.hashCode,
              "Failed to create bond. ${bs.bondState}");
        }
      }
    } finally {
      await scope.close();
      mtx.give();
    }
  }

  /// Remove bond (Android Only)
  Future<void> removeBond({Duration timeout = const Duration(seconds: 30)}) async {
    // check android
    if (kIsWeb || !Platform.isAndroid) {
      throw FlutterBluePlusException(ErrorPlatform.fbp, "removeBond", FbpErrorCode.androidOnly.index, "android-only");
    }

    // Only allow a single BLE operation to be underway per device.
    _Mutex mtx = _MutexFactory.getMutexForKey(FlutterBluePlus._bleOperationMutexKey(remoteId));
    await mtx.take(timeout: timeout, function: "removeBond");

    final scope = _OperationScope(this, "removeBond", timeout, connected: false);
    try {
      // Start listening now, before invokeMethod, to ensure we don't miss the response
      Future<BmBondStateResponse> futureResponse = scope.first(_responseStreams.bondStateChange);

      // invoke
      bool changed = await scope.invoke(() => FlutterBluePlus._invokePlatform(
          () => FlutterBluePlusPlatform.instance.removeBond(BmRemoveBondRequest(remoteId: remoteId))));

      // only wait for 'unbonded' state if we weren't already unbonded
      if (changed) {
        BmBondStateResponse bs = await scope.wait(futureResponse);

        // success?
        if (bs.bondState != BmBondStateEnum.none) {
          throw FlutterBluePlusException(ErrorPlatform.fbp, "createBond", FbpErrorCode.removeBondFailed.hashCode,
              "Failed to remove bond. ${bs.bondState}");
        }
      }
    } finally {
      await scope.close();
      mtx.give();
    }
  }

  /// Refresh ble services & characteristics (Android Only)
  Future<void> clearGattCache() async {
    // check android
    if (kIsWeb || !Platform.isAndroid) {
      throw FlutterBluePlusException(
          ErrorPlatform.fbp, "clearGattCache", FbpErrorCode.androidOnly.index, "android-only");
    }

    // check connected
    if (isDisconnected) {
      throw FlutterBluePlusException(
          ErrorPlatform.fbp, "clearGattCache", FbpErrorCode.deviceIsDisconnected.index, "device is not connected");
    }

    // invoke
    await FlutterBluePlus._invokePlatform(
        () => FlutterBluePlusPlatform.instance.clearGattCache(BmClearGattCacheRequest(remoteId: remoteId)));
  }

  /// Get the current bondState of the device (Android & OHOS only)
  Stream<BluetoothBondState> get bondState async* {
    // check platform
    if (kIsWeb || (!Platform.isAndroid && Platform.operatingSystem != 'ohos')) {
      throw FlutterBluePlusException(ErrorPlatform.fbp, "bondState", FbpErrorCode.androidOnly.index, "android-only");
    }

    // get current state if needed
    if (FlutterBluePlus._bondStates[remoteId] == null) {
      var val = await FlutterBluePlus._invokePlatform(
          () => FlutterBluePlusPlatform.instance.getBondState(BmBondStateRequest(remoteId: remoteId)));
      // update _bondStates if it is still null after the await
      if (FlutterBluePlus._bondStates[remoteId] == null) {
        FlutterBluePlus._bondStates[remoteId] = val;
      }
    }

    yield* FlutterBluePlusPlatform.instance.onBondStateChanged
        .where((p) => p.remoteId == remoteId)
        .map((p) => _bmToBondState(p.bondState))
        .newStreamWithInitialValue(_bmToBondState(FlutterBluePlus._bondStates[remoteId]!.bondState));
  }

  /// Get the previous bondState of the device (Android only).
  /// OHOS does not expose the previous bond state, so this is always null there.
  BluetoothBondState? get prevBondState {
    var b = FlutterBluePlus._bondStates[remoteId]?.prevState;
    return b != null ? _bmToBondState(b) : null;
  }

  /// Get the Services Changed characteristic (0x2A05)
  BluetoothCharacteristic? get _servicesChangedCharacteristic {
    final Guid gattUuid = Guid("1801");
    final Guid servicesChangedUuid = Guid("2A05");
    BluetoothService? gatt = servicesList._firstWhereOrNull((svc) => svc.uuid == gattUuid);
    return gatt?.characteristics._firstWhereOrNull((chr) => chr.uuid == servicesChangedUuid);
  }

  /// Workaround race condition between connect and disconnect.
  /// The bug: If you call disconnect right as android is establishing a connection
  /// android may still connect to the device. Worse, "onConnectionStateChange" will not be called
  /// so FBP will have no idea this connection is active. Adding a delay fixes this issue.
  /// https://issuetracker.google.com/issues/37121040
  Future<void> _ensureAndroidDisconnectionDelay(int androidDelay) async {
    if (!kIsWeb && Platform.isAndroid) {
      if (FlutterBluePlus._connectTimestamp.containsKey(remoteId)) {
        Duration minGap = Duration(milliseconds: androidDelay);
        Duration elapsed = DateTime.now().difference(FlutterBluePlus._connectTimestamp[remoteId]!);
        if (elapsed.compareTo(minGap) < 0) {
          Duration timeLeft = minGap - elapsed;
          FlutterBluePlusPlatform.log("[FBP] disconnect: enforcing ${minGap.inMilliseconds}ms disconnect gap, delaying "
              "${timeLeft.inMilliseconds}ms");
          await Future<void>.delayed(timeLeft);
        }
      }
    }
  }

  @override
  String toString() {
    return 'BluetoothDevice{'
        'remoteId: $remoteId, '
        'platformName: $platformName, '
        'services: ${FlutterBluePlus._knownServices[remoteId]}'
        '}';
  }
}

class _PendingConnection {
  final Future<bool> invocation;
  Future<void>? cleanup;
  bool cancelled = false;
  _PendingConnection(this.invocation);
}

class _BluetoothDeviceResponseStreams {
  final DeviceIdentifier remoteId;

  _BluetoothDeviceResponseStreams(this.remoteId);

  late final Stream<BmConnectionStateResponse> connectionState =
      FlutterBluePlusPlatform.instance.onConnectionStateChanged.where((response) => response.remoteId == remoteId);

  late final Stream<BmConnectionStateResponse> disconnected =
      connectionState.where((response) => response.connectionState == BmConnectionStateEnum.disconnected);

  late final Stream<BmDiscoverServicesResult> discoveredServices =
      FlutterBluePlusPlatform.instance.onDiscoveredServices.where((response) => response.remoteId == remoteId);

  late final Stream<BmReadRssiResult> readRssi =
      FlutterBluePlusPlatform.instance.onReadRssi.where((response) => response.remoteId == remoteId);

  late final Stream<int> mtu = FlutterBluePlusPlatform.instance.onMtuChanged
      .where((response) => response.remoteId == remoteId)
      .map((response) => response.mtu);

  late final Stream<BmBondStateResponse> bondStateChange = FlutterBluePlusPlatform.instance.onBondStateChanged.where(
    (response) => response.remoteId == remoteId && response.bondState != BmBondStateEnum.bonding,
  );
}
