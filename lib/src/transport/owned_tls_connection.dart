import 'dart:async';
import 'dart:io';

import 'package:mqtt_client/mqtt_client.dart';

import 'connection_diagnostics.dart';
import 'mqtt_frame_reader.dart';
import 'owned_tls_socket.dart';

/// A single MQTT/TLS connection with bounded buffers and owned socket setup.
final class OwnedTlsConnection extends MqttConnectionBase<OwnedTlsSocket> {
  OwnedTlsConnection(
    super.clientEventBus, {
    required this.onFailure,
    required int maxBufferedBytes,
    SecurityContext? securityContext,
    ConnectionDiagnostics? diagnostics,
    Future<ConnectionTask<RawSocket>> Function(String, int)? startConnect,
  }) : _socket = OwnedTlsSocket(
         maxBufferedBytes: maxBufferedBytes,
         securityContext: securityContext,
         diagnostics: diagnostics,
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
  final OwnedTlsSocket _socket;
  late final MqttFrameReader _reader;
  StreamSubscription<List<int>>? _subscription;
  bool _closed = false;

  @override
  Future<void> connect(String server, int port) async {
    client = await _socket.connect(server, port);
    _subscription = _socket.listen(
      (bytes) {
        if (_closed) return;
        try {
          _reader.add(bytes);
        } catch (error) {
          _fail(error);
        }
      },
      onError: (Object error) => _fail(error),
      onDone: () => _fail(const SocketException('Connection ended.')),
    );
  }

  @override
  Future<void> connectAuto(String server, int port) =>
      throw UnsupportedError('The device client owns recovery.');

  @override
  void send(MqttByteBuffer message) => _socket.add(message.buffer!);

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
    stopListening();
    _reader.clear();
    client = null;
  }

  @override
  void disposeClient() => closeClient();
}
