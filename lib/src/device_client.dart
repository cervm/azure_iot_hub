import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:typed_data/typed_buffers.dart';

import 'authentication/iot_hub_connection_string.dart';
import 'authentication/sas_token_cache.dart';
import 'pending_operation.dart';
import 'telemetry_message.dart';
import 'transport/mqtt_transport.dart';

/// An internal TLS telemetry client; not yet the package's public device API.
final class DeviceClient {
  DeviceClient(
    this.credentials, {
    this.operationTimeout = const Duration(minutes: 4),
    this.connectionTimeout = const Duration(seconds: 60),
    this.maxPending = 16,
    this.maxPendingBytes = 4 * 1024 * 1024,
    this.port = 8883,
    this.securityContext,
    this.schedule = Timer.new,
    this.now = DateTime.now,
    int Function(int)? randomInt,
  }) : _randomInt = randomInt ?? Random().nextInt,
       _sasTokens = SasTokenCache(credentials, now: now) {
    if (operationTimeout <= Duration.zero ||
        connectionTimeout <= Duration.zero ||
        maxPending < 1 ||
        maxPending > 32767 ||
        maxPendingBytes < 1 ||
        port < 1 ||
        port > 65535) {
      throw ArgumentError('Invalid timeout, capacity or port.');
    }
  }

  final IotHubConnectionString credentials;
  final Duration operationTimeout;
  final Duration connectionTimeout;
  final int maxPending;
  final int maxPendingBytes;
  final int port;
  final SecurityContext? securityContext;
  final Schedule schedule;
  final DateTime Function() now;
  final int Function(int) _randomInt;
  final SasTokenCache _sasTokens;
  final _shutdown = CancellationToken();
  final _pending = <_Operation>{};
  final _packets = <int, _Operation>{};
  _Attempt? _attempt;
  Future<void>? _connecting;
  Timer? _retry;
  int _retryCount = 0;
  int _pendingBytes = 0;
  bool _connected = false;
  bool _closed = false;
  bool _recoveryStopped = false;

  int get pendingCount => _pending.length;
  int get pendingBytes => _pendingBytes;
  bool get isConnected => _connected;

  Future<void> open({CancellationToken? cancellationToken}) =>
      _submit(null, cancellationToken);

  Future<void> sendEvent(
    TelemetryMessage message, {
    CancellationToken? cancellationToken,
  }) => _submit(message, cancellationToken);

  Future<void> _submit(TelemetryMessage? message, CancellationToken? token) {
    final reason = _closed
        ? OperationFailureReason.closed
        : (token?.isCancelled ?? false)
        ? OperationFailureReason.cancelled
        : null;
    if (reason != null) {
      return Future.error(OperationFailure(reason, DeliveryState.notSubmitted));
    }
    final topic = message?.topic(credentials.deviceId);
    if (topic != null) PublicationTopic(topic);
    final size = message == null
        ? 0
        : message.payload.length + utf8.encode(topic!).length + 8;
    if (_pending.length >= maxPending ||
        _pendingBytes + size > maxPendingBytes) {
      return Future.error(
        OperationFailure(
          OperationFailureReason.capacity,
          DeliveryState.notSubmitted,
        ),
      );
    }
    if (_recoveryStopped) {
      _recoveryStopped = false;
      _retryCount = 0;
    }
    late final _Operation operation;
    operation = _Operation(
      message,
      topic,
      size,
      PendingOperation<void>(
        timeout: operationTimeout,
        schedule: schedule,
        onCancelled: () {
          if (operation.packetId == null) _release(operation);
        },
        onTimeout: () {
          final submitted = operation.packetId != null;
          _release(operation);
          if (submitted && _attempt != null) _lost(_attempt!);
        },
      ),
    );
    _pending.add(operation);
    _pendingBytes += size;
    if (!operation.completion.start(
      shutdown: _shutdown,
      cancellationToken: token,
    )) {
      return operation.completion.future;
    }
    if (_connected) {
      _flush();
    } else if (_retry == null) {
      _ensureConnection();
    }
    return operation.completion.future;
  }

  void _release(_Operation operation) {
    operation.completion.release();
    if (_pending.remove(operation)) _pendingBytes -= operation.size;
    _packets.remove(operation.packetId);
  }

  void _ensureConnection() {
    if (_closed || _connected || _connecting != null || _recoveryStopped) {
      return;
    }
    // Assign the guard before any factory/credential code can fail synchronously.
    _connecting = Future<void>.microtask(_connect).whenComplete(() {
      _connecting = null;
      _scheduleRetry();
    });
  }

