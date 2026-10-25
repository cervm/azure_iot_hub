// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license; see third_party/azure-iot-sdk-csharp-LICENSE.
// Adapts InternalClient and MqttTransportHandler receive/completion behaviour.
// See doc/upstream.md for bounded storage and acknowledgement-order corrections.
part of 'internal_client.dart';

extension _CloudToDevice on InternalClient {
  bool get _receiveRegistrationPending => _pending.any(
    (operation) =>
        operation.kind == .receiveSubscription &&
        !operation.completion.isCompleted,
  );

  Future<CloudToDeviceMessage?> _receive({
    Duration? timeout,
    CancellationToken? token,
  }) async {
    final wait = timeout ?? operationTimeout;
    if (wait <= Duration.zero) throw ArgumentError('Timeout must be positive.');
    _checkReceiveState(token);
    if (_receiveHandler != null) return null;
    if (pendingCount >= maxPending) {
      throw OperationFailure(.capacity, .notSubmitted);
    }
    late final PendingOperation<CloudToDeviceMessage?> receiver;
    receiver = .new(
      timeout: wait,
      schedule: schedule,
      onCancelled: () => _releaseReceiver(receiver),
      onTimeout: () => _releaseReceiver(receiver),
    );
    _receivers.add(receiver);
    if (receiver.start(
      shutdown: _shutdown,
      cancellationToken: unwrapCancellationToken(token),
    )) {
      if (_recoveryStopped) {
        _recoveryStopped = false;
        _retryCount = 0;
      }
      if (_connected) {
        _flush();
      } else if (_retry == null) {
        _ensureConnection();
      }
    }
    try {
      return await receiver.future;
    } on OperationFailure catch (error) {
      if (error.reason == .timeout) return null;
      rethrow;
    }
  }

  void _checkReceiveState(CancellationToken? token) {
    if (_closed) throw OperationFailure(.closed, .notSubmitted);
    if (token?.isCancellationRequested ?? false) {
      throw OperationFailure(.cancelled, .notSubmitted);
    }
  }

  void _releaseReceiver(PendingOperation<CloudToDeviceMessage?> receiver) {
    receiver.release();
    _receivers.remove(receiver);
  }

  Future<void> _completeMessage(
    CloudToDeviceMessage message,
    CancellationToken? token,
  ) async {
    _checkReceiveState(token);
    final attempt = _attempt;
    final incoming = attempt?.incoming.values
        .where((entry) => identical(entry.message, message) && entry.delivered)
        .firstOrNull;
    if (attempt == null || incoming == null || incoming.ready) {
      throw OperationFailure(.protocol, .notSubmitted);
    }
    // Validate before mutating: the pinned C# queue loses its head on mismatch.
    final first = attempt.incoming.values
        .where((entry) => entry.message != null && !entry.ready)
        .firstOrNull;
    if (!identical(first, incoming)) {
      throw OperationFailure(.protocol, .notSubmitted);
    }
    late final PendingOperation<void> completion;
    void release() {
      incoming.ready = false;
      incoming.completion = null;
      completion.release();
    }

    completion = .new(
      timeout: operationTimeout,
      schedule: schedule,
      onCancelled: release,
      onTimeout: release,
    );
    incoming.completion = completion;
    if (completion.start(
      shutdown: _shutdown,
      cancellationToken: unwrapCancellationToken(token),
    )) {
      incoming.ready = true;
      _flushIncomingAcks(attempt);
    }
    await completion.future;
  }

  void _processReceiveRegistrations() {
    if (_closed) return;
    final active = _attempt?.receiveAction?.operation;
    if (active != null && !active.completion.isCompleted) return;
    for (final operation in _pending.toList()) {
      if (operation.kind != .receiveSubscription ||
          operation.completion.isCompleted) {
        continue;
      }
      final subscribe = operation.receiveHandler != null;
      final attempt = _attempt;
      if (!subscribe) {
        // C# clears the callback before awaiting unsubscription.
        _receiveHandler = null;
        attempt?.pollingRequested = false;
      }
      if ((subscribe && _receiveEnabled) ||
          (!subscribe &&
              !_receiveEnabled &&
              !(attempt?.receiveSubscribed ?? false) &&
              attempt?.receiveAction == null) ||
          (_connected &&
              attempt?.receiveAction == null &&
              attempt?.receiveSubscribed == subscribe)) {
        _receiveEnabled = subscribe;
        _receiveHandler = operation.receiveHandler;
        operation.completion.complete(null);
        _release(operation);
        continue;
      }
      if (_connected && attempt != null && attempt.receiveAction == null) {
        _startReceiveAction(
          attempt,
          subscribe: subscribe,
          operation: operation,
        );
      }
      return;
    }
    final attempt = _attempt;
    if (_connected && attempt != null) {
      _maintainReceiveSubscription(attempt);
      _dispatchReceivedMessages(attempt);
    }
  }

  void _maintainReceiveSubscription(_Attempt attempt) {
    if (attempt.receiveAction != null || _receiveRegistrationPending) {
      return;
    }
    if (_receivers.isNotEmpty) attempt.pollingRequested = true;
    final subscribe = _receiveEnabled || attempt.pollingRequested;
    if (attempt.receiveSubscribed != subscribe) {
      _startReceiveAction(attempt, subscribe: subscribe);
    }
  }

