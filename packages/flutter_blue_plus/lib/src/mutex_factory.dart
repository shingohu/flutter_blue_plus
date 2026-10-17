part of '../flutter_blue_plus.dart';

// dart is single threaded, but still has task switching.
// this mutex lets a single task through at a time.
class _Mutex {
  final Queue<_MutexWaiter> _waiters = Queue();
  final void Function()? onIdle;
  bool _taken = false;

  _Mutex({this.onIdle});

  Future<bool> take({Duration? timeout, String function = "operation"}) {
    if (!_taken) {
      _taken = true;
      return Future.value(true);
    }
    final waiter = _MutexWaiter();
    _waiters.add(waiter);
    if (timeout != null) {
      waiter.timer = Timer(timeout, () {
        _waiters.remove(waiter);
        waiter.result.completeError(FlutterBluePlusException(
            ErrorPlatform.fbp, function, FbpErrorCode.timeout.index, "Timed out waiting for the operation queue"));
      });
    }
    return waiter.result.future;
  }

  bool give() {
    if (_waiters.isNotEmpty) {
      final next = _waiters.removeFirst();
      next.timer?.cancel();
      next.result.complete(true);
    } else {
      _taken = false;
      onIdle?.call();
    }
    return false;
  }
}

class _MutexWaiter {
  final result = Completer<bool>();
  Timer? timer;
}

// Create mutexes in a parallel-safe way,
class _MutexFactory {
  static final Map<String, _Mutex> _all = {};
  // Preserve the mode-change constraint without retaining every past device.
  static final Set<String> _usedCategories = {};

  static _Mutex getMutexForKey(String key) {
    _usedCategories.add(key.startsWith("device:")
        ? "device:"
        : key.startsWith("disconnect:")
            ? "disconnect:"
            : key);
    return _all.putIfAbsent(key, () {
      late final _Mutex mutex;
      mutex = _Mutex(onIdle: () {
        if (identical(_all[key], mutex)) _all.remove(key);
      });
      return mutex;
    });
  }

  static bool hasMutexWhere(bool Function(String key) test) {
    return _usedCategories.any(test);
  }
}
