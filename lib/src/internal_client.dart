// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license; see third_party/azure-iot-sdk-csharp-LICENSE.
// Twin and direct-method handling adapts InternalClient, MqttTransportHandler
// and the retry pipeline.
// See docs/upstream.md for the pinned source/test mapping and agreed deviations.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cancellation_token/cancellation_token.dart' as cancellation;
import 'package:mqtt_client/mqtt_client.dart';
import 'package:typed_data/typed_buffers.dart';

import 'authentication/iot_hub_connection_string.dart';
import 'authentication/sas_token_cache.dart';
import 'cancellation.dart';
import 'connection_status.dart';
import 'direct_method.dart';
import 'pending_operation.dart';
import 'telemetry_message.dart';
import 'transport/connection_diagnostics.dart';
import 'transport/mqtt_transport.dart';
import 'transport/mqtt_transport_type.dart';
import 'twin.dart';

/// The MQTT implementation behind the public device client.
final class InternalClient {
  InternalClient(
    this.credentials, {
    this.operationTimeout = const .new(minutes: 4),
    this.connectionTimeout = const .new(seconds: 60),
    this.twinResponseTimeout = const .new(seconds: 60),
    this.maxPending = 16,
    this.maxPendingBytes = 4 * 1024 * 1024,
    this.transport = .tcp,
    int? port,
    this.securityContext,
    this.schedule = Timer.new,
    this.now = DateTime.now,
    int Function(int)? randomInt,
  }) : port = port ?? transport.defaultPort,
       _randomInt = randomInt ?? Random().nextInt,
       _sasTokens = .new(credentials, now: now) {
    if (operationTimeout <= Duration.zero ||
        connectionTimeout <= Duration.zero ||
        twinResponseTimeout <= Duration.zero ||
        maxPending < 1 ||
        maxPending > 32767 ||
        maxPendingBytes < 1 ||
        this.port < 1 ||
        this.port > 65535) {
      throw ArgumentError('Invalid timeout, capacity or port.');
    }
  }

  final IotHubConnectionString credentials;
  final connectionDiagnostics = ConnectionDiagnostics();
  final Duration operationTimeout;
  final Duration connectionTimeout;
  final Duration twinResponseTimeout;
  final int maxPending;
  final int maxPendingBytes;
  final MqttTransportType transport;
  final int port;
  final SecurityContext? securityContext;
  final Schedule schedule;
  final DateTime Function() now;
  final int Function(int) _randomInt;
  final SasTokenCache _sasTokens;
  final _shutdown = cancellation.CancellationToken();
  final _pending = <_Operation>{};
  final _packets = <int, _Operation>{};
  final _twinRequests = <String, _Operation>{};
  _Attempt? _attempt;
  Future<void>? _connecting;
  Timer? _authenticationDeadline;
  Timer? _retry;
  int _retryCount = 0;
  int _pendingBytes = 0;
  bool _connected = false;
  bool _closed = false;
  bool _recoveryStopped = false;
  ConnectionStatusChangesHandler? _connectionStatusHandler;
  (ConnectionStatus, ConnectionStatusChangeReason) _connectionStatus = (
    .disconnected,
    .clientClose,
  );
  DesiredPropertyUpdateCallback? _desiredCallback;
  final _methodHandlers = <String, MethodCallback>{};
  MethodCallback? _defaultMethodHandler;
  bool _methodsEnabled = false;
  int _methodCallCount = 0;
  int _methodCallBytes = 0;
  static const _methodTopic = r'$iothub/methods/POST/#';
  static const _methodPrefix = r'$iothub/methods/POST/';
  static const _desiredTopic = r'$iothub/twin/PATCH/properties/desired/#';
  static const _desiredPrefix = r'$iothub/twin/PATCH/properties/desired/';

  int get pendingCount => _pending.length;
  int get pendingBytes => _pendingBytes;
  int get methodCallCount => _methodCallCount;
  int get methodCallBytes => _methodCallBytes;
  bool get isConnected => _connected;

  void setConnectionStatusChangesHandler(
    ConnectionStatusChangesHandler? handler,
  ) {
    _connectionStatusHandler = handler == null
        ? null
        : Zone.current.bindBinaryCallbackGuarded(handler);
  }

