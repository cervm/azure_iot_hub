import 'dart:async';
import 'dart:convert';
import 'dart:io';

// A minimal loopback MQTT peer: tests explicitly send CONNACK and PUBACK.
// It is deliberately not an Azure emulator or a general-purpose broker.
final class MqttPeerServer {
  MqttPeerServer._(Stream<Socket> sockets, this.port, this._closeServer) {
    _listener = sockets.listen((socket) {
      final peer = MqttPeer(socket);
      peers.add(peer);
      _connections.add(peer);
    }, onError: (Object error) => errors.add(error));
  }

  static Future<MqttPeerServer> start() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    return MqttPeerServer._(server, server.port, server.close);
  }

  static Future<MqttPeerServer> startTls(SecurityContext context) async {
    final server = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    return MqttPeerServer._(server, server.port, server.close);
  }

  final Future<void> Function() _closeServer;
  final errors = <Object>[];
  final peers = <MqttPeer>[];
  final _connections = StreamController<MqttPeer>();
  late final _iterator = StreamIterator(_connections.stream);
  late final StreamSubscription<Socket> _listener;
  bool _listening = false;
  final int port;

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
    await _closeServer();
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

  Future<void> connack({int code = 0, bool twinResponses = false}) async {
    socket.add([0x20, 2, 0, code]);
    await socket.flush();
    if (twinResponses && code == 0) await acceptTwinSubscription();
  }

  Future<void> acceptTwinSubscription() async {
    final packet = await nextPacket(8);
    final length = (packet.body[2] << 8) | packet.body[3];
    if (utf8.decode(packet.body.sublist(4, 4 + length)) !=
            r'$iothub/twin/res/#' ||
        packet.body.last != 1) {
      throw StateError('Expected a QoS 1 twin response subscription.');
    }
    await suback((packet.body[0] << 8) | packet.body[1]);
  }

  Future<void> suback(int id, {int qos = 1}) async {
    socket.add([0x90, 3, id >> 8, id & 255, qos]);
    await socket.flush();
  }

  Future<void> publish(String topic, List<int> payload, {int id = 1}) async {
    final name = utf8.encode(topic);
    final body = [
      name.length >> 8,
      name.length & 255,
      ...name,
      id >> 8,
      id & 255,
      ...payload,
    ];
    final length = <int>[];
    var remaining = body.length;
    do {
      var digit = remaining % 128;
      remaining ~/= 128;
      if (remaining > 0) digit |= 128;
      length.add(digit);
    } while (remaining > 0);
    socket.add([0x32, ...length, ...body]);
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
  String get topic =>
      utf8.decode(body.sublist(2, 2 + ((body[0] << 8) | body[1])));
  int get packetId {
    final topicLength = (body[0] << 8) | body[1];
    final offset = 2 + topicLength;
    return (body[offset] << 8) | body[offset + 1];
  }
}
