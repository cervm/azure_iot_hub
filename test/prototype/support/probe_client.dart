// Experimental test harness. This is not the SDK's public API.
import 'dart:async';
import 'dart:convert';

import 'package:azure_iot_hub/src/pending_operation.dart';
import 'package:cancellation_token/cancellation_token.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

// Owns connection recovery separately from the callers waiting for it.
final class ProbeClient {
  ProbeClient(
    this.createClient, {
    this.schedule = Timer.new,
    this.operationTimeout = const Duration(minutes: 4),
    this.connectionTimeout = const Duration(seconds: 5),
    this.retryDelay = const Duration(seconds: 1),
    this.maxPending = 4,
    this.maxPayloadBytes = 1024,
  }) {
    if (operationTimeout <= Duration.zero ||
        connectionTimeout <= Duration.zero ||
        retryDelay <= Duration.zero ||
        maxPending < 1 ||
        maxPayloadBytes < 1) {
      throw ArgumentError('Timeouts and resource limits must be positive.');
    }
  }

  final MqttServerClient Function() createClient;
  final Schedule schedule;
  final Duration operationTimeout;
  final Duration connectionTimeout;
  final Duration retryDelay;
  final int maxPending;
  final int maxPayloadBytes;
  final _shutdown = CancellationToken();
  final _pending = <_Operation>{};
  final _packets = <int, _Operation>{};
  _Attempt? _attempt;
  Future<void>? _connecting;
  Future<void>? _closing;
  Timer? _retry;
  bool _closed = false;
  bool _connected = false;

  int get pendingCount => _pending.length;
  int get retainedPackets =>
      // White-box measurement for this version-pinned dependency experiment.
      // ignore: invalid_use_of_protected_member
      _attempt?.client.publishingManager?.publishedMessages.length ?? 0;
  bool get isConnected => _connected;
  bool get hasCancellationListeners => _shutdown.hasCancellables;
  Object? lastConnectionError;

  Future<void> open({CancellationToken? cancellationToken}) =>
      _submit(null, cancellationToken);

  Future<void> send(String payload, {CancellationToken? cancellationToken}) {
    if (utf8.encode(payload).length > maxPayloadBytes) {
      return Future.error(ArgumentError('Prototype payload limit exceeded.'));
    }
    return _submit(payload, cancellationToken);
  }

  Future<void> _submit(String? payload, CancellationToken? token) {
    if (_closed) {
      return Future.error(
        OperationFailure(
          OperationFailureReason.closed,
          DeliveryState.notSubmitted,
        ),
      );
    }
    if (token?.isCancelled ?? false) {
      return Future.error(
        OperationFailure(
          OperationFailureReason.cancelled,
          DeliveryState.notSubmitted,
        ),
      );
    }
    if (_pending.length >= maxPending) {
      return Future.error(
        OperationFailure(
          OperationFailureReason.capacity,
          DeliveryState.notSubmitted,
        ),
      );
    }
    late final _Operation operation;
    operation = _Operation(
      payload,
      PendingOperation<void>(
        onCancelled: () => _cancel(operation),
        onTimeout: () => _expire(operation),
        timeout: operationTimeout,
        schedule: schedule,
      ),
    );
    _pending.add(operation);
    if (!operation.completion.start(
      shutdown: _shutdown,
      cancellationToken: token,
    )) {
      return operation.future;
    }
    if (_connected) {
      _flush();
    } else if (_retry == null) {
      _ensureConnection();
    }
    return operation.future;
  }

  void _cancel(_Operation operation) {
    // A cancelled caller does not remove the packet retained by mqtt_client.
    // Keep its slot and original deadline until PUBACK or connection retirement.
    if (operation.packetId == null) _release(operation);
  }

  void _expire(_Operation operation) {
    final hadPacket = operation.packetId != null;
    _release(operation);
    if (hadPacket) {
      final attempt = _attempt;
      if (attempt != null) _lost(attempt);
    }
  }

  void _release(_Operation operation) {
    operation.completion.release();
    _pending.remove(operation);
    _packets.remove(operation.packetId);
  }

  void _ensureConnection() {
    if (_closed || _connected || _connecting != null) return;
    _connecting = _connect();
  }

  Future<void> _connect() async {
    _Attempt? attempt;
    try {
      final client = createClient()
        ..autoReconnect = false
        ..connectionTimeout = connectionTimeout.inMilliseconds
        ..connectTimeoutPeriod = 1000;
      if (client.maxConnectionAttempts != 1) {
        throw ArgumentError(
          'The prototype owns retries; use one MQTT attempt.',
        );
      }
      attempt = _Attempt(client);
      final current = attempt;
      _attempt = current;
      client.onDisconnected = () => _lost(current);
      current.deadline = schedule(connectionTimeout, () => _lost(current));
      final connecting = client.connect();
      final status = await connecting;
      if (_closed || !identical(_attempt, current)) return;
      if (status?.state != MqttConnectionState.connected) {
        throw StateError('MQTT handshake failed.');
      }
      current.deadline?.cancel();
      current.subscription = client.published!.listen((message) {
        if (!identical(_attempt, current)) return;
        final operation = _packets[message.variableHeader!.messageIdentifier];
        if (operation == null) return;
        operation.completion.complete(null);
        _release(operation);
      });
      _connected = true;
      _flush();
    } catch (error) {
      lastConnectionError = error;
      if (attempt != null && identical(_attempt, attempt)) _lost(attempt);
    } finally {
      if (attempt != null) {
        attempt.connecting = false;
        if (attempt.retired) attempt.retire();
      }
      _connecting = null;
      _scheduleRetry();
    }
  }

  void _flush() {
    final client = _attempt!.client;
    for (final operation in _pending.toList()) {
      if (!_connected) break;
      if (operation.done || operation.packetId != null) continue;
      final payload = operation.payload;
      if (payload == null) {
        operation.completion.complete(null);
        _release(operation);
        continue;
      }
      final builder = MqttClientPayloadBuilder()..addUTF8String(payload);
      operation.completion.markSubmitted();
      final id = client.publishMessage(
        'probe/telemetry',
        MqttQos.atLeastOnce,
        builder.payload!,
      );
      operation.packetId = id;
      _packets[id] = operation;
    }
  }

  void _lost(_Attempt attempt) {
    if (!identical(_attempt, attempt)) return;
    _attempt = null;
    _connected = false;
    attempt.retire();
    _packets.clear();
    for (final operation in _pending.toList()) {
      operation.packetId = null;
      if (operation.done) _release(operation);
    }
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (_closed || _connected || _connecting != null || _retry != null) return;
    _retry = schedule(retryDelay, () {
      _retry = null;
      _ensureConnection();
    });
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    _retry?.cancel();
    _retry = null;
    _shutdown.cancel();
    final attempt = _attempt;
    if (attempt != null) _lost(attempt);
    for (final operation in _pending.toList()) {
      _release(operation);
    }
    await _connecting;
    await attempt?.subscription?.cancel();
  }
}

final class _Attempt(final MqttServerClient client) {
  StreamSubscription<MqttPublishMessage>? subscription;
  Timer? deadline;
  bool connecting = true;
  bool retired = false;

  void retire() {
    retired = true;
    deadline?.cancel();
    unawaited(subscription?.cancel());
    // Preserve the handler until its bounded attempt settles, so a late socket
    // remains reachable through public disconnect(). Recovery waits for this too.
    if (!connecting) client.disconnect();
  }
}

final class _Operation(
  final String? payload,
  final PendingOperation<void> completion,
) {
  int? packetId;
  Future<void> get future => completion.future;
  bool get done => completion.isCompleted;
}