  void _startReceiveAction(
    _Attempt attempt, {
    required bool subscribe,
    _Operation? operation,
  }) {
    final action = _ReceiveAction(subscribe, operation);
    attempt.receiveAction = action;
    if (operation == null) {
      action.deadline = schedule(connectionTimeout, () => _lost(attempt));
    }
    try {
      operation?.completion.markSubmitted();
      if (subscribe) {
        if (attempt.transport.subscribe(_receiveTopic, .atLeastOnce) == null) {
          _lost(attempt);
        }
      } else {
        attempt.transport.unsubscribe(_receiveTopic, expectAcknowledge: true);
      }
    } catch (_) {
      _lost(attempt);
    }
  }

  void _completeReceiveAction(_Attempt attempt, {required bool subscribed}) {
    final action = attempt.receiveAction;
    if (action == null || action.subscribe != subscribed) return;
    action.deadline?.cancel();
    attempt.receiveAction = null;
    attempt.receiveSubscribed = subscribed;
    final operation = action.operation;
    if (operation != null) {
      if (!operation.completion.isCompleted) {
        _receiveEnabled = subscribed;
        _receiveHandler = operation.receiveHandler;
        operation.completion.complete(null);
      }
      _release(operation);
    }
    if (!_connected) {
      _restoreSubscriptions(attempt);
    } else {
      _flush();
    }
  }

  bool _retainIncoming(
    _Attempt attempt,
    String topic,
    MqttPublishMessage publish, {
    required bool isC2d,
  }) {
    if (!isC2d &&
        (publish.header?.qos != .atLeastOnce ||
            (!topic.startsWith(InternalClient._methodPrefix) &&
                !attempt.incoming.values.any(
                  (entry) => entry.publish.header?.qos == .atLeastOnce,
                )))) {
      // Twin/desired responses can be processed and ACKed immediately when no
      // earlier QoS 1 delivery blocks them. Only retained work needs a budget.
      return true;
    }
    final size = publish.payload.message.length + utf8.encode(topic).length;
    if (attempt.incoming.length >= maxPending ||
        attempt.incomingBytes + size > maxPendingBytes) {
      // Never acknowledge excess C2D data. The persistent session can redeliver
      // unacknowledged QoS 1 messages after recovery.
      _lost(attempt);
      return false;
    }
    final message = isC2d
        ? decodeCloudToDeviceMessage(
            publish.payload.message,
            topic.substring(_receivePrefix.length),
          )
        : null;
    attempt.incoming[publish] = _Incoming(publish, size, message);
    attempt.incomingBytes += size;
    return true;
  }

  void _dispatchReceivedMessages(_Attempt attempt) {
    if (attempt.dispatchingMessages ||
        !attempt.receiveSubscribed ||
        _receiveRegistrationPending) {
      return;
    }
    attempt.dispatchingMessages = true;
    try {
      for (final incoming in attempt.incoming.values.toList()) {
        if (!identical(_attempt, attempt) || _receiveRegistrationPending) break;
        final message = incoming.message;
        if (message == null || incoming.delivered) continue;
        final handler = _receiveHandler;
        final receiver = _receivers.firstOrNull;
        if (handler == null && receiver == null) break;
        incoming.delivered = true;
        if (incoming.publish.header?.qos != .atLeastOnce) {
          _removeIncoming(attempt, incoming);
        }
        if (handler != null) {
          handler(message);
        } else if (receiver != null) {
          receiver.complete(message);
          _releaseReceiver(receiver);
        }
      }
    } catch (_) {
      _lost(attempt);
    } finally {
      attempt.dispatchingMessages = false;
    }
  }

  void _ackIncoming(_Attempt attempt, MqttPublishMessage publish) {
    final incoming = attempt.incoming[publish];
    if (incoming == null) {
      if (publish.header?.qos == .atLeastOnce) {
        attempt.transport.acknowledgeIncomingQos1(publish);
      }
      return;
    }
    incoming.ready = true;
    _flushIncomingAcks(attempt);
  }

  void _flushIncomingAcks(_Attempt attempt) {
    try {
      for (final incoming in attempt.incoming.values.toList()) {
        if (!identical(_attempt, attempt)) return;
        if (incoming.publish.header?.qos != .atLeastOnce) continue;
        if (!incoming.ready) break;
        incoming.completion?.markSubmitted();
        attempt.transport.acknowledgeIncomingQos1(incoming.publish);
        incoming.completion?.complete(null);
        incoming.completion?.release();
        _removeIncoming(attempt, incoming);
      }
    } catch (_) {
      _lost(attempt);
    }
  }

  void _removeIncoming(_Attempt attempt, _Incoming incoming) {
    if (attempt.incoming.remove(incoming.publish) != null) {
      attempt.incomingBytes -= incoming.size;
    }
  }

  void _retireIncoming(_Attempt attempt) {
    for (final incoming in attempt.incoming.values) {
      incoming.completion?.fail(.protocol);
      incoming.completion?.release();
    }
    attempt.incoming.clear();
    attempt.incomingBytes = 0;
  }
}

final class _ReceiveAction(final bool subscribe, final _Operation? operation) {
  Timer? deadline;
}

final class _Incoming(
  final MqttPublishMessage publish,
  final int size,
  final CloudToDeviceMessage? message,
) {
  bool ready = false;
  bool delivered = false;
  PendingOperation<void>? completion;
}