  void _changeConnectionStatus(
    ConnectionStatus status,
    ConnectionStatusChangeReason reason,
  ) {
    final next = (status, reason);
    if (_connectionStatus == next) return;
    // Commit before invoking user code: a handler can close the client or replace
    // itself synchronously, and the outer notification must not overwrite that.
    _connectionStatus = next;
    _connectionStatusHandler?.call(status, reason);
  }

  Future<void> open({CancellationToken? cancellationToken}) =>
      _submit(.open, null, cancellationToken);

  Future<void> sendEvent(
    TelemetryMessage message, {
    CancellationToken? cancellationToken,
  }) => _submit(.telemetry, message, cancellationToken);

  /// Retrieves twin properties after PUBACK and a matching service response.
  Future<TwinProperties> getTwin({
    CancellationToken? cancellationToken,
  }) async => (await _submit(.twinGet, null, cancellationToken))!;

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
      .twinPatch,
      null,
      cancellationToken,
      reportedProperties: properties,
    );
  }

  /// Registers or replaces a desired-property callback; null unsubscribes.
  ///
  /// Registration waits for SUBACK, and removal waits for UNSUBACK. Reconnects
  /// restore the subscription. Snapshots and version reconciliation belong to
  /// the application; this method does not fetch or merge desired state.
  Future<void> setDesiredPropertyUpdateCallback(
    DesiredPropertyUpdateCallback? callback, {
    CancellationToken? cancellationToken,
  }) => _submit(
    .desiredSubscription,
    null,
    cancellationToken,
    desiredCallback: callback,
  );

  Future<void> setMethodHandler(
    String methodName,
    MethodCallback? handler, {
    CancellationToken? cancellationToken,
  }) => _submit(
    .methodSubscription,
    null,
    cancellationToken,
    methodRegistration: .new(methodName, handler),
  );

  Future<void> setMethodDefaultHandler(
    MethodCallback? handler, {
    CancellationToken? cancellationToken,
  }) => _submit(
    .methodSubscription,
    null,
    cancellationToken,
    methodRegistration: .new(null, handler),
  );

  Future<TwinProperties?> _submit(
    _OperationKind kind,
    TelemetryMessage? message,
    CancellationToken? token, {
    Map<String, Object?>? reportedProperties,
    DesiredPropertyUpdateCallback? desiredCallback,
    _MethodRegistration? methodRegistration,
    String? methodRequestId,
    MethodResponse? methodResponse,
  }) {
    final reason = _closed
        ? OperationFailureReason.closed
        : (token?.isCancellationRequested ?? false)
        ? OperationFailureReason.cancelled
        : null;
    if (reason != null) {
      return Future.error(OperationFailure(reason, .notSubmitted));
    }
    if (kind == .desiredSubscription &&
        !_pending.any((operation) => operation.kind == kind) &&
        (_desiredCallback != null) == (desiredCallback != null)) {
      // Replacing a callback (or clearing an absent one) needs no wire exchange.
      _desiredCallback = desiredCallback;
      return Future.value();
    }
    if (methodRegistration != null &&
        _attempt?.methodAction == null &&
        !_pending.any((operation) => operation.kind == .methodSubscription) &&
        _methodSubscriptionNeeded(methodRegistration) == _methodsEnabled) {
      _applyMethodRegistration(methodRegistration);
      return Future.value();
    }
    final topic = switch (kind) {
      .twinGet => r'$iothub/twin/GET/?$rid=',
      .twinPatch => r'$iothub/twin/PATCH/properties/reported/?$rid=',
      .telemetry => telemetryTopic(message!, credentials.deviceId),
      .methodResponse =>
        '${r'$iothub/methods/res/'}${methodResponse!.status}'
            '/?${r'$rid='}${escapeDataString(methodRequestId!)}',
      .open || .desiredSubscription || .methodSubscription => null,
    };
    if (topic != null) {
      try {
        PublicationTopic(topic);
      } on Exception {
        // Keep dependency validation details out of the public error contract.
        throw ArgumentError('Invalid MQTT publication topic.');
      }
    }
    final payload = kind == .twinPatch
        ? encodeReportedProperties(reportedProperties!)
        : methodResponse?.result ?? message?.payload ?? const <int>[];
    final size = topic == null
        ? utf8.encode(methodRegistration?.name ?? '').length
        : payload.length +
              utf8.encode(topic).length +
              (kind.isTwin ? 36 : 0) +
              8;
    if (_pending.length >= maxPending ||
        _pendingBytes + size > maxPendingBytes) {
      return Future.error(OperationFailure(.capacity, .notSubmitted));
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
          if (!_hasReservation(operation)) _release(operation);
        },
        onTimeout: () {
          final submitted = _hasReservation(operation);
          _release(operation);
          final attempt = _attempt;
          if (submitted && attempt != null) _lost(attempt);
        },
      ),
      desiredCallback: desiredCallback,
      methodRegistration: methodRegistration,
    );
    _pending.add(operation);
    _pendingBytes += size;
    if (!operation.completion.start(
      shutdown: _shutdown,
      cancellationToken: unwrapCancellationToken(token),
    )) {
      return operation.completion.future;
    }
    if (kind == .methodSubscription) {
      _processMethodRegistrations();
      if (operation.completion.isCompleted) return operation.completion.future;
    }
    if (_connected) {
      _flush();
    } else if (_retry == null) {
      _ensureConnection();
    }
    return operation.completion.future;
  }

  bool _hasReservation(_Operation operation) =>
      operation.packetId != null ||
      identical(_attempt?.desiredAction?.operation, operation) ||
      identical(_attempt?.methodAction?.operation, operation);

  void _release(_Operation operation) {
    _clearTwinRequest(operation);
    operation.completion.release();
    if (_pending.remove(operation)) {
      _pendingBytes -= operation.size;
      if (operation.kind == .methodSubscription) {
        scheduleMicrotask(_processMethodRegistrations);
      }
    }
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
    if (_closed) return;
    _Attempt? current;
    var timedOut = false;
    connectionDiagnostics.attempts++;
    connectionDiagnostics.stage = .authentication;
    final deadline = schedule(connectionTimeout, () {
      timedOut = true;
      connectionDiagnostics.recordFailure(OperationFailureReason.timeout);
      if (current != null) {
        _lost(current);
      } else if (!_closed) {
        _changeConnectionStatus(.disconnectedRetrying, .communicationError);
      }
    });
    _authenticationDeadline = deadline;
    try {
      final token = await _sasTokens.getToken();
      if (_closed || timedOut) return;
      final transport = MqttTransport(
        credentials.connectionHostName,
        credentials.deviceId,
        port: port,
        transport: this.transport,
        diagnostics: connectionDiagnostics,
        maxBufferedBytes: maxPendingBytes + 65536,
        securityContext: securityContext,
        schedule: schedule,
        now: now,
      );
      transport.manuallyAcknowledgeQos1 = true;
      final attempt = _Attempt(transport);
      current = attempt;
      _attempt = attempt;
      transport.onDisconnected = () => _lost(attempt);
      // Acquisition and network setup share one connection deadline.
      attempt.deadline = deadline;
      _authenticationDeadline = null;
      final status = await transport.connect(
        '${credentials.hostName}/${credentials.deviceId}/?'
        'api-version=2020-09-30&DeviceClientType='
        '${escapeDataString('azure-iot-hub-dart/0.1.0-dev.1')}',
        token.value,
      );
      if (_closed || !identical(_attempt, attempt)) return;
      if (status?.state != .connected) {
        throw TransportFailure(.network);
      }
      attempt.subscription = transport.published!.listen((message) {
        if (!identical(_attempt, attempt)) return;
        final operation = _packets.remove(
          message.variableHeader!.messageIdentifier,
        );
        if (operation == null) return;
        operation.packetId = null;
        if (operation.kind.isTwin && !operation.completion.isCompleted) {
          final response = operation.response;
          if (response != null) {
            _finishTwinResponse(operation, response);
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
          if (!identical(_attempt, attempt)) break;
          final publish = message.payload as MqttPublishMessage;
          try {
            if (message.topic.startsWith(_methodPrefix)) {
              _receiveMethod(attempt, message.topic, publish);
              continue;
            } else if (message.topic.startsWith(_desiredPrefix)) {
              final patch = decodeDesiredPropertyPatch(publish.payload.message);
              _desiredCallback?.call(patch);
            } else {
              _receiveTwin(message.topic, publish.payload.message);
            }
            if (identical(_attempt, attempt)) {
              transport.acknowledgeQos1Message(publish);
            }
          } catch (_) {
            // A malformed patch or synchronous callback failure must not leak
            // property values or acknowledge work whose dispatch failed.
            // C# closes the transport and lets its retry handler recover it.
            _lost(attempt);
          }
        }
      });
      transport.onSubscribed = (topic) {
        if (_closed || !identical(_attempt, attempt)) return;
        if (topic == _desiredTopic) {
          _completeDesiredAction(attempt, subscribed: true);
        } else if (topic == _methodTopic) {
          _completeMethodAction(attempt, subscribed: true);
        } else if (topic == r'$iothub/twin/res/#') {
          _restoreSubscriptions(attempt);
        }
      };
      transport.onUnsubscribed = (topic) {
        if (_closed || !identical(_attempt, attempt)) return;
        if (topic == _desiredTopic) {
          _completeDesiredAction(attempt, subscribed: false);
        } else if (topic == _methodTopic) {
          _completeMethodAction(attempt, subscribed: false);
        }
      };
      transport.onSubscribeFail = (_) {
        if (_closed || !identical(_attempt, attempt)) return;
        _lost(attempt, failureReason: .protocol);
      };
      connectionDiagnostics.stage = .twinSubscription;
      if (transport.subscribe(r'$iothub/twin/res/#', .atLeastOnce) == null) {
        _lost(attempt);
      }
    } catch (error) {
      if (current != null && identical(_attempt, current)) {
        _lost(current);
      } else if (current == null && !_closed && !timedOut) {
        // C# ErrorDelegatingHandler retries network/timeouts, but not TLS or
        // malformed credentials. Never retain a provider's exception text.
        if (error is TlsException) {
          connectionDiagnostics.recordFailure(OperationFailureReason.tls);
          _stopRecovery(.tls);
        } else if (error is TimeoutException) {
          connectionDiagnostics.recordFailure(OperationFailureReason.timeout);
          _changeConnectionStatus(.disconnectedRetrying, .communicationError);
        } else if (error is IOException ||
            error is cancellation.CancelledException) {
          connectionDiagnostics.recordFailure(TransportFailureKind.network);
          _changeConnectionStatus(.disconnectedRetrying, .communicationError);
        } else {
          connectionDiagnostics.recordFailure(
            OperationFailureReason.authentication,
          );
          _stopRecovery(.authentication);
        }
      }
    } finally {
      if (current == null) {
        deadline.cancel();
        _authenticationDeadline = null;
      }
      // Serialize acquisition and native setup: an uncooperative provider or
      // uncancellable DNS cannot build unbounded abandoned attempts. Callers
      // and close() settle independently; late results are discarded.
      await current?.transport.settled;
    }
  }

  void _restoreSubscriptions(_Attempt attempt) {
    if (_desiredCallback != null && !attempt.desiredSubscribed) {
      _startDesiredAction(attempt, subscribe: true);
    } else if (_methodsEnabled && !attempt.methodsSubscribed) {
      _startMethodAction(attempt, subscribe: true);
    } else {
      _connectedReady(attempt);
    }
  }

  void _connectedReady(_Attempt attempt) {
    attempt.deadline?.cancel();
    _connected = true;
    connectionDiagnostics.stage = .ready;
    _retryCount = 0;
    _changeConnectionStatus(.connected, .connectionOk);
    if (!_closed && identical(_attempt, attempt)) _flush();
  }

  void _startDesiredAction(
    _Attempt attempt, {
    required bool subscribe,
    _Operation? operation,
  }) {
    final action = _DesiredAction(subscribe, operation);
    attempt.desiredAction = action;
    // Background recovery/cleanup has no caller operation to bound its wait.
    if (operation == null) {
      action.deadline = schedule(connectionTimeout, () => _lost(attempt));
    }
    try {
      operation?.completion.markSubmitted();
      if (subscribe) {
        if (attempt.transport.subscribe(_desiredTopic, .atLeastOnce) == null) {
          _lost(attempt);
        }
      } else {
        attempt.transport.unsubscribe(_desiredTopic, expectAcknowledge: true);
      }
    } catch (_) {
      _lost(attempt);
    }
  }

  void _completeDesiredAction(_Attempt attempt, {required bool subscribed}) {
    final action = attempt.desiredAction;
    if (action == null || action.subscribe != subscribed) return;
    action.deadline?.cancel();
    attempt.desiredAction = null;
    attempt.desiredSubscribed = subscribed;
    final operation = action.operation;
    if (operation != null) {
      if (!operation.completion.isCompleted) {
        _desiredCallback = operation.desiredCallback;
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

  void _flush() {
    final attempt = _attempt!;
    _processMethodRegistrations();
    for (final operation in _pending.toList()) {
      if (!_connected || !identical(_attempt, attempt)) break;
      if (operation.completion.isCompleted || operation.packetId != null) {
        continue;
      }
      if (operation.kind == .methodSubscription) continue;
      if (operation.kind == .desiredSubscription) {
        if (attempt.desiredAction != null) continue;
        final subscribe = operation.desiredCallback != null;
        if (attempt.desiredSubscribed == subscribe) {
          _desiredCallback = operation.desiredCallback;
          operation.completion.complete(null);
          _release(operation);
        } else {
          _startDesiredAction(
            attempt,
            subscribe: subscribe,
            operation: operation,
          );
        }
        continue;
      }
      if (operation.kind == .open) {
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
          .atLeastOnce,
          bytes,
        );
        operation.packetId = id;
        _packets[id] = operation;
      } catch (_) {
        _lost(attempt);
      }
    }
    if (_connected &&
        identical(_attempt, attempt) &&
        attempt.desiredAction == null &&
        attempt.desiredSubscribed != (_desiredCallback != null)) {
      // Cancellation can arrive while SUBACK/UNSUBACK is in flight. Restore the
      // last committed registration once that exchange has released its ID.
      _startDesiredAction(attempt, subscribe: _desiredCallback != null);
    }
    if (_connected &&
        identical(_attempt, attempt) &&
        attempt.methodAction == null &&
        attempt.methodsSubscribed != _methodsEnabled) {
      _startMethodAction(attempt, subscribe: _methodsEnabled);
    }
  }

  void _applyMethodRegistration(_MethodRegistration registration) {
    final name = registration.name;
    final handler = registration.handler;
    if (name == null) {
      _defaultMethodHandler = handler;
    } else if (handler == null) {
      _methodHandlers.remove(name);
    } else {
      _methodHandlers[name] = handler;
    }
  }

  bool _methodSubscriptionNeeded(_MethodRegistration registration) =>
      registration.handler != null ||
      _methodHandlers.keys.any((name) => name != registration.name) ||
      (registration.name != null && _defaultMethodHandler != null);

  void _processMethodRegistrations() {
    // Recovery and cancelled wire exchanges do not hold C#'s local handler
    // semaphore. They still reserve the transport until their ACK arrives.
    if (_closed) return;
    final activeRegistration = _attempt?.methodAction?.operation;
    if (activeRegistration != null &&
        !activeRegistration.completion.isCompleted) {
      return;
    }
    for (final operation in _pending.toList()) {
      if (operation.kind != .methodSubscription ||
          operation.completion.isCompleted) {
        continue;
      }
      final registration = operation.methodRegistration!;
      // C# removes the delegate before awaiting DisableMethodsAsync. Failure or
      // cancellation of that exchange does not restore the removed delegate.
      if (registration.handler == null) _applyMethodRegistration(registration);
      final subscribe = _methodSubscriptionNeeded(registration);
      if (_methodsEnabled == subscribe ||
          (_connected &&
              _attempt?.methodAction == null &&
              _attempt?.methodsSubscribed == subscribe)) {
        _methodsEnabled = subscribe;
        _applyMethodRegistration(registration);
        operation.completion.complete(null);
        _release(operation);
        continue;
      }
      final attempt = _attempt;
      if (_connected && attempt != null && attempt.methodAction == null) {
        _startMethodAction(attempt, subscribe: subscribe, operation: operation);
      }
      return;
    }
  }

  void _startMethodAction(
    _Attempt attempt, {
    required bool subscribe,
    _Operation? operation,
  }) {
    final action = _MethodAction(subscribe, operation);
    attempt.methodAction = action;
    if (operation == null) {
      action.deadline = schedule(connectionTimeout, () => _lost(attempt));
    }
    try {
      operation?.completion.markSubmitted();
      if (subscribe) {
        if (attempt.transport.subscribe(_methodTopic, .atLeastOnce) == null) {
          _lost(attempt);
        }
      } else {
        attempt.transport.unsubscribe(_methodTopic, expectAcknowledge: true);
      }
    } catch (_) {
      _lost(attempt);
    }
  }

  void _completeMethodAction(_Attempt attempt, {required bool subscribed}) {
    final action = attempt.methodAction;
    if (action == null || action.subscribe != subscribed) return;
    action.deadline?.cancel();
    attempt.methodAction = null;
    attempt.methodsSubscribed = subscribed;
    final operation = action.operation;
    if (operation != null) {
      if (!operation.completion.isCompleted) {
        _methodsEnabled = subscribed;
        _applyMethodRegistration(operation.methodRegistration!);
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

  void _receiveMethod(
    _Attempt attempt,
    String topic,
    MqttPublishMessage publish,
  ) {
    final route = parseMethodTopic(topic);
    if (route == null) throw const FormatException('Invalid method topic.');
    final (name, requestId) = route;
    final payload = publish.payload.message;
    final size = payload.length + utf8.encode(topic).length;
    if (_methodCallCount >= maxPending ||
        _methodCallBytes + size > maxPendingBytes) {
      // Reject before retaining the payload. Release any MQTT QoS 1 reservation
      // immediately; only the bounded outgoing 503 response can remain.
      _ackMethodRequest(attempt, publish);
      unawaited(_replyToMethod(attempt, null, requestId, .new(503)));
      return;
    }
    _methodCallCount++;
    _methodCallBytes += size;
    unawaited(_dispatchMethod(attempt, publish, name, requestId, size));
  }

  Future<void> _dispatchMethod(
    _Attempt attempt,
    MqttPublishMessage publish,
    String name,
    String requestId,
    int size,
  ) async {
    try {
      // C# takes the registration semaphore before selecting a handler. Keep
      // early requests bounded while a registration is waiting for its ACK.
      while (!_closed) {
        final registration = _pending
            .where(
              (operation) =>
                  operation.kind == .methodSubscription &&
                  !operation.completion.isCompleted,
            )
            .firstOrNull;
        if (registration == null) break;
        try {
          await registration.completion.future;
        } on OperationFailure {
          // Route using the state left by the completed/cancelled registration.
        }
      }
      if (_closed) return;
      MethodResponse response;
      try {
        validateMethodPayload(publish.payload.message);
      } catch (_) {
        await _replyToMethod(attempt, publish, requestId, .new(400));
        return;
      }
      final handler = _methodHandlers[name] ?? _defaultMethodHandler;
      if (handler == null) {
        response = .new(501);
      } else {
        try {
          response = await handler(.new(name, publish.payload.message));
        } catch (_) {
          // C# returns 500 for user-code failures, including invalid results.
          response = .new(500);
        }
      }
      if (!_closed) await _replyToMethod(attempt, publish, requestId, response);
    } finally {
      // Retain this reservation across reconnect and until application work
      // actually settles. A deadline must not admit unbounded abandoned handlers.
      _methodCallCount--;
      _methodCallBytes -= size;
    }
  }

  Future<void> _replyToMethod(
    _Attempt attempt,
    MqttPublishMessage? publish,
    String requestId,
    MethodResponse response,
  ) async {
    try {
      if (_closed) return;
      await _submit(
        .methodResponse,
        null,
        null,
        methodRequestId: requestId,
        methodResponse: response,
      );
      _ackMethodRequest(attempt, publish);
    } on OperationFailure catch (error) {
      if (!identical(_attempt, attempt)) return;
      if (error.reason == .capacity) {
        // Drop an overloaded QoS 1 request too, so mqtt_client cannot retain an
        // unbounded acknowledgement queue. The service caller will time out.
        _ackMethodRequest(attempt, publish);
      } else {
        _lost(attempt);
      }
    } catch (_) {
      _lost(attempt);
    }
  }

  void _ackMethodRequest(_Attempt attempt, MqttPublishMessage? publish) {
    if (publish == null || !identical(_attempt, attempt)) return;
    try {
      attempt.transport.acknowledgeQos1Message(publish);
    } catch (_) {
      _lost(attempt);
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
      operation.completion.fail(.capacity);
      _clearTwinRequest(operation);
      if (operation.packetId == null) _release(operation);
      return;
    }
    operation.response = response;
    _pendingBytes += payload.length;
    if (operation.packetId == null) _finishTwinResponse(operation, response);
  }

  void _finishTwinResponse(_Operation operation, TwinResponse response) {
    if (response.status == 429) {
      _retryTwin(operation);
      return;
    }
    if (response.status >= 300) {
      operation.completion.fail(.service, statusCode: response.status);
    } else if (operation.kind == .twinPatch) {
      // C# ignores successful PATCH response bodies, including empty 204s.
      operation.completion.complete(null);
    } else {
      try {
        operation.completion.complete(
          TwinProperties.fromBytes(response.payload),
        );
      } on FormatException {
        operation.completion.fail(.protocol);
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

  void _lost(_Attempt attempt, {OperationFailureReason? failureReason}) {
    if (!identical(_attempt, attempt)) return;
    _attempt = null;
    _connected = false;
    attempt.deadline?.cancel();
    attempt.desiredAction?.deadline?.cancel();
    attempt.methodAction?.deadline?.cancel();
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
    if (_closed) return;
    if (failureReason != null) {
      _stopRecovery(failureReason);
    } else if (failure != null && !failure.isTransient) {
      _stopRecovery(
        switch (failure.kind) {
          .authentication => .authentication,
          .tls => .tls,
          _ => .protocol,
        },
        statusReason: failure.kind == .authentication
            ? .badCredential
            : .communicationError,
      );
    } else {
      // Reserve backoff before calling user code, which may submit more work.
      _scheduleRetry();
      _changeConnectionStatus(.disconnectedRetrying, .communicationError);
    }
  }

  void _stopRecovery(
    OperationFailureReason reason, {
    ConnectionStatusChangeReason statusReason = .communicationError,
  }) {
    _recoveryStopped = true;
    _retry?.cancel();
    _retry = null;
    for (final operation in _pending.toList()) {
      operation.completion.fail(reason);
      _release(operation);
    }
    _changeConnectionStatus(.disconnected, statusReason);
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
    return .new(milliseconds: min(10000, 100 + factor * (80 + _randomInt(40))));
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _desiredCallback = null;
    _methodHandlers.clear();
    _defaultMethodHandler = null;
    _retry?.cancel();
    _retry = null;
    _authenticationDeadline?.cancel();
    _authenticationDeadline = null;
    _shutdown.cancel();
    final attempt = _attempt;
    if (attempt != null) _lost(attempt);
    for (final operation in _pending.toList()) {
      _release(operation);
    }
    _changeConnectionStatus(.disabled, .clientClose);
    _connectionStatusHandler = null;
  }
}

final class _Attempt(final MqttTransport transport) {
  Timer? deadline;
  StreamSubscription<MqttPublishMessage>? subscription;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? updates;
  bool desiredSubscribed = false;
  _DesiredAction? desiredAction;
  bool methodsSubscribed = false;
  _MethodAction? methodAction;
}

final class _DesiredAction(final bool subscribe, final _Operation? operation) {
  Timer? deadline;
}

final class _MethodAction(final bool subscribe, final _Operation? operation) {
  Timer? deadline;
}

final class _MethodRegistration(
  final String? name,
  final MethodCallback? handler,
);

enum _OperationKind {
  open,
  telemetry,
  twinGet,
  twinPatch,
  desiredSubscription,
  methodSubscription,
  methodResponse;

  bool get isTwin => this == twinGet || this == twinPatch;
}

final class _Operation(
  final _OperationKind kind,
  final List<int> payload,
  final String? topic,
  final int size,
  final PendingOperation<TwinProperties?> completion, {
  final DesiredPropertyUpdateCallback? desiredCallback,
  final _MethodRegistration? methodRegistration,
}) {
  int? packetId;
  String? requestId;
  TwinResponse? response;
  Timer? responseTimer;
  Timer? retry;
  int retryCount = 0;
}