  Future<void> _connect() async {
    _Attempt? current;
    try {
      if (_closed) return;
      final token = _sasTokens.getToken();
      final transport = MqttTransport(
        credentials.connectionHostName,
        credentials.deviceId,
        port: port,
        maxBufferedBytes: maxPendingBytes + 65536,
        securityContext: securityContext,
        schedule: schedule,
        now: now,
      );
      final attempt = _Attempt(transport);
      current = attempt;
      _attempt = attempt;
      transport.onDisconnected = () => _lost(attempt);
      attempt.deadline = schedule(connectionTimeout, () => _lost(attempt));
      final status = await transport.connect(
        '${credentials.hostName}/${credentials.deviceId}/?'
        'api-version=2020-09-30&DeviceClientType='
        '${escapeDataString('azure-iot-hub-dart/0.1.0-dev.1')}',
        token.value,
      );
      if (_closed || !identical(_attempt, attempt)) return;
      if (status?.state != MqttConnectionState.connected) {
        throw TransportFailure(TransportFailureKind.network);
      }
      attempt.deadline?.cancel();
      attempt.subscription = transport.published!.listen((message) {
        if (!identical(_attempt, attempt)) return;
        final operation = _packets[message.variableHeader!.messageIdentifier];
        if (operation == null) return;
        operation.completion.complete(null);
        _release(operation);
      });
      _connected = true;
      _retryCount = 0;
      _flush();
    } catch (error) {
      if (current != null && identical(_attempt, current)) {
        _lost(current);
      } else if (current == null && !_closed) {
        _stopRecovery(OperationFailureReason.authentication);
      }
    } finally {
      // Serialize native setup too: uncancellable DNS resolution cannot build
      // an unbounded collection of abandoned connection attempts. Callers and
      // close() settle independently; late sockets are closed by the adapter.
      await current?.transport.settled;
    }
  }

  void _flush() {
    final attempt = _attempt!;
    for (final operation in _pending.toList()) {
      if (!_connected || !identical(_attempt, attempt)) break;
      if (operation.completion.isCompleted || operation.packetId != null) {
        continue;
      }
      final message = operation.message;
      if (message == null) {
        operation.completion.complete(null);
        _release(operation);
        continue;
      }
      try {
        final bytes = Uint8Buffer()..addAll(message.payload);
        operation.completion.markSubmitted();
        final id = attempt.transport.publishMessage(
          operation.topic!,
          MqttQos.atLeastOnce,
          bytes,
        );
        operation.packetId = id;
        _packets[id] = operation;
      } catch (_) {
        _lost(attempt);
      }
    }
  }

  void _lost(_Attempt attempt) {
    if (!identical(_attempt, attempt)) return;
    _attempt = null;
    _connected = false;
    attempt.deadline?.cancel();
    unawaited(attempt.subscription?.cancel());
    attempt.transport.retire();
    _packets.clear();
    for (final operation in _pending.toList()) {
      operation.packetId = null;
      if (operation.completion.isCompleted) _release(operation);
    }
    final failure = attempt.transport.failure;
    if (failure != null && !failure.isTransient) {
      _stopRecovery(switch (failure.kind) {
        TransportFailureKind.authentication =>
          OperationFailureReason.authentication,
        TransportFailureKind.tls => OperationFailureReason.tls,
        _ => OperationFailureReason.protocol,
      });
    }
    _scheduleRetry();
  }

  void _stopRecovery(OperationFailureReason reason) {
    _recoveryStopped = true;
    _retry?.cancel();
    _retry = null;
    for (final operation in _pending.toList()) {
      operation.completion.fail(reason);
      _release(operation);
    }
  }

  void _scheduleRetry() {
    if (_closed ||
        _connected ||
        _connecting != null ||
        _retry != null ||
        _recoveryStopped) {
      return;
    }
    // C# default: 100ms minimum, 100ms delta with 80–120% jitter, 10s cap.
    // Clamp the exponent before evaluation, even after a very long outage.
    final factor = (1 << min(_retryCount++, 8)) - 1;
    final delay = min(10000, 100 + factor * (80 + _randomInt(40)));
    _retry = schedule(Duration(milliseconds: delay), () {
      _retry = null;
      _ensureConnection();
    });
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _retry?.cancel();
    _retry = null;
    _shutdown.cancel();
    if (_attempt != null) _lost(_attempt!);
    for (final operation in _pending.toList()) {
      _release(operation);
    }
  }
}

final class _Attempt(final MqttTransport transport) {
  Timer? deadline;
  StreamSubscription<MqttPublishMessage>? subscription;
}

final class _Operation(
  final TelemetryMessage? message,
  final String? topic,
  final int size,
  final PendingOperation<void> completion,
) {
  int? packetId;
}
