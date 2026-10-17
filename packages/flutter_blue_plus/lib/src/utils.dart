part of '../flutter_blue_plus.dart';

// Own all resources for one operation, including the period spent awaiting the
// native method result. Future.timeout alone cannot cancel stream subscriptions.
class _OperationScope {
  static final Set<DeviceIdentifier> _needsReconnect = {};
  final BluetoothDevice? device;
  final String function;
  final _interrupted = Completer<Never>();
  final List<StreamSubscription> _subscriptions = [];
  Timer? _timer;
  Object? _failure;
  StackTrace? _failureStack;
  bool _invoked = false;

  _OperationScope(this.device, this.function, Duration timeout, {bool connected = true, bool adapter = true}) {
    _interrupted.future.ignore();
    try {
      _start(timeout, connected: connected, adapter: adapter);
    } catch (error, stack) {
      _fail(error, stack);
    }
  }

  void _start(Duration timeout, {required bool connected, required bool adapter}) {
    if (connected && device != null) {
      if (_needsReconnect.contains(device!.remoteId) ||
          BluetoothDevice._pendingConnections.containsKey(device!.remoteId)) {
        _fail(FlutterBluePlusException(ErrorPlatform.fbp, function, FbpErrorCode.timeout.index,
            "A previous operation timed out; disconnect and reconnect before issuing more operations"));
      } else if (device!.isDisconnected) {
        _fail(FlutterBluePlusException(
            ErrorPlatform.fbp, function, FbpErrorCode.deviceIsDisconnected.index, "Device is disconnected"));
      }
      _subscriptions.add(device!.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _fail(FlutterBluePlusException(
              ErrorPlatform.fbp, function, FbpErrorCode.deviceIsDisconnected.index, "Device is disconnected"));
        }
      }));
    }
    if (adapter) {
      if (FlutterBluePlus.adapterStateNow == BluetoothAdapterState.off ||
          FlutterBluePlus.adapterStateNow == BluetoothAdapterState.turningOff) {
        _fail(FlutterBluePlusException(
            ErrorPlatform.fbp, function, FbpErrorCode.adapterIsOff.index, "Bluetooth adapter is off"));
      }
      _subscriptions.add(FlutterBluePlusPlatform.instance.onAdapterStateChanged.listen((event) {
        if (event.adapterState == BmAdapterStateEnum.off || event.adapterState == BmAdapterStateEnum.turningOff) {
          _fail(FlutterBluePlusException(
              ErrorPlatform.fbp, function, FbpErrorCode.adapterIsOff.index, "Bluetooth adapter is off"));
        }
      }, onError: (Object e, StackTrace s) => _fail(e, s)));
    }
    _timer = Timer(timeout, () {
      // A timed-out GATT request can still be running in native code. Fence
      // subsequent requests until disconnect, rather than overlap that request
      // or let its late callback satisfy a new operation.
      if (_invoked && connected && device != null) _needsReconnect.add(device!.remoteId);
      _fail(FlutterBluePlusException(
          ErrorPlatform.fbp, function, FbpErrorCode.timeout.index, "Timed out after ${timeout.inMilliseconds}ms"));
    });
  }

  void _fail(Object error, [StackTrace? stack]) {
    if (_interrupted.isCompleted) return;
    _failure = error;
    _failureStack = stack ?? StackTrace.current;
    _interrupted.completeError(error, _failureStack);
  }

  Future<T> first<T>(Stream<T> stream) {
    final value = Completer<T>();
    value.future.ignore(); // invoke can fail before this result is awaited
    StreamSubscription<T>? subscription;
    subscription = stream.listen((event) {
      if (!value.isCompleted) value.complete(event);
      subscription?.cancel();
    }, onError: (Object e, StackTrace s) {
      if (!value.isCompleted) value.completeError(e, s);
      subscription?.cancel();
    }, onDone: () {
      if (!value.isCompleted) value.completeError(StateError("Response stream closed"));
    });
    _subscriptions.add(subscription);
    return value.future;
  }

  Future<T> wait<T>(Future<T> future) {
    // Always attach to the original Future, including when already interrupted,
    // so a late native rejection cannot become an unhandled asynchronous error.
    if (_failure != null) {
      future.ignore();
      return Future.error(_failure!, _failureStack);
    }
    return Future.any([future, _interrupted.future]);
  }

  Future<T> invoke<T>(Future<T> Function() call) {
    if (_failure != null) return Future.error(_failure!, _failureStack);
    _invoked = true;
    return wait(Future.sync(call));
  }

  Future<void> close() async {
    _timer?.cancel();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
  }
}

extension AddOrUpdate<T> on List<T> {
  /// add an item to a list, or update item if it already exists
  void addOrUpdate(T item) {
    final index = indexOf(item);
    if (index != -1) {
      this[index] = item;
    } else {
      add(item);
    }
  }
}

extension RemoveWhere<T> on List<T> {
  /// returns true if some items where removed
  bool _removeWhere(bool Function(T) test) {
    int initialLength = length;
    removeWhere(test);
    return length != initialLength;
  }
}

extension FirstWhereOrNullExtension<T> on Iterable<T> {
  /// returns first item to satisfy `test`, else null
  T? _firstWhereOrNull(bool Function(T) test) {
    for (var element in this) {
      if (test(element)) {
        return element;
      }
    }
    return null;
  }
}

extension FutureTimeout<T> on Future<T> {
  Future<T> fbpTimeout(Duration duration, String function) {
    return timeout(duration, onTimeout: () {
      throw FlutterBluePlusException(
          ErrorPlatform.fbp, function, FbpErrorCode.timeout.index, "Timed out after ${duration.inMilliseconds}ms");
    });
  }
}

