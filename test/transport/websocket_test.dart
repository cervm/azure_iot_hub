// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license; see third_party/azure-iot-sdk-csharp-LICENSE.
// Named write cases adapt ClientWebSocketChannelTests.cs at the pinned commit.
// Additional cases cover Dart's HTTP upgrade, framing and resource ownership.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:azure_iot_hub/src/device_client.dart';
import 'package:azure_iot_hub/src/pending_operation.dart';
import 'package:azure_iot_hub/src/transport/connection_diagnostics.dart';
import 'package:azure_iot_hub/src/transport/mqtt_transport.dart';
import 'package:azure_iot_hub/src/transport/mqtt_transport_type.dart';
import 'package:azure_iot_hub/src/transport/owned_websocket_connection.dart';
import 'package:crypto/crypto.dart';
import 'package:event_bus/event_bus.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:test/test.dart';

import '../prototype/support/manual_time.dart';
import '../prototype/support/mqtt_peer.dart';
import 'support/device_test_support.dart';

void main() {
  late HttpServer server;
  late StreamIterator<HttpRequest> requests;
  late OwnedWebSocketConnection connection;
  late MqttEventBus bus;
  late List<Object> failures;
  late List<Socket> sockets;
  late ConnectionDiagnostics diagnostics;

  setUp(() async {
    server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      serverContext(),
    );
    requests = StreamIterator(server);
    failures = [];
    sockets = [];
    diagnostics = ConnectionDiagnostics();
    bus = MqttEventBus.fromEventBus(EventBus());
    connection = OwnedWebSocketConnection(
      bus,
      onFailure: failures.add,
      maxBufferedBytes: 4096,
      securityContext: clientContext(),
      diagnostics: diagnostics,
    );
  });

  tearDown(() async {
    connection.closeClient();
    for (final socket in sockets) {
      socket.destroy();
    }
    bus.destroy();
    await requests.cancel();
    await server.close(force: true);
  });

  Future<HttpRequest> request() async {
    expect(await requests.moveNext(), isTrue);
    return requests.current;
  }

  // Only the test peer writes raw frames, to exercise fragmentation and limits.
  Future<Socket> upgrade({
    String? protocol = 'mqtt',
    bool validAccept = true,
  }) async {
    final incoming = await request();
    final key = incoming.headers.value('sec-websocket-key')!;
    final accept = base64.encode(
      sha1
          .convert(
            utf8.encode(
              '$key'
              '258EAFA5-E914-47DA-95CA-C5AB0DC85B11',
            ),
          )
          .bytes,
    );
    incoming.response
      ..statusCode = HttpStatus.switchingProtocols
      ..headers.set('connection', 'Upgrade')
      ..headers.set('upgrade', 'websocket')
      ..headers.set(
        'sec-websocket-accept',
        validAccept ? accept : base64.encode(List.filled(20, 0)),
      );
    if (protocol != null) {
      incoming.response.headers.set('sec-websocket-protocol', protocol);
    }
    final socket = await incoming.response.detachSocket();
    sockets.add(socket);
    return socket;
  }

  Future<Socket> establish() async {
    final connecting = connection.connect('127.0.0.1', server.port);
    final socket = await upgrade();
    await connecting;
    return socket;
  }

  test(
    'IoT Hub SAS endpoint and mqtt subprotocol; credentials stay out of HTTP',
    () async {
      final tcp = DeviceClient(credentials());
      final wss = DeviceClient(
        credentials(),
        transport: MqttTransportType.webSocket,
      );
      expect(tcp.port, 8883);
      expect(wss.port, 443);
      await tcp.close();
      await wss.close();
      final connecting = connection.connect('127.0.0.1', server.port);
      await upgrade();
      await connecting;
      final incoming = requests.current;
      expect(incoming.method, 'GET');
      expect(incoming.uri.path, r'/$iothub/websocket');
      expect(incoming.uri.queryParameters, {'iothub-no-client-cert': 'true'});
      expect(incoming.headers.value('sec-websocket-protocol'), 'mqtt');
      expect(incoming.headers.value('sec-websocket-extensions'), isNull);
      expect(incoming.headers.value('authorization'), isNull);
      expect(
        incoming.headers.toString(),
        isNot(contains('SharedAccessSignature')),
      );
    },
  );

  test('ClientWebSocketChannelWriteWithoutConnectTest', () {
    expect(
      () => connection.send(MqttByteBuffer.fromList([0xc0, 0])),
      throwsA(isA<SocketException>()),
    );
  });

  test(
    'raw WSS CONNECT frame contains the complete unmodified MQTT packet',
    () async {
      const deviceId = 'device-1';
      const username = 'hub.azure-devices.net/device-1/?api-version=2020-09-30';
      final password = 'SharedAccessSignature ${List.filled(200, 'x').join()}';
      final transport = MqttTransport(
        '127.0.0.1',
        deviceId,
        port: server.port,
        transport: MqttTransportType.webSocket,
        maxBufferedBytes: 4096,
        securityContext: clientContext(),
      );
      addTearDown(transport.retire);
      final connecting = transport.connect(username, password);
      final peer = await upgrade();
      final received = <int>[];
      final listener = peer.listen(received.addAll);
      addTearDown(listener.cancel);
      await until(() => received.length >= 8);
      expect(received[0], 0x82); // Binary and FIN, without extensions.
      expect(received[1], 0xfe); // Masked, with a 16-bit payload length.
      final length = (received[2] << 8) | received[3];
      await until(() => received.length >= length + 8);
      final unmasked = [
        for (var i = 0; i < length; i++)
          received[i + 8] ^ received[4 + (i % 4)],
      ];
      List<int> mqttString(String value) {
        final bytes = utf8.encode(value);
        return [bytes.length >> 8, bytes.length & 255, ...bytes];
      }

      final body = [
        ...mqttString('MQTT'), 4, 0xc0, 1, 44, // v3.1.1, SAS, keepalive 300.
        ...mqttString(deviceId),
        ...mqttString(username),
        ...mqttString(password),
      ];
      expect(unmasked, [
        0x10,
        (body.length % 128) | 128,
        body.length ~/ 128,
        ...body,
      ]);
      expect(received.length, length + 8);
      peer.add([0x82, 4, 0x20, 2, 0, 0]);
      await peer.flush();
      expect((await connecting)?.state, MqttConnectionState.connected);
    },
  );

  test(
    'WSS accepts a mixed-case hostname from the connection string',
    () async {
      final mqtt = await MqttPeerServer.startWebSocket(serverContext());
      addTearDown(mqtt.close);
      await connection.connect('LOCALHOST', mqtt.port);
      expect(failures, isEmpty);
    },
  );

  test('HTTP rejection retains only safe connection diagnostics', () async {
    final diagnostics = ConnectionDiagnostics();
    final transport = MqttTransport(
      '127.0.0.1',
      'private-device-id',
      port: server.port,
      transport: MqttTransportType.webSocket,
      maxBufferedBytes: 4096,
      securityContext: clientContext(),
      diagnostics: diagnostics,
    );
    addTearDown(transport.retire);
    final connecting = expectLater(
      transport.connect('private-username', 'private-password'),
      throwsA(isA<TransportFailure>()),
    );
    final incoming = await request();
    incoming.response
      ..statusCode = HttpStatus.forbidden
      ..write('private-response-body');
    await incoming.response.close();
    await connecting;
    expect(diagnostics.failureStage, ConnectionStage.webSocketUpgrade);
    expect(diagnostics.failure, 'network');
    expect(diagnostics.httpStatus, 403);
    expect(diagnostics.toString(), isNot(contains('private-')));
    expect(diagnostics.toString(), isNot(contains('127.0.0.1')));
  });

  test('ClientWebSocketChannelWriteAfterCloseTest', () async {
    await establish();
    connection.closeClient();
    expect(
      () => connection.send(MqttByteBuffer.fromList([0xc0, 0])),
      throwsA(isA<SocketException>()),
    );
    expect(failures, isEmpty);
  });

  test('WebSocket close diagnostics exclude the service reason text', () async {
    final peer = await establish();
    final reason = utf8.encode('private-service-reason');
    peer.add([0x88, reason.length + 2, 3, 0xf0, ...reason]); // Close 1008.
    await peer.flush();
    await until(() => failures.isNotEmpty);
    expect(diagnostics.lastWebSocketCloseCode, 1008);
    expect(diagnostics.toString(), isNot(contains('private-service-reason')));
  });

  test(
    'WebSocket fragments and coalesced MQTT packets are decoded once',
    () async {
      final events = <ConnectAckMessageAvailable>[];
      final listener = bus.on<ConnectAckMessageAvailable>().listen(events.add);
      addTearDown(listener.cancel);
      final peer = await establish();
      peer.add([0x02, 2, 0x20, 2]); // Binary, FIN = 0.
      await peer.flush();
      await pumpEventQueue();
      expect(events, isEmpty);
      peer.add([0x80, 2, 0, 0]); // Final continuation.
      peer.add([0x82, 8, 0x20, 2, 0, 0, 0x20, 2, 0, 0]);
      await peer.flush();
      await until(() => events.length == 3);
      expect(failures, isEmpty);
    },
  );

  test('text messages retire the connection as invalid MQTT data', () async {
    final peer = await establish();
    peer.add([0x81, 2, 104, 105]);
    await peer.flush();
    await until(() => failures.isNotEmpty);
    expect(failures.single, isA<FormatException>());
  });

  test(
    'oversized WebSocket frame is rejected from its length prefix',
    () async {
      final peer = await establish();
      peer.add([0x82, 126, 0x10, 1]); // 4097 bytes, without sending the body.
      await peer.flush();
      await until(() => failures.isNotEmpty);
      expect(failures, hasLength(1));
    },
  );

  test(
    'unfinished WebSocket fragments cannot accumulate without bound',
    () async {
      final peer = await establish();
      peer.add([0x02, 126, 8, 0, ...List.filled(2048, 0)]);
      await peer.flush();
      await pumpEventQueue();
      expect(failures, isEmpty);
      peer.add([0x00, 126, 8, 0, ...List.filled(2048, 0)]);
      await peer.flush();
      await until(() => failures.isNotEmpty);
      expect(failures, hasLength(1));
    },
  );

  test(
    'outgoing WebSocket queue rejects excess bytes before submission',
    () async {
      await establish();
      connection.send(MqttByteBuffer.fromList(List.filled(3000, 0)));
      expect(
        () => connection.send(MqttByteBuffer.fromList(List.filled(3000, 0))),
        throwsStateError,
      );
      connection.closeClient(); // Also closes an active asynchronous write.
      await pumpEventQueue();
      expect(failures, isEmpty);
    },
  );

  for (final invalidProtocol in [false, true]) {
    test(
      'rejects ${invalidProtocol ? 'unoffered subprotocol' : 'invalid upgrade accept'}',
      () async {
        final connecting = expectLater(
          connection.connect('127.0.0.1', server.port),
          throwsA(isA<WebSocketException>()),
        );
        await upgrade(
          protocol: invalidProtocol ? 'other' : 'mqtt',
          validAccept: invalidProtocol,
        );
        await connecting;
      },
    );
  }

  for (final timeout in [false, true]) {
    test(
      '${timeout ? 'timeout' : 'close'} releases a stalled HTTP upgrade',
      () async {
        final time = ManualTime();
        final client = DeviceClient(
          credentials(),
          transport: MqttTransportType.webSocket,
          port: server.port,
          securityContext: clientContext(),
          schedule: time.schedule,
          connectionTimeout: const Duration(seconds: 5),
          randomInt: (_) => 20,
        );
        addTearDown(client.close);
        final opening = expectLater(
          client.open(),
          throwsA(
            failure(OperationFailureReason.closed, DeliveryState.notSubmitted),
          ),
        );
        final incoming = await request();
        expect(
          client.connectionDiagnostics.stage,
          ConnectionStage.webSocketUpgrade,
        );
        final peer = await incoming.response.detachSocket(writeHeaders: false);
        sockets.add(peer);
        final closed = Completer<void>();
        peer.listen(
          (_) {},
          onDone: closed.complete,
          onError: closed.completeError,
        );
        if (timeout) {
          time.elapse(const Duration(seconds: 5));
        } else {
          await client.close();
        }
        await closed.future.timeout(const Duration(seconds: 2));
        await client.close();
        await opening;
        expect(client.pendingCount, 0);
        expect(time.activeTimers, 0);
        if (timeout) {
          expect(client.connectionDiagnostics.failure, 'timeout');
          expect(
            client.connectionDiagnostics.failureStage,
            ConnectionStage.webSocketUpgrade,
          );
        }
      },
    );
  }
}
