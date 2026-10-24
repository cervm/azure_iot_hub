// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license; see third_party/azure-iot-sdk-csharp-LICENSE.
// Named cases adapt DeviceClientTwinApiTests and MqttTransportHandlerTests.
// See docs/upstream.md for the pinned reference and Dart lifecycle additions.
import 'dart:async';
import 'dart:convert';

import 'package:azure_iot_hub/src/device_client.dart';
import 'package:azure_iot_hub/src/pending_operation.dart';
import 'package:azure_iot_hub/src/telemetry_message.dart';
import 'package:azure_iot_hub/src/transport/mqtt_transport_type.dart';
import 'package:azure_iot_hub/src/twin.dart';
import 'package:cancellation_token/cancellation_token.dart';
import 'package:test/test.dart';

import '../prototype/support/manual_time.dart';
import '../prototype/support/mqtt_peer.dart';
import 'support/device_test_support.dart';

int controlId(Packet packet) => (packet.body[0] << 8) | packet.body[1];

Future<int> desiredControl(MqttPeer peer, {bool subscribe = true}) async {
  final packet = await peer.nextPacket(subscribe ? 8 : 10);
  final length = (packet.body[2] << 8) | packet.body[3];
  expect(
    utf8.decode(packet.body.sublist(4, 4 + length)),
    r'$iothub/twin/PATCH/properties/desired/#',
  );
  if (subscribe) expect(packet.body.last, 1);
  return controlId(packet);
}

