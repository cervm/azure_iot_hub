// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license; see third_party/azure-iot-sdk-csharp-LICENSE.
// Named cases adapt MqttTransportHandlerTests.cs at the pinned C# commit.
// Other cases cover Dart lifecycle races and agreed bounds/deviations.
import 'dart:convert';

import 'package:azure_iot_hub/src/device_client.dart';
import 'package:azure_iot_hub/src/pending_operation.dart';
import 'package:azure_iot_hub/src/telemetry_message.dart';
import 'package:cancellation_token/cancellation_token.dart';
import 'package:test/test.dart';

import '../prototype/support/manual_time.dart';
import '../prototype/support/mqtt_peer.dart';
import 'support/device_test_support.dart';

String requestId(Packet packet) =>
    Uri.splitQueryString(packet.topic.split('?').last)[r'$rid']!;

Future<void> respond(
  MqttPeer peer,
  String rid, {
  int status = 200,
  String body = '{"desired":{},"reported":{}}',
}) async {
  await peer.publish(
    '${r'$iothub/twin/res/'}$status/?${r'$rid='}$rid',
    utf8.encode(body),
  );
  await peer.nextPacket(4); // The client acknowledges inbound QoS 1 responses.
}

void main() {
  late MqttPeerServer server;
  late ManualTime time;
  late DeviceClient client;

  setUp(() async {
    server = await MqttPeerServer.startTls(serverContext());
    time = ManualTime();
    client = DeviceClient(
      credentials(),
      port: server.port,
      securityContext: clientContext(),
      operationTimeout: const Duration(seconds: 90),
      connectionTimeout: const Duration(seconds: 5),
      maxPending: 3,
      maxPendingBytes: 2048,
      schedule: time.schedule,
      now: () => epoch.add(time.elapsed),
      randomInt: (_) => 20,
    );
  });

  tearDown(() async {
    await client.close();
    await server.close();
    expect(client.pendingCount, 0);
    expect(client.pendingBytes, 0);
    expect(time.activeTimers, 0);
  });

  Future<MqttPeer> accept() async {
    final peer = await server.nextConnection();
    await peer.nextPacket(1);
    await peer.connack(twinResponses: true);
    return peer;
  }

  Future<MqttPeer> establish() async {
    final opening = client.open();
    final peer = await accept();
    await opening;
    return peer;
  }

  test(
    'MqttTransportHandlerSendTwinGetAsyncTokenCancellationRequested',
    () async {
      await expectLater(
        client.getTwin(cancellationToken: CancellationToken()..cancel()),
        throwsA(
          failure(OperationFailureReason.cancelled, DeliveryState.notSubmitted),
        ),
      );
      expect(server.peers, isEmpty);
    },
  );

  test('MqttTransportHandlerOpenAsyncSubscribesToTwinResultTopic', () async {
    var completed = false;
    final opening = client.open().then((_) => completed = true);
    final peer = await server.nextConnection();
    await peer.nextPacket(1);
    await peer.connack();
    final subscription = await peer.nextPacket(8);
    expect(subscription.header, 0x82);
    expect(
      utf8.decode(subscription.body.sublist(4, subscription.body.length - 1)),
      r'$iothub/twin/res/#',
    );
    expect(subscription.body.last, 1);
    expect(completed, isFalse);
    final id = (subscription.body[0] << 8) | subscription.body[1];
    await peer.suback(id + 1);
    expect(completed, isFalse);
    await peer.suback(id);
    await opening;
    expect(client.isConnected, isTrue);
  });

  for (final (property, value) in [
    ('foo', 'bar'),
    ('Iso8601String', '2023-01-31T10:37:08.4599400'),
  ]) {
    test('MqttTransportHandlerSendTwinGetAsyncHappyPath: $property', () async {
      var completed = false;
      final getting = client.getTwin().then((twin) {
        completed = true;
        return twin;
      });
      final peer = await accept();
      final request = await peer.nextPacket(3);
      expect(request.header, 0x32);
      expect(request.topic, startsWith(r'$iothub/twin/GET/?$rid='));
      expect(
        requestId(request),
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
      expect(request.body.length, utf8.encode(request.topic).length + 4);
      await peer.puback(request.packetId);
      await until(() => time.activeTimers == 3);
      expect(completed, isFalse);
      await respond(
        peer,
        requestId(request),
        body: jsonEncode({
          'desired': {property: value},
          'reported': {},
        }),
      );
      final twin = await getting;
      expect(twin.desired![property], value);
      expect(twin.reported, isEmpty);
    });
  }

  test(
    'response before PUBACK is retained and does not complete early',
    () async {
      var completed = false;
      final getting = client.getTwin().then((twin) {
        completed = true;
        return twin;
      });
      final peer = await accept();
      final request = await peer.nextPacket(3);
      final pendingBytes = client.pendingBytes;
      await respond(peer, requestId(request), body: '{"desired":{"value":1}}');
      await until(() => client.pendingBytes > pendingBytes);
      final retainedBytes = client.pendingBytes;
      await respond(peer, requestId(request), body: '{"desired":{"value":2}}');
      expect(client.pendingBytes, retainedBytes);
      expect(completed, isFalse);
      await peer.puback(request.packetId);
      expect((await getting).desired!['value'], 1);
      expect(client.pendingBytes, 0);
    },
  );

  test(
    'concurrent GETs correlate out-of-order responses and ignore unknown IDs',
    () async {
      final peer = await establish();
      final first = client.getTwin();
      final second = client.getTwin();
      final a = await peer.nextPacket(3);
      final b = await peer.nextPacket(3);
      expect(requestId(a), isNot(requestId(b)));
      await peer.puback(a.packetId);
      await peer.puback(b.packetId);
      await respond(peer, 'unknown', body: '{"desired":{"value":0}}');
      await respond(peer, requestId(b), body: '{"desired":{"value":2}}');
      expect((await second).desired!['value'], 2);
      expect(client.pendingCount, 1);
      await respond(peer, requestId(a), body: '{"desired":{"value":1}}');
      expect((await first).desired!['value'], 1);
    },
  );

  for (final status in [400, 500]) {
    test(
      'MqttTransportHandlerSendTwinGetAsyncReturnsFailure: $status',
      () async {
        final getting = expectLater(
          client.getTwin(),
          throwsA(
            isA<OperationFailure>()
                .having(
                  (e) => e.reason,
                  'reason',
                  OperationFailureReason.service,
                )
                .having((e) => e.statusCode, 'statusCode', status)
                .having(
                  (e) => e.toString(),
                  'diagnostic',
                  isNot(contains('secret-property')),
                ),
          ),
        );
        final peer = await accept();
        final request = await peer.nextPacket(3);
        await peer.puback(request.packetId);
        await respond(
          peer,
          requestId(request),
          status: status,
          body: 'secret-property',
        );
        await getting;
        time.elapse(const Duration(seconds: 1));
        expect(client.pendingCount, 0);
        expect(client.isConnected, isTrue);
        expect(server.peers, hasLength(1));
      },
    );
  }

  test(
    '429 retries on the same connection with a new request ID and backoff',
    () async {
      final getting = client.getTwin();
      final peer = await accept();
      final request = await peer.nextPacket(3);
      await peer.puback(request.packetId);
      await respond(peer, requestId(request), status: 429);
      await until(() => time.activeTimers == 3);
      time.elapse(const Duration(milliseconds: 100));
      final retry = await peer.nextPacket(3);
      expect(requestId(retry), isNot(requestId(request)));
      await peer.puback(retry.packetId);
      await respond(peer, requestId(retry));
      await getting;
      expect(server.peers, hasLength(1));
    },
  );

  test('MqttTransportHandlerSendTwinGetAsyncTimesOut: retries within original deadline', () async {
    final getting = expectLater(
      client.getTwin(),
      throwsA(failure(OperationFailureReason.timeout, DeliveryState.unknown)),
    );
    final peer = await accept();
    final request = await peer.nextPacket(3);
    await peer.puback(request.packetId);
    await until(() => time.activeTimers == 3);
    time.elapse(const Duration(seconds: 60));
    time.elapse(const Duration(milliseconds: 100));
    final retry = await peer.nextPacket(3);
    expect(requestId(retry), isNot(requestId(request)));
    await peer.puback(retry.packetId);
    await until(() => time.activeTimers == 3);
    time.elapse(const Duration(milliseconds: 29900));
    await getting;
    expect(client.isConnected, isTrue);
  });

  test('reconnect resubscribes and discards old request IDs', () async {
    final getting = client.getTwin();
    final first = await accept();
    final request = await first.nextPacket(3);
    await first.puback(request.packetId);
    await first.close();
    await until(() => !client.isConnected && time.activeTimers == 2);
    time.elapse(const Duration(milliseconds: 100));
    final replacement = await accept();
    final retried = await replacement.nextPacket(3);
    expect(requestId(retried), isNot(requestId(request)));
    await replacement.puback(retried.packetId);
    await respond(
      replacement,
      requestId(request),
      body: '{"desired":{"value":0}}',
    );
    await respond(
      replacement,
      requestId(retried),
      body: '{"desired":{"value":1}}',
    );
    expect((await getting).desired!['value'], 1);
  });

  test(
    'cancellation after PUBACK releases the request and ignores late responses',
    () async {
      final token = CancellationToken();
      final getting = expectLater(
        client.getTwin(cancellationToken: token),
        throwsA(
          failure(OperationFailureReason.cancelled, DeliveryState.unknown),
        ),
      );
      final peer = await accept();
      final request = await peer.nextPacket(3);
      await peer.puback(request.packetId);
      await until(() => time.activeTimers == 3);
      token.cancel();
      await getting;
      expect(client.pendingCount, 0);
      expect(token.hasCancellables, isFalse);
      await respond(peer, requestId(request));
      final sending = client.sendEvent(TelemetryMessage([1]));
      final publish = await peer.nextPacket(3);
      await peer.puback(publish.packetId);
      await sending;
      expect(client.isConnected, isTrue);
    },
  );

  test(
    'cancellation before PUBACK retains only the MQTT reservation',
    () async {
      final token = CancellationToken();
      final getting = expectLater(
        client.getTwin(cancellationToken: token),
        throwsA(
          failure(OperationFailureReason.cancelled, DeliveryState.unknown),
        ),
      );
      final peer = await accept();
      final request = await peer.nextPacket(3);
      token.cancel();
      await getting;
      expect(client.pendingCount, 1);
      await respond(peer, requestId(request));
      await peer.puback(request.packetId);
      await until(() => client.pendingCount == 0);
      expect(time.activeTimers, 1);
    },
  );

  test(
    'invalid JSON fails only its request without disclosing the response',
    () async {
      final getting = expectLater(
        client.getTwin(),
        throwsA(
          failure(OperationFailureReason.protocol, DeliveryState.unknown),
        ),
      );
      final peer = await accept();
      final request = await peer.nextPacket(3);
      await peer.puback(request.packetId);
      await respond(
        peer,
        requestId(request),
        body: 'secret-property: invalid JSON',
      );
      await getting;
      expect(client.isConnected, isTrue);
      expect(client.pendingCount, 0);
    },
  );

  test('early response bytes share the pending byte limit', () async {
    final getting = expectLater(
      client.getTwin(),
      throwsA(failure(OperationFailureReason.capacity, DeliveryState.unknown)),
    );
    final peer = await accept();
    final request = await peer.nextPacket(3);
    await respond(peer, requestId(request), body: 'x' * 2048);
    await getting;
    expect(client.pendingBytes, lessThan(2048));
    expect(client.pendingCount, 1);
    await peer.puback(request.packetId);
    await until(() => client.pendingCount == 0);
  });

  test('twin requests share the pending count limit with telemetry', () async {
    final peer = await establish();
    final requests = [for (var i = 0; i < 3; i++) client.getTwin()];
    final packets = [for (var i = 0; i < 3; i++) await peer.nextPacket(3)];
    await expectLater(
      client.sendEvent(TelemetryMessage([1])),
      throwsA(
        failure(OperationFailureReason.capacity, DeliveryState.notSubmitted),
      ),
    );
    for (final request in packets) {
      await peer.puback(request.packetId);
      await respond(peer, requestId(request));
    }
    await Future.wait(requests);
  });

  test('rejected twin subscription fails open and stops recovery', () async {
    final opening = expectLater(
      client.open(),
      throwsA(
        failure(OperationFailureReason.protocol, DeliveryState.notSubmitted),
      ),
    );
    final peer = await server.nextConnection();
    await peer.nextPacket(1);
    await peer.connack();
    final subscription = await peer.nextPacket(8);
    await peer.suback(
      (subscription.body[0] << 8) | subscription.body[1],
      qos: 128,
    );
    await opening;
    await peer.disconnected;
    expect(time.activeTimers, 0);
    expect(client.isConnected, isFalse);
  });

  test('connection deadline bounds a missing SUBACK', () async {
    final opening = expectLater(
      client.open(),
      throwsA(
        failure(OperationFailureReason.closed, DeliveryState.notSubmitted),
      ),
    );
    final peer = await server.nextConnection();
    await peer.nextPacket(1);
    await peer.connack();
    await peer.nextPacket(8);
    time.elapse(const Duration(seconds: 5));
    await peer.disconnected;
    await client.close();
    await opening;
  });

  test(
    'close while awaiting a twin response settles and releases everything',
    () async {
      final getting = expectLater(
        client.getTwin(),
        throwsA(failure(OperationFailureReason.closed, DeliveryState.unknown)),
      );
      final peer = await accept();
      final request = await peer.nextPacket(3);
      await peer.puback(request.packetId);
      await until(() => time.activeTimers == 3);
      await client.close();
      await getting;
      await peer.disconnected;
    },
  );

  test(
    'a response without PUBACK cannot escape the original deadline',
    () async {
      final getting = expectLater(
        client.getTwin(),
        throwsA(failure(OperationFailureReason.timeout, DeliveryState.unknown)),
      );
      final peer = await accept();
      final request = await peer.nextPacket(3);
      await respond(peer, requestId(request));
      time.elapse(const Duration(seconds: 90));
      await getting;
      await peer.disconnected;
      expect(client.pendingBytes, 0);
    },
  );

  test(
    'reconnect does not restart a twin GET deadline with a caller token',
    () async {
      final getting = expectLater(
        client.getTwin(cancellationToken: CancellationToken()),
        throwsA(failure(OperationFailureReason.timeout, DeliveryState.unknown)),
      );
      final first = await accept();
      await first.nextPacket(3);
      time.elapse(const Duration(seconds: 6));
      await first.close();
      await until(() => !client.isConnected && time.activeTimers == 2);
      time.elapse(const Duration(milliseconds: 100));
      final replacement = await accept();
      await replacement.nextPacket(3);
      time.elapse(const Duration(milliseconds: 83900));
      await getting;
      await replacement.disconnected;
    },
  );

  test('cancelling one twin GET leaves another request and its subscription active', () async {
    final peer = await establish();
    final token = CancellationToken();
    final cancelled = expectLater(
      client.getTwin(cancellationToken: token),
      throwsA(failure(OperationFailureReason.cancelled, DeliveryState.unknown)),
    );
    final getting = client.getTwin();
    final a = await peer.nextPacket(3);
    final b = await peer.nextPacket(3);
    token.cancel();
    await cancelled;
    await peer.puback(b.packetId);
    await respond(peer, requestId(b));
    await getting;
    expect(client.isConnected, isTrue);
    expect(client.pendingCount, 1);
    await peer.puback(a.packetId);
    await until(() => client.pendingCount == 0);
  });
}
