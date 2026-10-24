import 'dart:async';
import 'dart:io';

import 'package:azure_iot_hub/src/transport/owned_tls_connection.dart';
import 'package:test/test.dart';

void main() {
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
      final connection = OwnedTlsConnection(
        null,
        maxBufferedBytes: 4096,
        onFailure: (_) => fail('No unsolicited disconnect expected.'),
        startConnect: (_, _) => gate.future,
      );
      final connecting = expectLater(
        connection.connect('test', 8883),
        throwsA(isA<SocketException>()),
      );
      connection.closeClient();
      gate.complete(task);
      await connecting;
      await closed.future.timeout(const Duration(seconds: 2));
      expect(received, isEmpty);
    },
  );
}