Future<void> notifyPatch(
  MqttPeer peer,
  Map<String, Object?> patch, {
  int id = 1,
}) async {
  await peer.publish(
    '${r'$iothub/twin/PATCH/properties/desired/?$version='}${patch[r'$version'] ?? 1}',
    utf8.encode(jsonEncode(patch)),
    id: id,
  );
  expect(controlId(await peer.nextPacket(4)), id);
}

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
      operationTimeout: const Duration(seconds: 10),
      connectionTimeout: const Duration(seconds: 5),
      maxPending: 3,
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

  Future<MqttPeer> register(DesiredPropertyUpdateCallback callback) async {
    final registering = client.setDesiredPropertyUpdateCallback(callback);
    final peer = await accept();
    await peer.suback(await desiredControl(peer));
    await registering;
    return peer;
  }

  test(
    'MqttTransportHandlerEnableTwinPatchAsyncTokenCancellationRequested',
    () async {
      await expectLater(
        client.setDesiredPropertyUpdateCallback(
          (_) {},
          cancellationToken: CancellationToken()..cancel(),
        ),
        throwsA(
          failure(OperationFailureReason.cancelled, DeliveryState.notSubmitted),
        ),
      );
      expect(server.peers, isEmpty);
    },
  );

  test('DeviceClientSetDesiredPropertyUpdateCallbackAsyncRegistersForPatchesOnFirstCall', () async {
    var completed = false;
    final registering = client
        .setDesiredPropertyUpdateCallback((_) {})
        .then((_) => completed = true);
    final peer = await accept();
    final id = await desiredControl(peer);
    expect(completed, isFalse);
    // An unrelated SUBACK must not complete this registration.
    await peer.suback(id + 1);
    await notifyPatch(peer, {'ignoredBeforeRegistration': true});
    expect(completed, isFalse);
    await peer.suback(id);
    await registering;
    expect(client.pendingCount, 0);
  });

  test('DeviceClientCallbackAsyncIsCalledWhenPatchIsReceived', () async {
    final received = <Map<String, Object?>>[];
    final peer = await register(received.add);
    final patch = <String, Object?>{
      'nested': {'removed': null, 'number': 1.5},
      'list': [true, null, 'blå ☕'],
      'Iso8601String': '2023-01-31T10:37:08.4599400',
      r'$version': 9,
      r'$metadata': {r'$lastUpdated': '2026-10-24T00:00:00Z'},
    };
    await notifyPatch(peer, patch);
    // Receipt of PUBACK proves dispatch has already happened.
    expect(received, [patch]);
  });

  test('DeviceClientSetDesiredPropertyUpdateCallbackAsyncDoesNotRegisterForPatchesAfterFirstCall', () async {
    var oldCalls = 0;
    var newCalls = 0;
    final peer = await register((_) => oldCalls++);
    await client.setDesiredPropertyUpdateCallback((_) => newCalls++);
    // A second SUBSCRIBE would appear before this PUBACK and fail the test.
    await notifyPatch(peer, {'value': 1});
    expect(oldCalls, 0);
    expect(newCalls, 1);
  });

  test('DeviceClientDesiredPropertyUpdateCallbackUnsubscribes', () async {
    var calls = 0;
    final peer = await register((_) => calls++);
    var completed = false;
    final removing = client
        .setDesiredPropertyUpdateCallback(null)
        .then((_) => completed = true);
    final id = await desiredControl(peer, subscribe: false);
    await peer.unsuback(id + 1);
    await notifyPatch(peer, {'beforeUnsuback': true});
    expect(completed, isFalse);
    expect(calls, 1);
    await peer.unsuback(id);
    await removing;
    await notifyPatch(peer, {'afterUnsuback': true});
    expect(calls, 1);
  });

  test('clearing an absent callback does not connect', () async {
    await client.setDesiredPropertyUpdateCallback(null);
    expect(server.peers, isEmpty);
    expect(time.activeTimers, 0);
  });

  test('re-registering after removal subscribes again: agreed C# defect correction', () async {
    final peer = await register((_) {});
    final removing = client.setDesiredPropertyUpdateCallback(null);
    await peer.unsuback(await desiredControl(peer, subscribe: false));
    await removing;
    var calls = 0;
    final registering = client.setDesiredPropertyUpdateCallback((_) => calls++);
    await peer.suback(await desiredControl(peer));
    await registering;
    await notifyPatch(peer, {'value': 2});
    expect(calls, 1);
  });

  test('patches are forwarded without merging or version filtering', () async {
    final received = <Map<String, Object?>>[];
    final peer = await register(received.add);
    for (final version in [4, 4, 2, 8]) {
      await notifyPatch(peer, {'removed': null, r'$version': version});
    }
    expect(received, [
      for (final version in [4, 4, 2, 8])
        {'removed': null, r'$version': version},
    ]);
  });

  test('PUBACK does not wait for asynchronous application work', () async {
    final work = Completer<void>();
    var started = false;
    var finished = false;
    final peer = await register((_) async {
      started = true;
      await work.future;
      finished = true;
    });
    await notifyPatch(peer, {'value': 1});
    expect(started, isTrue);
    expect(finished, isFalse);
    work.complete();
    await until(() => finished);
  });

  test(
    'reconnect restores subscriptions before sends without fetching a snapshot',
    () async {
      final received = <Map<String, Object?>>[];
      final first = await register(received.add);
      await first.close();
      await until(() => !client.isConnected && time.activeTimers == 1);
      var sent = false;
      final sending = client
          .sendEvent(TelemetryMessage([42]))
          .then((_) => sent = true);
      time.elapse(const Duration(milliseconds: 100));
      final replacement = await accept();
      final subscription = await desiredControl(replacement);
      expect(client.isConnected, isFalse);
      expect(sent, isFalse);
      await replacement.suback(subscription);
      final telemetry = await replacement.nextPacket(3);
      expect(telemetry.topic, startsWith('devices/device-1/messages/events/'));
      await replacement.puback(telemetry.packetId);
      await sending;
      // Any automatic twin GET would appear before the notification's PUBACK.
      await notifyPatch(replacement, {'onlyPatch': true, r'$version': 5});
      expect(received, [
        {'onlyPatch': true, r'$version': 5},
      ]);
    },
  );

  test(
    'concurrent registrations serialize and share the pending count limit',
    () async {
      final calls = <String>[];
      final first = client.setDesiredPropertyUpdateCallback(
        (_) => calls.add('first'),
      );
      final removing = client.setDesiredPropertyUpdateCallback(null);
      final last = client.setDesiredPropertyUpdateCallback(
        (_) => calls.add('last'),
      );
      await expectLater(
        client.sendEvent(TelemetryMessage([42])),
        throwsA(
          failure(OperationFailureReason.capacity, DeliveryState.notSubmitted),
        ),
      );
      final peer = await accept();
      await peer.suback(await desiredControl(peer));
      await first;
      await peer.unsuback(await desiredControl(peer, subscribe: false));
      await removing;
      await peer.suback(await desiredControl(peer));
      await last;
      await notifyPatch(peer, {'value': 1});
      expect(calls, ['last']);
    },
  );

  for (final removing in [false, true]) {
    test(
      'cancelled ${removing ? 'removal' : 'registration'} retains its reservation until ACK and restores committed state',
      () async {
        var calls = 0;
        MqttPeer? peer;
        if (removing) peer = await register((_) => calls++);
        final token = CancellationToken();
        final cancelled = expectLater(
          client.setDesiredPropertyUpdateCallback(
            removing ? null : (_) => calls++,
            cancellationToken: token,
          ),
          throwsA(
            failure(OperationFailureReason.cancelled, DeliveryState.unknown),
          ),
        );
        peer ??= await accept();
        final id = await desiredControl(peer, subscribe: !removing);
        token.cancel();
        await cancelled;
        expect(client.pendingCount, 1);
        expect(token.hasCancellables, isFalse);
        if (removing) {
          await peer.unsuback(id);
          await peer.suback(await desiredControl(peer));
        } else {
          await peer.suback(id);
          await peer.unsuback(await desiredControl(peer, subscribe: false));
        }
        await notifyPatch(peer, {'value': 1});
        expect(calls, removing ? 1 : 0);
        expect(client.pendingCount, 0);
        expect(time.activeTimers, 1);
      },
    );
  }

  test('queued cancellation does not affect the active registration', () async {
    var calls = 0;
    final registering = client.setDesiredPropertyUpdateCallback((_) => calls++);
    final token = CancellationToken();
    final cancelled = expectLater(
      client.setDesiredPropertyUpdateCallback(null, cancellationToken: token),
      throwsA(
        failure(OperationFailureReason.cancelled, DeliveryState.notSubmitted),
      ),
    );
    final peer = await accept();
    final id = await desiredControl(peer);
    token.cancel();
    await cancelled;
    expect(client.pendingCount, 1);
    await peer.suback(id);
    await registering;
    await notifyPatch(peer, {'value': 1});
    expect(calls, 1);
  });

  for (final acknowledged in [false, true]) {
    test(
      'cancelled registration cleanup is bounded ${acknowledged ? 'after' : 'before'} SUBACK',
      () async {
        final token = CancellationToken();
        final cancelled = expectLater(
          client.setDesiredPropertyUpdateCallback(
            (_) {},
            cancellationToken: token,
          ),
          throwsA(
            failure(OperationFailureReason.cancelled, DeliveryState.unknown),
          ),
        );
        final peer = await accept();
        final id = await desiredControl(peer);
        token.cancel();
        await cancelled;
        if (acknowledged) {
          await peer.suback(id);
          await desiredControl(peer, subscribe: false);
          expect(client.pendingCount, 0);
          time.elapse(const Duration(seconds: 5));
        } else {
          expect(client.pendingCount, 1);
          time.elapse(const Duration(seconds: 10));
        }
        await peer.disconnected;
        expect(client.pendingCount, 0);
        expect(client.isConnected, isFalse);
      },
    );
  }

  test(
    'subscription recovery has a deadline without any caller operation',
    () async {
      final first = await register((_) {});
      await first.close();
      await until(() => !client.isConnected && time.activeTimers == 1);
      time.elapse(const Duration(milliseconds: 100));
      final second = await accept();
      await desiredControl(second);
      expect(client.pendingCount, 0);
      expect(client.isConnected, isFalse);
      time.elapse(const Duration(seconds: 5));
      await second.disconnected;
      expect(client.isConnected, isFalse);
    },
  );

  test('MqttTransportHandlerEnableTwinPatchAsyncTimesOut: missing SUBACK retires the connection', () async {
    final registering = expectLater(
      client.setDesiredPropertyUpdateCallback(
        (_) {},
        cancellationToken: CancellationToken(),
      ),
      throwsA(failure(OperationFailureReason.timeout, DeliveryState.unknown)),
    );
    final peer = await accept();
    await desiredControl(peer);
    time.elapse(const Duration(seconds: 10));
    await registering;
    await peer.disconnected;
    expect(client.pendingCount, 0);
    expect(client.isConnected, isFalse);
  });

  test('reconnect does not restart a pending registration deadline', () async {
    final registering = expectLater(
      client.setDesiredPropertyUpdateCallback((_) {}),
      throwsA(failure(OperationFailureReason.timeout, DeliveryState.unknown)),
    );
    final first = await accept();
    await desiredControl(first);
    time.elapse(const Duration(seconds: 6));
    await first.close();
    await until(() => !client.isConnected && time.activeTimers == 2);
    time.elapse(const Duration(milliseconds: 100));
    final second = await accept();
    await desiredControl(second);
    time.elapse(const Duration(milliseconds: 3900));
    await registering;
    await second.disconnected;
  });

  test(
    'rejected desired SUBACK fails registration with a protocol error',
    () async {
      final registering = expectLater(
        client.setDesiredPropertyUpdateCallback((_) {}),
        throwsA(
          failure(OperationFailureReason.protocol, DeliveryState.unknown),
        ),
      );
      final peer = await accept();
      await peer.suback(await desiredControl(peer), qos: 0x80);
      await registering;
      await peer.disconnected;
      expect(time.activeTimers, 0);
    },
  );

  for (final malformed in [false, true]) {
    test(
      '${malformed ? 'malformed JSON' : 'synchronous callback failure'} retires without ACK and recovers',
      () async {
        var calls = 0;
        final first = await register((_) {
          if (!malformed && calls++ == 0) throw StateError('secret-property');
        });
        await first.publish(
          r'$iothub/twin/PATCH/properties/desired/?$version=1',
          utf8.encode(malformed ? 'secret-property' : '{}'),
        );
        await first.disconnected;
        await expectLater(first.nextPacket(4), throwsStateError);
        await until(() => time.activeTimers == 1);
        time.elapse(const Duration(milliseconds: 100));
        final second = await accept();
        await second.suback(await desiredControl(second));
        await notifyPatch(second, {'value': 2});
        expect(client.isConnected, isTrue);
      },
    );
  }

  test('closing inside a callback prevents a stale PUBACK', () async {
    var calls = 0;
    final peer = await register((_) {
      calls++;
      unawaited(client.close());
    });
    await peer.publish(
      r'$iothub/twin/PATCH/properties/desired/?$version=1',
      utf8.encode('{}'),
    );
    await peer.disconnected;
    await expectLater(peer.nextPacket(4), throwsStateError);
    expect(calls, 1);
    expect(time.activeTimers, 0);
  });

  test('close settles an active and a queued registration', () async {
    final first = expectLater(
      client.setDesiredPropertyUpdateCallback((_) {}),
      throwsA(failure(OperationFailureReason.closed, DeliveryState.unknown)),
    );
    final second = expectLater(
      client.setDesiredPropertyUpdateCallback(null),
      throwsA(
        failure(OperationFailureReason.closed, DeliveryState.notSubmitted),
      ),
    );
    final peer = await accept();
    await desiredControl(peer);
    await client.close();
    await Future.wait([first, second]);
    await peer.disconnected;
    expect(time.activeTimers, 0);
  });
}
