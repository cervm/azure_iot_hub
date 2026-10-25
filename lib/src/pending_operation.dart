import 'dart:async';

import 'package:cancellation_token/cancellation_token.dart';

typedef Schedule = Timer Function(Duration delay, void Function() callback);

/// The reason an operation could not complete.
enum OperationFailureReason {
  /// Caller cancellation was requested.
  cancelled,

  /// The operation's finite deadline elapsed.
  timeout,

  /// The client was closed.
  closed,

  /// A pending-work or transport resource limit was reached.
  capacity,

  /// Credentials were rejected or could not be acquired or validated.
  authentication,

  /// TLS setup or certificate validation failed.
  tls,

  /// Protocol data, negotiation, a subscription or message completion was invalid.
  protocol,

  /// The service returned a terminal error response.
  service,
}

/// Whether a failed operation may have reached the service.
enum DeliveryState {
  /// The operation was never submitted to the transport.
  notSubmitted,

  /// Submission was attempted, so the service may have accepted the operation.
  unknown,
}

/// An operation failure, without transport or credential details.
///
/// A timeout or cancellation does not undo a submitted operation. Check [delivery]
/// before deciding whether an application-level retry could duplicate its effects.
final class OperationFailure(
  /// The category of failure.
  final OperationFailureReason reason,

  /// The delivery uncertainty retained across connection attempts.
  final DeliveryState delivery, {

  /// The service response status, when the failure came from a twin response.
  final int? statusCode,
}) implements Exception {
  @override
  String toString() =>
      'OperationFailure($reason, $delivery'
      '${statusCode == null ? '' : ', status: $statusCode'})';
}

/// A caller's completion and deadline, independent of connection recovery.
///
/// Completing the caller does not release an outstanding transport reservation.
/// The owner calls [release] after acknowledgement or connection retirement.
/// Until then, cancellation leaves the original deadline active for cleanup.
/// This class and its dependency types are not exported by the SDK.
final class PendingOperation<T> with Cancellable {
  PendingOperation({
    required this.onCancelled,
    required this.onTimeout,
    this.timeout = const .new(minutes: 4),
    this.schedule = Timer.new,
  }) {
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'Must be positive.');
    }
  }

  final void Function() onCancelled;
  final void Function() onTimeout;
  final Duration timeout;
  final Schedule schedule;
  final _completer = Completer<T>();
  CancellationToken? _shutdown;
  Timer? _timer;
  bool _started = false;
  bool _submitted = false;
  bool _released = false;

  Future<T> get future => _completer.future;
  bool get isCompleted => _completer.isCompleted;
  DeliveryState get delivery => _submitted ? .unknown : .notSubmitted;

  /// Starts the original deadline and links caller cancellation with shutdown.
  ///
  /// Returns `false` when cancellation has already occurred. Register the
  /// operation with its owner before calling this method: callbacks may run
  /// immediately. Neither token is cancelled by this operation.
  bool start({
    required CancellationToken shutdown,
    CancellationToken? cancellationToken,
  }) {
    if (_started || _released || isCompleted) {
      throw StateError('An operation can only be started once.');
    }
    _started = true;
    _shutdown = shutdown;
    if (shutdown.isCancelled || (cancellationToken?.isCancelled ?? false)) {
      fail(shutdown.isCancelled ? .closed : .cancelled);
      onCancelled();
      return false;
    }
    _timer = schedule(timeout, () {
      if (_released) return;
      fail(.timeout);
      onTimeout();
    });
    return maybeAttach(
      cancellationToken == null ? shutdown : cancellationToken.merge(shutdown),
    );
  }

  /// Records that submission may have reached the service, including on retries.
  void markSubmitted() {
    if (!_started || isCompleted || _released) {
      throw StateError('Cannot submit an inactive operation.');
    }
    _submitted = true;
  }

  void complete(T value) {
    if (isCompleted) return;
    detach();
    _shutdown = null;
    _completer.complete(value);
  }

  void fail(OperationFailureReason reason, {int? statusCode}) {
    if (isCompleted) return;
    detach();
    _shutdown = null;
    _completer.completeError(
      OperationFailure(reason, delivery, statusCode: statusCode),
    );
  }

  /// Releases deadline and listener resources after the caller has settled.
  void release() {
    assert(isCompleted);
    _released = true;
    _timer?.cancel();
    _timer = null;
    detach();
    _shutdown = null;
  }

  @override
  void onCancel(Exception cancelException) {
    super.onCancel(cancelException);
    if (isCompleted) return;
    fail(_shutdown?.isCancelled ?? false ? .closed : .cancelled);
    onCancelled();
  }
}
