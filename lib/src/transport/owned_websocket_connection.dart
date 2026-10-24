import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:mqtt_client/mqtt_client.dart';

import 'connection_diagnostics.dart';
import 'mqtt_frame_reader.dart';
import 'owned_tls_socket.dart';

/// An IoT Hub WebSocket connection using Dart's HTTP upgrade and framing.
final class OwnedWebSocketConnection extends MqttConnectionBase<WebSocket> {
  OwnedWebSocketConnection(
    super.clientEventBus, {
    required this.onFailure,
    required this.maxBufferedBytes,
    SecurityContext? securityContext,
    this.diagnostics,
    Future<ConnectionTask<RawSocket>> Function(String, int)? startConnect,
  }) : _socket = OwnedTlsSocket(
         maxBufferedBytes: maxBufferedBytes,
         securityContext: securityContext,
         diagnostics: diagnostics,
         limitReadsUntilReset: true,
         startConnect: startConnect,
       ) {
    _reader = MqttFrameReader(maxBufferedBytes, (message) {
      if (_closed) return;
      if (message.header!.messageType == MqttMessageType.connectAck) {
        clientEventBus!.fire(ConnectAckMessageAvailable(message));
      } else {
        clientEventBus!.fire(MessageAvailable(message));
      }
    });
  }

  final void Function(Object) onFailure;
  final int maxBufferedBytes;
  final ConnectionDiagnostics? diagnostics;
  final OwnedTlsSocket _socket;
  final _http = HttpClient();
  final _outgoing = Queue<Uint8List>();
  late final MqttFrameReader _reader;
  Future<void> _nativeSetup = Future.value();
  Future<void>? _writer;
  StreamSubscription<Object?>? _subscription;
  int _queuedBytes = 0;
  bool _socketStarted = false;
  bool _writing = false;
  bool _closed = false;

  @override
  Future<void> connect(String server, int port) async {
    _http.findProxy = (_) => 'DIRECT';
    _http.connectionFactory = (uri, proxyHost, proxyPort) async {
      if (_closed || _socketStarted) {
        throw const SocketException('Connection retired.');
      }
      // Uri normalizes DNS names; connection strings can preserve their case.
      if (uri.scheme != 'https' ||
          uri.host != server.toLowerCase() ||
          uri.port != port) {
        throw const WebSocketException('Unexpected upgrade destination.');
      }
      _socketStarted = true;
      final setup = _socket.connect(server, port).then((socket) {
        diagnostics?.stage = ConnectionStage.webSocketUpgrade;
        return socket;
      });
      _nativeSetup = setup;
      return ConnectionTask.fromSocket(setup, _socket.destroy);
    };
    try {
      final socket = await WebSocket.connect(
        Uri(
          scheme: 'wss',
          host: server,
          port: port,
          path: r'/$iothub/websocket',
          // This transport uses SAS. IoT Hub documents this option for clients
          // that cannot negotiate a client certificate; see docs/upstream.md.
          queryParameters: const {'iothub-no-client-cert': 'true'},
        ).toString(),
        protocols: const ['mqtt'],
        compression: CompressionOptions.compressionOff,
        customClient: _http,
        maxPayloadLength: maxBufferedBytes,
      );
      client = socket;
      if (_closed) {
        unawaited(socket.close());
        throw const SocketException('Connection retired.');
      }
      if (socket.protocol != null && socket.protocol != 'mqtt') {
        throw const WebSocketException('Unexpected WebSocket subprotocol.');
      }
      _socket.resetReadBudget();
      _subscription = socket.listen(
        (data) {
          if (_closed) return;
          try {
            if (data is! List<int>) {
              throw const FormatException('Expected binary MQTT data.');
            }
            _socket.resetReadBudget();
            _reader.add(data);
          } catch (error) {
            _fail(error);
          }
        },
        onError: (Object error) => _fail(error),
        onDone: () {
          if (_closed) return;
          diagnostics?.lastWebSocketCloseCode = socket.closeCode;
          _fail(const SocketException('Connection ended.'));
        },
      );
    } finally {
      // HttpClient can settle before uncancellable DNS does. Keep the device
      // client's connection-attempt guard until native setup has also settled.
      await _nativeSetup;
    }
  }

  @override
  Future<void> connectAuto(String server, int port) =>
      throw UnsupportedError('The device client owns recovery.');

  @override
  void send(MqttByteBuffer message) {
    if (_closed || client == null) {
      throw const SocketException('Connection is not open.');
    }
    if (_queuedBytes + message.length > maxBufferedBytes) {
      throw StateError('WebSocket write buffer exceeded.');
    }
    _queuedBytes += message.length;
    _outgoing.add(Uint8List.fromList(message.buffer!));
    if (!_writing) _writer = _drain();
  }

  Future<void> _drain() async {
    _writing = true;
    try {
      while (!_closed && _outgoing.isNotEmpty) {
        final bytes = _outgoing.first;
        await client!.addStream(Stream.value(bytes));
        await _socket.flush();
        if (_closed) return;
        _outgoing.removeFirst();
        _queuedBytes -= bytes.length;
      }
    } catch (error) {
      _fail(error);
    } finally {
      _writing = false;
    }
  }

  void _fail(Object error) {
    if (_closed) return;
    closeClient();
    onFailure(error);
  }

  @override
  void stopListening() {
    unawaited(_subscription?.cancel());
    _subscription = null;
  }

  @override
  void closeClient() {
    if (_closed) return;
    _closed = true;
    _socket.destroy();
    _http.close(force: true);
    stopListening();
    final socket = client;
    if (socket != null) {
      // Dart cannot close its WebSocket sink while addStream is active. The
      // native socket is already closed; let its writer settle before disposal.
      (_writer ?? Future<void>.value()).then((_) => socket.close()).ignore();
    }
    client = null;
    _outgoing.clear();
    _queuedBytes = 0;
    _reader.clear();
  }

  @override
  void disposeClient() => closeClient();
}
