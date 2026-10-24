import 'dart:async';
import 'dart:io';

import 'package:azure_iot_hub/src/transport/mqtt_transport_type.dart';
import 'package:azure_iot_hub/src/transport/owned_tls_connection.dart';
import 'package:azure_iot_hub/src/transport/owned_websocket_connection.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:test/test.dart';

void main() {
  for (final transport in MqttTransportType.values) {
    group(transport.name, () => lateSetupTest(transport));
  }
}

void lateSetupTest(MqttTransportType transport) {
  test(
    'late DNS/task completion closes an already connected socket without TLS',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = Completer<Socket>();
      final listener = server.listen(accepted.complete);
      addTearDown(() async {
        await listener.cancel();
        await server.close();
      });
      final task = await RawSocket.startConnect('127.0.0.1', server.port);
      final raw = await task.socket;
      addTearDown(raw.close);
      final peer = await accepted.future;
      addTearDown(peer.destroy);
      final received = <int>[];
      final closed = Completer<void>();
      peer.listen(received.addAll, onDone: closed.complete);

      final gate = Completer<ConnectionTask<RawSocket>>();
      final started = Completer<void>();
      Future<ConnectionTask<RawSocket>> start(String host, int port) {
        started.complete();
        return gate.future;
      }

      void failed(Object error) => fail('No unsolicited disconnect expected.');
      final MqttConnectionBase connection = switch (transport) {
        MqttTransportType.tcp => OwnedTlsConnection(
          null,
          maxBufferedBytes: 4096,
          onFailure: failed,
          startConnect: start,
        ),
        MqttTransportType.webSocket => OwnedWebSocketConnection(
          null,
          maxBufferedBytes: 4096,
          onFailure: failed,
          startConnect: start,
        ),
      };
      final connecting = expectLater(
        connection.connect('test', 8883),
        throwsA(isA<SocketException>()),
      );
      await started.future;
      connection.closeClient();
      await pumpEventQueue();
      gate.complete(task);
      await connecting;
      await closed.future.timeout(const Duration(seconds: 2));
      expect(received, isEmpty);
    },
  );
}
