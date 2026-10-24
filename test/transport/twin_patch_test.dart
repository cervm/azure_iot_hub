// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license; see third_party/azure-iot-sdk-csharp-LICENSE.
// Named cases adapt MqttTransportHandlerTests.cs at the pinned C# commit.
// Additional cases cover patch snapshots, response ordering and bounded work.
import 'dart:convert';

import 'package:azure_iot_hub/src/device_client.dart';
import 'package:azure_iot_hub/src/pending_operation.dart';
import 'package:azure_iot_hub/src/telemetry_message.dart';
import 'package:azure_iot_hub/src/transport/mqtt_transport_type.dart';
import 'package:cancellation_token/cancellation_token.dart';
import 'package:test/test.dart';

import '../prototype/support/manual_time.dart';
import '../prototype/support/mqtt_peer.dart';
import 'support/device_test_support.dart';

List<int> payload(Packet packet) =>
    packet.body.sublist(4 + utf8.encode(packet.topic).length);

Future<void> respondPatch(
  MqttPeer peer,
  Packet request, {
  int status = 204,
  String body = '',
}) => respond(peer, requestId(request), status: status, body: body);

void main() {
  for (final transport in MqttTransportType.values) {
    group(transport.name, () => transportTests(transport));
  }
}

void transportTests(MqttTransportType transport) {
  late MqttPeerServer server;
  late ManualTime time;
  late DeviceClient client;

  setUp(() async {
    server = await switch (transport) {
      MqttTransportType.tcp => MqttPeerServer.startTls(serverContext()),
      MqttTransportType.webSocket => MqttPeerServer.startWebSocket(
        serverContext(),
      ),
    };
    time = ManualTime();
    client = DeviceClient(
      credentials(),
      transport: transport,
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

  test(
    'MqttTransportHandlerSendTwinPatchAsyncTokenCancellationRequested',
    () async {
      // Cancellation precedes serialization, as in C#.
      await expectLater(
        client.updateReportedProperties({
          'invalid': Object(),
        }, cancellationToken: CancellationToken()..cancel()),
        throwsA(
          failure(OperationFailureReason.cancelled, DeliveryState.notSubmitted),
        ),
      );
      expect(server.peers, isEmpty);
    },
  );

  for (final (property, value) in [
    ('foo', 'bar'),
    ('Iso8601String', '2023-01-31T10:37:08.4599400'),
  ]) {
    test(
      'MqttTransportHandlerSendTwinPatchAsyncHappyPath: $property',
      () async {
        var completed = false;
        final patch = {property: value};
        final updating = client
            .updateReportedProperties(patch)
            .then((_) => completed = true);
        final peer = await accept();
        final request = await peer.nextPacket(3);
        expect(request.header, 0x32);
        expect(
          request.topic,
          startsWith(r'$iothub/twin/PATCH/properties/reported/?$rid='),
        );
        expect(
          requestId(request),
          matches(
            RegExp(
              r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
            ),
          ),
        );
        expect(utf8.decode(payload(request)), jsonEncode(patch));
        await peer.puback(request.packetId);
        await until(() => time.activeTimers == 3);
        expect(completed, isFalse);
        // The upstream test uses 200 with an empty body, rather than 204.
        await respondPatch(peer, request, status: 200);
        await updating;
      },
    );
  }

  test(
    'an empty patch sends an object and accepts an empty 204 response',
    () async {
      final updating = client.updateReportedProperties({});
      final peer = await accept();
      final request = await peer.nextPacket(3);
      expect(utf8.decode(payload(request)), '{}');
      await peer.puback(request.packetId);
      await respondPatch(peer, request);
      await updating;
    },
  );

  test(
    'patch snapshots preserve nested nulls, arrays and UTF-8 values',
    () async {
      final nested = <String, Object?>{
        'removed': null,
        'text': 'blå ☕',
        'number': 1.5,
      };
      final list = <Object?>[
        true,
        null,
        {'value': 3},
      ];
      final patch = <String, Object?>{
        'nested': nested,
        'array': list,
        'removed': null,
      };
      final expected = jsonEncode(patch);
      final updating = client.updateReportedProperties(patch);
      nested['removed'] = 'changed';
      list.clear();
      patch.clear();
      final peer = await accept();
      final request = await peer.nextPacket(3);
      expect(utf8.decode(payload(request)), expected);
      await peer.puback(request.packetId);
      // Successful PATCH response bodies are ignored, unlike GET bodies.
      await respondPatch(peer, request, body: 'not JSON');
      await updating;
    },
  );

  test('an early or duplicate 204 cannot complete before PUBACK', () async {
    var completed = false;
    final updating = client
        .updateReportedProperties({'value': 1})
        .then((_) => completed = true);
    final peer = await accept();
    final request = await peer.nextPacket(3);
    final pendingBytes = client.pendingBytes;
    await respondPatch(peer, request);
    await respondPatch(peer, request);
    expect(completed, isFalse);
    expect(client.pendingBytes, pendingBytes);
    await peer.puback(request.packetId);
    await updating;
  });

  for (final status in [400, 500]) {
    test(
      'MqttTransportHandlerSendTwinPatchAsyncReturnsFailure: $status',
      () async {
        final updating = expectLater(
          client.updateReportedProperties({'value': 1}),
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
        await respondPatch(
          peer,
          request,
          status: status,
          body: 'secret-property',
        );
        await updating;
        expect(client.isConnected, isTrue);
        expect(client.pendingCount, 0);
        expect(time.activeTimers, 1);
      },
    );
  }

  test(
    'GET and PATCH responses complete only their matching requests',
    () async {
      final updating = client.updateReportedProperties({'value': 1});
      final getting = client.getTwin();
      final failed = expectLater(
        client.updateReportedProperties({'value': 2}),
        throwsA(failure(OperationFailureReason.service, DeliveryState.unknown)),
      );
      final peer = await accept();
      final patch = await peer.nextPacket(3);
      final get = await peer.nextPacket(3);
      final rejected = await peer.nextPacket(3);
      expect({
        requestId(patch),
        requestId(get),
        requestId(rejected),
      }, hasLength(3));
      for (final request in [patch, get, rejected]) {
        await peer.puback(request.packetId);
      }
      await respondPatch(peer, rejected, status: 400);
      await failed;
      expect(client.pendingCount, 2);
      await respond(peer, requestId(get), body: '{"reported":{"value":0}}');
      expect((await getting).reported!['value'], 0);
      expect(client.pendingCount, 1);
      await respondPatch(peer, patch);
      await updating;
    },
  );

  test(
    '429 retries the same patch with a new ID without blocking telemetry',
    () async {
      final properties = <String, Object?>{'value': 1};
      final updating = client.updateReportedProperties(properties);
      final peer = await accept();
      final request = await peer.nextPacket(3);
      properties['value'] = 2;
      await peer.puback(request.packetId);
      await respondPatch(peer, request, status: 429);
      final sending = client.sendEvent(TelemetryMessage([42]));
      final telemetry = await peer.nextPacket(3);
      expect(telemetry.topic, startsWith('devices/device-1/messages/events/'));
      await peer.puback(telemetry.packetId);
      await sending;
      time.elapse(const Duration(milliseconds: 100));
      final retry = await peer.nextPacket(3);
      expect(requestId(retry), isNot(requestId(request)));
      expect(payload(retry), payload(request));
      await peer.puback(retry.packetId);
      await respondPatch(peer, retry);
      await updating;
      expect(server.peers, hasLength(1));
    },
  );

  test('MqttTransportHandlerSendTwinPatchAsyncTimesOut: retries within original deadline', () async {
    final updating = expectLater(
      client.updateReportedProperties({
        'value': 1,
      }, cancellationToken: CancellationToken()),
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
    expect(payload(retry), payload(request));
    await peer.puback(retry.packetId);
    await until(() => time.activeTimers == 3);
    time.elapse(const Duration(milliseconds: 29900));
    await updating;
    expect(client.isConnected, isTrue);
  });

  test(
    'reconnect resends the original patch and ignores the obsolete response',
    () async {
      final patch = <String, Object?>{'value': 1, 'removed': null};
      final updating = client.updateReportedProperties(patch);
      final first = await accept();
      final request = await first.nextPacket(3);
      patch['value'] = 2;
      await first.close();
      await until(() => !client.isConnected && time.activeTimers == 2);
      time.elapse(const Duration(milliseconds: 100));
      final replacement = await accept();
      final retry = await replacement.nextPacket(3);
      expect(requestId(retry), isNot(requestId(request)));
      expect(payload(retry), payload(request));
      await replacement.puback(retry.packetId);
      // A stale failure must not fail the new attempt.
      await respondPatch(replacement, request, status: 400);
      await respondPatch(replacement, retry);
      await updating;
    },
  );

  for (final acknowledge in [false, true]) {
    test(
      'cancellation ${acknowledge ? 'after' : 'before'} PUBACK preserves reservation rules',
      () async {
        final token = CancellationToken();
        final updating = expectLater(
          client.updateReportedProperties({
            'value': 1,
          }, cancellationToken: token),
          throwsA(
            failure(OperationFailureReason.cancelled, DeliveryState.unknown),
          ),
        );
        final peer = await accept();
        final request = await peer.nextPacket(3);
        if (acknowledge) {
          await peer.puback(request.packetId);
          await until(() => time.activeTimers == 3);
        }
        token.cancel();
        await updating;
        expect(client.pendingCount, acknowledge ? 0 : 1);
        expect(token.hasCancellables, isFalse);
        await respondPatch(peer, request);
        if (!acknowledge) await peer.puback(request.packetId);
        await until(() => client.pendingCount == 0);
        expect(client.isConnected, isTrue);
        expect(time.activeTimers, 1);
      },
    );
  }

  test(
    'a service response without PUBACK times out with unknown delivery',
    () async {
      final updating = expectLater(
        client.updateReportedProperties({'value': 1}),
        throwsA(failure(OperationFailureReason.timeout, DeliveryState.unknown)),
      );
      final peer = await accept();
      final request = await peer.nextPacket(3);
      await respondPatch(peer, request);
      time.elapse(const Duration(seconds: 90));
      await updating;
      await peer.disconnected;
    },
  );

  test(
    'serialized patch bytes count toward capacity before opening a socket',
    () async {
      await expectLater(
        client.updateReportedProperties({'value': 'x' * 2048}),
        throwsA(
          failure(OperationFailureReason.capacity, DeliveryState.notSubmitted),
        ),
      );
      expect(server.peers, isEmpty);
      expect(client.pendingCount, 0);
    },
  );

  test(
    'patches share the pending count limit with GETs and telemetry',
    () async {
      final updating = client.updateReportedProperties({'value': 1});
      final getting = client.getTwin();
      final sending = client.sendEvent(TelemetryMessage([1]));
      await expectLater(
        client.updateReportedProperties({'value': 2}),
        throwsA(
          failure(OperationFailureReason.capacity, DeliveryState.notSubmitted),
        ),
      );
      final peer = await accept();
      final patch = await peer.nextPacket(3);
      final get = await peer.nextPacket(3);
      final telemetry = await peer.nextPacket(3);
      for (final request in [patch, get, telemetry]) {
        await peer.puback(request.packetId);
      }
      await respondPatch(peer, patch);
      await respond(peer, requestId(get));
      await Future.wait<void>([updating, getting, sending]);
    },
  );

  test(
    'invalid JSON values fail before retaining work or opening a socket',
    () async {
      await expectLater(
        client.updateReportedProperties({'secret-property': Object()}),
        throwsA(
          isA<FormatException>().having((e) => e.source, 'source', isNull),
        ),
      );
      expect(server.peers, isEmpty);
      expect(client.pendingCount, 0);
    },
  );
}
