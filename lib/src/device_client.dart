// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license; see third_party/azure-iot-sdk-csharp-LICENSE.
// Twin request handling adapts MqttTransportHandler and the retry pipeline.
// See docs/upstream.md for the pinned source/test mapping and agreed deviations.
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
import 'twin.dart';

/// An internal TLS device client; not yet the package's public device API.
final class DeviceClient {
  DeviceClient(
    this.credentials, {
    this.operationTimeout = const Duration(minutes: 4),
    this.connectionTimeout = const Duration(seconds: 60),
    this.twinResponseTimeout = const Duration(seconds: 60),
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
        twinResponseTimeout <= Duration.zero ||
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
  final Duration twinResponseTimeout;
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
  final _twinRequests = <String, _Operation>{};
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
      _submit(_OperationKind.open, null, cancellationToken);

  Future<void> sendEvent(
    TelemetryMessage message, {
    CancellationToken? cancellationToken,
  }) => _submit(_OperationKind.telemetry, message, cancellationToken);

  /// Retrieves twin properties after PUBACK and a matching service response.
  Future<TwinProperties> getTwin({
    CancellationToken? cancellationToken,
  }) async => (await _submit(_OperationKind.twinGet, null, cancellationToken))!;

  /// Updates reported properties after PUBACK and a matching service response.
  ///
  /// Captures [properties] as a JSON patch when called. Null values delete
  /// properties; omitted properties are unchanged. Retries use the same patch
  /// within the original operation deadline.
  Future<void> updateReportedProperties(
    Map<String, Object?> properties, {
    CancellationToken? cancellationToken,
  }) async {
    await _submit(
      _OperationKind.twinPatch,
      null,
      cancellationToken,
      reportedProperties: properties,
    );
  }

  Future<TwinProperties?> _submit(
    _OperationKind kind,
    TelemetryMessage? message,
    CancellationToken? token, {
    Map<String, Object?>? reportedProperties,
  }) {
    final reason = _closed
        ? OperationFailureReason.closed
        : (token?.isCancelled ?? false)
        ? OperationFailureReason.cancelled
        : null;
    if (reason != null) {
      return Future.error(OperationFailure(reason, DeliveryState.notSubmitted));
    }
    final topic = switch (kind) {
      _OperationKind.twinGet => r'$iothub/twin/GET/?$rid=',
      _OperationKind.twinPatch =>
        r'$iothub/twin/PATCH/properties/reported/?$rid=',
      _OperationKind.telemetry => message!.topic(credentials.deviceId),
      _OperationKind.open => null,
    };
    if (topic != null) PublicationTopic(topic);
    final payload = kind == _OperationKind.twinPatch
        ? encodeReportedProperties(reportedProperties!)
        : message?.payload ?? const <int>[];
    final size = topic == null
        ? 0
        : payload.length +
              utf8.encode(topic).length +
              (kind.isTwin ? 36 : 0) +
              8;
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
      kind,
      payload,
      topic,
      size,
      PendingOperation<TwinProperties?>(
        timeout: operationTimeout,
        schedule: schedule,
        onCancelled: () {
          _clearTwinRequest(operation);
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
    _clearTwinRequest(operation);
    operation.completion.release();
    if (_pending.remove(operation)) _pendingBytes -= operation.size;
    _packets.remove(operation.packetId);
  }

  void _ensureConnection() {
    if (_closed ||
        _attempt != null ||
        _connecting != null ||
        _recoveryStopped) {
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
      attempt.subscription = transport.published!.listen((message) {
        if (!identical(_attempt, attempt)) return;
        final operation = _packets.remove(
          message.variableHeader!.messageIdentifier,
        );
        if (operation == null) return;
        operation.packetId = null;
        if (operation.kind.isTwin && !operation.completion.isCompleted) {
          if (operation.response != null) {
            _finishTwinResponse(operation);
          } else {
            operation.responseTimer = schedule(
              twinResponseTimeout,
              () => _retryTwin(operation),
            );
          }
        } else {
          operation.completion.complete(null);
          _release(operation);
        }
      });
      attempt.updates = transport.updates!.listen((messages) {
        if (!identical(_attempt, attempt)) return;
        for (final message in messages) {
          final publish = message.payload as MqttPublishMessage;
          _receiveTwin(message.topic, publish.payload.message);
        }
      });
      transport.onSubscribed = (_) {
        if (_closed || !identical(_attempt, attempt)) return;
        attempt.deadline?.cancel();
        _connected = true;
        _retryCount = 0;
        _flush();
      };
      transport.onSubscribeFail = (_) {
        if (_closed || !identical(_attempt, attempt)) return;
        _stopRecovery(OperationFailureReason.protocol);
        _lost(attempt);
      };
      if (transport.subscribe(r'$iothub/twin/res/#', MqttQos.atLeastOnce) ==
          null) {
        _lost(attempt);
      }
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
      if (operation.kind == _OperationKind.open) {
        operation.completion.complete(null);
        _release(operation);
        continue;
      }
      if (operation.requestId != null || operation.retry != null) continue;
      try {
        final bytes = Uint8Buffer()..addAll(operation.payload);
        var topic = operation.topic;
        if (operation.kind.isTwin) {
          final requestId = newTwinRequestId();
          operation.requestId = requestId;
          _twinRequests[requestId] = operation;
          topic = '$topic$requestId';
        }
        operation.completion.markSubmitted();
        final id = attempt.transport.publishMessage(
          topic!,
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

  void _receiveTwin(String topic, List<int> payload) {
    final response = TwinResponse.parse(topic, payload);
    if (response == null) return;
    final operation = _twinRequests[response.requestId];
    if (operation == null ||
        operation.completion.isCompleted ||
        operation.response != null) {
      return;
    }
    if (_pendingBytes + payload.length > maxPendingBytes) {
      operation.completion.fail(OperationFailureReason.capacity);
      _clearTwinRequest(operation);
      if (operation.packetId == null) _release(operation);
      return;
    }
    operation.response = response;
    _pendingBytes += payload.length;
    if (operation.packetId == null) _finishTwinResponse(operation);
  }

  void _finishTwinResponse(_Operation operation) {
    final response = operation.response!;
    if (response.status == 429) {
      _retryTwin(operation);
      return;
    }
    if (response.status >= 300) {
      operation.completion.fail(
        OperationFailureReason.service,
        statusCode: response.status,
      );
    } else if (operation.kind == _OperationKind.twinPatch) {
      // C# ignores successful PATCH response bodies, including empty 204s.
      operation.completion.complete(null);
    } else {
      try {
        operation.completion.complete(
          TwinProperties.fromBytes(response.payload),
        );
      } on FormatException {
        operation.completion.fail(OperationFailureReason.protocol);
      }
    }
    _release(operation);
  }

  void _clearTwinRequest(_Operation operation) {
    _twinRequests.remove(operation.requestId);
    operation.requestId = null;
    operation.responseTimer?.cancel();
    operation.responseTimer = null;
    operation.retry?.cancel();
    operation.retry = null;
    _pendingBytes -= operation.response?.payload.length ?? 0;
    operation.response = null;
  }

  void _retryTwin(_Operation operation) {
    _clearTwinRequest(operation);
    if (operation.completion.isCompleted) {
      _release(operation);
      return;
    }
    operation.retry = schedule(_retryDelay(operation.retryCount++), () {
      operation.retry = null;
      if (_connected) _flush();
    });
  }

  void _lost(_Attempt attempt) {
    if (!identical(_attempt, attempt)) return;
    _attempt = null;
    _connected = false;
    attempt.deadline?.cancel();
    unawaited(attempt.subscription?.cancel());
    unawaited(attempt.updates?.cancel());
    attempt.transport.retire();
    _packets.clear();
    for (final operation in _pending.toList()) {
      _clearTwinRequest(operation);
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
        _attempt != null ||
        _connecting != null ||
        _retry != null ||
        _recoveryStopped) {
      return;
    }
    _retry = schedule(_retryDelay(_retryCount++), () {
      _retry = null;
      _ensureConnection();
    });
  }

  Duration _retryDelay(int count) {
    // C# default: 100ms minimum, 100ms delta with 80–120% jitter, 10s cap.
    final factor = (1 << min(count, 8)) - 1;
    return Duration(
      milliseconds: min(10000, 100 + factor * (80 + _randomInt(40))),
    );
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
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? updates;
}

enum _OperationKind {
  open,
  telemetry,
  twinGet,
  twinPatch;

  bool get isTwin => this == twinGet || this == twinPatch;
}

final class _Operation(
  final _OperationKind kind,
  final List<int> payload,
  final String? topic,
  final int size,
  final PendingOperation<TwinProperties?> completion,
) {
  int? packetId;
  String? requestId;
  TwinResponse? response;
  Timer? responseTimer;
  Timer? retry;
  int retryCount = 0;
}
