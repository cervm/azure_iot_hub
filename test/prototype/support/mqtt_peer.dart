import 'dart:async';
import 'dart:io';

// A minimal loopback MQTT peer: tests explicitly send CONNACK and PUBACK.
// It is deliberately not an Azure emulator or a general-purpose broker.
final class MqttPeerServer {
  MqttPeerServer._(this._server) {
    _listener = _server.listen((socket) {
      final peer = MqttPeer(socket);
      peers.add(peer);
      _connections.add(peer);
    });
  }

  static Future<MqttPeerServer> start() async => MqttPeerServer._(
    await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
  );

  final ServerSocket _server;
  final peers = <MqttPeer>[];
  final _connections = StreamController<MqttPeer>();
  late final _iterator = StreamIterator(_connections.stream);
  late final StreamSubscription<Socket> _listener;
  bool _listening = false;
  int get port => _server.port;

  Future<MqttPeer> nextConnection() async {
    _listening = true;
    if (!await _iterator.moveNext()) throw StateError('Server closed.');
    return _iterator.current;
  }

  Future<void> close() async {
    for (final peer in peers) {
      await peer.close();
    }
    if (!_listening) unawaited(_iterator.moveNext());
    await _iterator.cancel();
    await _connections.close();
    await _listener.cancel();
    await _server.close();
  }
}

final class MqttPeer {
  MqttPeer(this.socket) {
    unawaited(socket.done.then<void>((_) {}, onError: (Object error) {}));
    _listener = socket.listen(
      _read,
      onError: (Object error) {
        _finish();
      },
      onDone: _finish,
    );
  }

  final Socket socket;
  final _buffer = <int>[];
  final _packets = StreamController<Packet>();
  final _disconnected = Completer<void>();
  late final _iterator = StreamIterator(_packets.stream);
  late final StreamSubscription<List<int>> _listener;
  Future<void> get disconnected => _disconnected.future;

  void _finish() {
    if (!_disconnected.isCompleted) _disconnected.complete();
    unawaited(_packets.close());
  }

  void _read(List<int> bytes) {
    _buffer.addAll(bytes);
    while (_buffer.length >= 2) {
      var remaining = 0;
      var multiplier = 1;
      var index = 1;
      while (true) {
        if (index >= _buffer.length) return;
        final value = _buffer[index++];
        remaining += (value & 127) * multiplier;
        if (value < 128) break;
        multiplier *= 128;
        if (index > 4) throw StateError('Invalid MQTT remaining length.');
      }
      if (_buffer.length < index + remaining) return;
      _packets.add(
        Packet(_buffer[0], _buffer.sublist(index, index + remaining)),
      );
      _buffer.removeRange(0, index + remaining);
    }
  }

  Future<Packet> nextPacket(int type) async {
    if (!await _iterator.moveNext()) throw StateError('Peer disconnected.');
    final packet = _iterator.current;
    if (packet.type != type) {
      throw StateError('Expected MQTT type $type; received ${packet.type}.');
    }
    return packet;
  }

  Future<void> connack() async {
    socket.add([0x20, 2, 0, 0]);
    await socket.flush();
  }

  Future<void> puback(int id) async {
    socket.add([0x40, 2, id >> 8, id & 255]);
    await socket.flush();
  }

  Future<void> close() async {
    socket.destroy();
    await _listener.cancel();
    await _iterator.cancel();
    _finish();
  }
}

final class Packet(final int header, final List<int> body) {
  int get type => header >> 4;
  int get packetId {
    final topicLength = (body[0] << 8) | body[1];
    final offset = 2 + topicLength;
    return (body[offset] << 8) | body[offset + 1];
  }
}