// This is a reimplementation of BehaviorSubject from RxDart library.
// It is essentially a stream but:
//  1. we cache the latestValue of the stream
//  2. the "latestValue" is re-emitted whenever the stream is listened to
class _StreamControllerReEmit<T> {
  T latestValue;

  final StreamController<T> _controller = StreamController<T>.broadcast();

  _StreamControllerReEmit({required T initialValue}) : latestValue = initialValue;

  Stream<T> get stream {
    if (latestValue != null) {
      return _controller.stream.newStreamWithInitialValue(latestValue!);
    } else {
      return _controller.stream;
    }
  }

  T get value => latestValue;

  void add(T newValue) {
    latestValue = newValue;
    _controller.add(newValue);
  }

  void addError(Object error) {
    _controller.addError(error);
  }

  void listen(Function(T) onData, {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    onData(latestValue);
    _controller.stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  Future<void> close() {
    return _controller.close();
  }
}

// immediately starts listening to a broadcast stream and
// buffering it in a new single-subscription stream
class _BufferStream<T> {
  final Stream<T> _inputStream;
  late final StreamSubscription? _subscription;
  late final StreamController<T> _controller;
  late bool hasReceivedValue = false;

  _BufferStream.listen(this._inputStream) {
    _controller = StreamController<T>(
      onCancel: () {
        _subscription?.cancel();
      },
      onPause: () {
        _subscription?.pause();
      },
      onResume: () {
        _subscription?.resume();
      },
      onListen: () {}, // inputStream is already listened to
    );

    // immediately start listening to the inputStream
    _subscription = _inputStream.listen(
      (data) {
        hasReceivedValue = true;
        _controller.add(data);
      },
      onError: (e) {
        _controller.addError(e);
      },
      onDone: () {
        _controller.close();
      },
      cancelOnError: false,
    );
  }

  void close() {
    _subscription?.cancel();
    _controller.close();
  }

  Stream<T> get stream async* {
    yield* _controller.stream;
  }
}

// Helper for 'newStreamWithInitialValue' method for streams.
class _NewStreamWithInitialValueTransformer<T> extends StreamTransformerBase<T, T> {
  /// the initial value to push to the new stream
  final T initialValue;

  /// controller for the new stream
  late StreamController<T> controller;

  /// subscription to the original stream
  late StreamSubscription<T> subscription;

  /// new stream listener count
  var listenerCount = 0;

  _NewStreamWithInitialValueTransformer(this.initialValue);

  @override
  Stream<T> bind(Stream<T> stream) {
    if (stream.isBroadcast) {
      return _bind(stream, broadcast: true);
    } else {
      return _bind(stream);
    }
  }

  Stream<T> _bind(Stream<T> stream, {bool broadcast = false}) {
    /////////////////////////////////////////
    /// Original Stream Subscription Callbacks
    ///

    /// When the original stream emits data, forward it to our new stream
    void onData(T data) {
      controller.add(data);
    }

    /// When the original stream is done, close our new stream
    void onDone() {
      controller.close();
    }

    /// When the original stream has an error, forward it to our new stream
    void onError(Object error) {
      controller.addError(error);
    }

    /// When a client listens to our new stream, emit the
    /// initial value and subscribe to original stream if needed
    void onListen() {
      // Emit the initial value to our new stream
      controller.add(initialValue);

      // listen to the original stream, if needed
      if (listenerCount == 0) {
        subscription = stream.listen(
          onData,
          onError: onError,
          onDone: onDone,
        );
      }

      // count listeners of the new stream
      listenerCount++;
    }

    //////////////////////////////////////
    ///  New Stream Controller Callbacks
    ///

    /// (Single Subscription Only) When a client pauses
    /// the new stream, pause the original stream
    void onPause() {
      subscription.pause();
    }

    /// (Single Subscription Only) When a client resumes
    /// the new stream, resume the original stream
    void onResume() {
      subscription.resume();
    }

    /// Called when a client cancels their
    /// subscription to the new stream,
    void onCancel() {
      // count listeners of the new stream
      listenerCount--;

      // when there are no more listeners of the new stream,
      // cancel the subscription to the original stream,
      // and close the new stream controller
      if (listenerCount == 0) {
        subscription.cancel();
        controller.close();
      }
    }

    //////////////////////////////////////
    /// Return New Stream
    ///

    // create a new stream controller
    if (broadcast) {
      controller = StreamController<T>.broadcast(
        onListen: onListen,
        onCancel: onCancel,
      );
    } else {
      controller = StreamController<T>(
        onListen: onListen,
        onPause: onPause,
        onResume: onResume,
        onCancel: onCancel,
      );
    }

    return controller.stream;
  }
}

extension _StreamNewStreamWithInitialValue<T> on Stream<T> {
  Stream<T> newStreamWithInitialValue(T initialValue) {
    return transform(_NewStreamWithInitialValueTransformer(initialValue));
  }
}

// ignore: unused_element
Stream<T> _mergeStreams<T>(List<Stream<T>> streams) {
  StreamController<T> controller = StreamController<T>();
  List<StreamSubscription<T>> subscriptions = [];

  void handleData(T data) {
    if (!controller.isClosed) {
      controller.add(data);
    }
  }

  void handleError(Object error, StackTrace stackTrace) {
    if (!controller.isClosed) {
      controller.addError(error, stackTrace);
    }
  }

  void handleDone() {
    for (var s in subscriptions) {
      s.cancel();
    }
    controller.close();
  }

  void subscribeToStream(Stream<T> stream) {
    final s = stream.listen(handleData, onError: handleError, onDone: handleDone);
    subscriptions.add(s);
  }

  streams.forEach(subscribeToStream);

  controller.onCancel = () async {
    await Future.wait(subscriptions.map((s) => s.cancel()));
  };

  return controller.stream;
}
