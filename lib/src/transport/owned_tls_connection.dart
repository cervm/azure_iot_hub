import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:mqtt_client/mqtt_client.dart';

/// A single TLS connection whose TCP socket remains reachable during handshake.
final class OwnedTlsConnection extends MqttConnectionBase<RawSecureSocket> {
  OwnedTlsConnection(
    super.clientEventBus, {
    required this.onFailure,
    required this.maxBufferedBytes,
    this.securityContext,
    Future<ConnectionTask<RawSocket>> Function(String, int)? startConnect,
  }) : _startConnect =
           startConnect ?? ((host, port) => RawSocket.startConnect(host, port));

  final void Function(Object) onFailure;
  final int maxBufferedBytes;
  final SecurityContext? securityContext;
  final Future<ConnectionTask<RawSocket>> Function(String, int) _startConnect;
  ConnectionTask<RawSocket>? _task;
  RawSocket? _raw;
  StreamSubscription<RawSocketEvent>? _subscription;
  final _outgoing = Queue<Uint8List>();
  final _incoming = BytesBuilder(copy: false);
  int _writeOffset = 0;
  int _queuedBytes = 0;
  bool _closed = false;
  final _retired = Completer<void>();

  @override
  Future<void> connect(String server, int port) async {
    // startConnect itself awaits DNS. If closed during resolution, cancel the
    // task as soon as it is available, without ever starting TLS.
    final task = await _startConnect(server, port);
    _task = task;
    if (_closed) task.cancel();
    final raw = await task.socket;
    _raw = raw;
    if (_closed) {
      await raw.close();
      throw const SocketException('Connection retired.');
    }
    raw.setOption(SocketOption.tcpNoDelay, true);
    final handshake =
        RawSecureSocket.secure(
          raw,
          host: server,
          context: securityContext,
        ).then((secure) {
          if (_closed) unawaited(secure.close());
          return secure;
        });
    // Closing RawSocket releases the native socket, but does not reliably settle
    // RawSecureSocket's handshake future. Race retirement and consume any late
    // completion, so a stalled peer cannot prevent subsequent recovery.
    final secure = await Future.any([
      handshake,
      _retired.future.then<RawSecureSocket>((_) {
        throw const SocketException('Connection retired.');
      }),
    ]);
    if (_closed) {
      await secure.close();
      throw const SocketException('Connection retired.');
    }
    client = secure;
    secure.writeEventsEnabled = false;
    _subscription = secure.listen(
      _event,
      onError: (Object error) => _fail(error),
      onDone: () => _fail(const SocketException('Connection ended.')),
    );
  }

  @override
  Future<void> connectAuto(String server, int port) =>
      throw UnsupportedError('The device client owns recovery.');

  void _event(RawSocketEvent event) {
    if (_closed) return;
    try {
      if (event == RawSocketEvent.read) {
        // Limit each read as well as retained data. The MQTT decoder only sees
        // complete frames, including when the length prefix is fragmented.
        final bytes = client!.read(8192);
        if (bytes != null) _read(bytes);
      } else if (event == RawSocketEvent.write) {
        _drain();
      } else {
        _fail(const SocketException('Connection ended.'));
      }
    } catch (error) {
      _fail(error);
    }
  }

  void _read(Uint8List bytes) {
    if (_incoming.length + bytes.length > maxBufferedBytes) {
      throw const FormatException('MQTT receive buffer exceeded.');
    }
    _incoming.add(bytes);
    final buffer = _incoming.takeBytes();
    var offset = 0;
    while (offset < buffer.length) {
      var index = offset + 1;
      var remaining = 0;
      var multiplier = 1;
      var completeLength = false;
      while (index < buffer.length) {
        final digit = buffer[index++];
        remaining += (digit & 127) * multiplier;
        if (digit < 128) {
          completeLength = true;
          break;
        }
        if (index - offset == 5) {
          throw const FormatException('Invalid MQTT length.');
        }
        multiplier *= 128;
      }
      if (!completeLength) break;
      if (index - offset + remaining > maxBufferedBytes) {
        throw const FormatException('MQTT frame exceeded limit.');
      }
      final end = index + remaining;
      if (end > buffer.length) break;
      final frame = MqttByteBuffer.fromList(buffer.sublist(offset, end));
      late final MqttMessage message;
      try {
        message = MqttMessage.createFrom(frame);
      } catch (_) {
        throw const FormatException('Invalid MQTT frame.');
      }
      if (frame.position != frame.length) {
        throw const FormatException('Invalid MQTT frame.');
      }
      if (message.header!.messageType == MqttMessageType.connectAck) {
        clientEventBus!.fire(ConnectAckMessageAvailable(message));
      } else {
        clientEventBus!.fire(MessageAvailable(message));
      }
      offset = end;
    }
    if (offset < buffer.length) {
      _incoming.add(Uint8List.sublistView(buffer, offset));
    }
  }

  @override
  void send(MqttByteBuffer message) {
    if (_closed || client == null) {
      throw const SocketException('Connection is not open.');
    }
    if (_queuedBytes + message.length > maxBufferedBytes) {
      throw StateError('MQTT write buffer exceeded.');
    }
    _outgoing.add(Uint8List.fromList(message.buffer!));
    _queuedBytes += message.length;
    _drain();
  }

  void _drain() {
    while (_outgoing.isNotEmpty) {
      final bytes = _outgoing.first;
      final written = client!.write(bytes, _writeOffset);
      _queuedBytes -= written;
      _writeOffset += written;
      if (_writeOffset < bytes.length) {
        client!.writeEventsEnabled = true;
        return;
      }
      _outgoing.removeFirst();
      _writeOffset = 0;
    }
    client!.writeEventsEnabled = false;
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
    _retired.complete();
    stopListening();
    _task?.cancel();
    // Closing the retained raw socket also aborts a TLS handshake in progress.
    unawaited(_raw?.close());
    unawaited(client?.close());
    _raw = null;
    client = null;
    _outgoing.clear();
    _incoming.clear();
    _queuedBytes = 0;
    _writeOffset = 0;
  }

  @override
  void disposeClient() => closeClient();
}
