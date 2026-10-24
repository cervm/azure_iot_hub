import 'dart:async';
import 'dart:io';

import 'package:event_bus/event_bus.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:typed_data/typed_buffers.dart';

import '../pending_operation.dart';
import 'owned_tls_connection.dart';

enum TransportFailureKind { network, tls, authentication, protocol }

/// A transport failure that never includes credentials or packet contents.
final class TransportFailure(final TransportFailureKind kind)
    implements Exception {
  bool get isTransient => kind == TransportFailureKind.network;

  @override
  String toString() => 'TransportFailure($kind)';
}

/// A single MQTT attempt; the device client owns deadlines and recovery.
final class MqttTransport extends MqttClient {
  MqttTransport(
    super.server,
    super.clientIdentifier, {
    required int port,
    required int maxBufferedBytes,
    SecurityContext? securityContext,
    Schedule schedule = Timer.new,
    DateTime Function() now = DateTime.now,
  }) {
    this.port = port;
    instantiationCorrect = true;
    autoReconnect = false;
    setProtocolV311();
    connectionMessage = MqttConnectMessage().withClientIdentifier(
      clientIdentifier,
    );
    final bus = MqttEventBus.fromEventBus(EventBus());
    clientEventBus = bus;
    _handler = _ConnectionHandler(
      bus,
      securityContext: securityContext,
      maxBufferedBytes: maxBufferedBytes,
      schedule: schedule,
      now: now,
    );
    connectionHandler = _handler;
  }

  late final _ConnectionHandler _handler;
  bool _retired = false;
  TransportFailure? get failure => _handler.failure;

  /// Completion of native connection setup, including late DNS resolution.
  Future<void> get settled => _handler.settled;

  // Upstream's credential check logs the SAS password when its global logger is
  // enabled. MQTT 3.1.1 has no 12-character credential advisory to preserve.
  @override
  void checkCredentials(String? username, String? password) {}

  void retire() {
    if (_retired) return;
    _retired = true;
    _handler.abort();
    // The retained handler owns the socket even after MqttClient clears its
    // connectionHandler. No late connection can escape retirement.
    disconnect();
  }
}

final class _ConnectionHandler extends MqttConnectionHandlerBase {
  _ConnectionHandler(
    super.clientEventBus, {
    required SecurityContext? securityContext,
    required int maxBufferedBytes,
    required this.schedule,
    required this.now,
  }) : super(maxConnectionAttempts: 1) {
    _wire = OwnedTlsConnection(
      clientEventBus,
      securityContext: securityContext,
      maxBufferedBytes: maxBufferedBytes,
      onFailure: _failed,
    );
    connection = _wire;
    initialiseListeners();
    registerForMessage(MqttMessageType.pingResponse, (_) {
      _pong?.cancel();
      _pong = null;
      _schedulePing();
      return true;
    });
  }

  final Schedule schedule;
  final DateTime Function() now;
  late final OwnedTlsConnection _wire;
  final _result = Completer<MqttClientConnectionStatus>();
  Future<void> settled = Future.value();
  TransportFailure? failure;
  bool _aborted = false;
  Timer? _ping;
  Timer? _pong;
  DateTime? _lastReceived;

  @override
  Future<MqttClientConnectionStatus> internalConnect(
    String hostname,
    int port,
    MqttConnectMessage? message,
  ) {
    connectionStatus.state = MqttConnectionState.connecting;
    settled = _wire
        .connect(hostname, port)
        .then<void>((_) {
          if (_aborted) return;
          // MqttClient overwrites this field. Advertise the C# default while using
          // its separate 75-second idle check and 30-second PINGRESP deadline.
          message!.variableHeader!.keepAlive = 300;
          sendMessage(message);
          _lastReceived = now();
        })
        .catchError((Object error) => _failed(error));
    return _result.future;
  }

  @override
  void connectAckReceived(ConnectAckMessageAvailable event) {
    if (_aborted) return;
    if (_result.isCompleted) {
      _failed(const FormatException('Unexpected CONNACK.'));
      return;
    }
    final message = event.message as MqttConnectAckMessage;
    final code = message.variableHeader.returnCode;
    connectionStatus.returnCode = code;
    if (code != MqttConnectReturnCode.connectionAccepted) {
      _failed(
        TransportFailure(switch (code) {
          MqttConnectReturnCode.brokerUnavailable =>
            TransportFailureKind.network,
          MqttConnectReturnCode.notAuthorized ||
          MqttConnectReturnCode.badUsernameOrPassword =>
            TransportFailureKind.authentication,
          _ => TransportFailureKind.protocol,
        }),
      );
      return;
    }
    connectionStatus.state = MqttConnectionState.connected;
    connectionStatus.connectAckMessage = message;
    initialConnectionComplete = true;
    _lastReceived = now();
    _schedulePing();
    _result.complete(connectionStatus);
    onConnected?.call();
  }

  @override
  void messageAvailable(MessageAvailable event) {
    if (_aborted) return;
    if (!initialConnectionComplete) {
      _failed(const FormatException('Expected CONNACK.'));
      return;
    }
    _lastReceived = now();
    super.messageAvailable(event);
  }

  @override
  void sendMessage(MqttMessage? message) {
    if (_aborted) throw const SocketException('Connection retired.');
    // Do not call upstream's sendMessage: it logs CONNECT including the SAS.
    final buffer = MqttByteBuffer(Uint8Buffer());
    message!.writeTo(buffer);
    _wire.send(buffer);
    for (final callback in sentMessageCallbacks) {
      callback(message);
    }
  }

  void _schedulePing() {
    _ping?.cancel();
    _ping = schedule(const Duration(seconds: 75), () {
      if (_aborted) return;
      if (now().difference(_lastReceived!) <= const Duration(seconds: 75)) {
        _schedulePing();
        return;
      }
      try {
        sendMessage(MqttPingRequestMessage());
        _pong = schedule(const Duration(seconds: 30), () {
          _failed(TransportFailure(TransportFailureKind.network));
        });
      } catch (error) {
        _failed(error);
      }
    });
  }

  void _failed(Object error) {
    if (_aborted) return;
    failure = error is TransportFailure
        ? error
        : TransportFailure(switch (error) {
            HandshakeException() => TransportFailureKind.tls,
            FormatException() => TransportFailureKind.protocol,
            _ => TransportFailureKind.network,
          });
    abort();
    onDisconnected?.call();
  }

  void abort() {
    if (_aborted) return;
    _aborted = true;
    _ping?.cancel();
    _pong?.cancel();
    _wire.closeClient();
    connectionStatus.state = MqttConnectionState.disconnected;
    if (!_result.isCompleted) {
      _result.completeError(
        failure ?? TransportFailure(TransportFailureKind.network),
      );
    }
  }
}
