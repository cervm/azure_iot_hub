// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license; see third_party/azure-iot-sdk-csharp-LICENSE.
// Named cases adapt DeviceClientTests and RetryDelegatingHandlerTests at the
// pinned C# commit; other cases cover Dart lifecycle races and agreed deviations.
import 'dart:async';
import 'dart:io';

import 'package:azure_iot_hub/azure_iot_hub.dart';
import 'package:azure_iot_hub/src/authentication/iot_hub_connection_string.dart';
import 'package:azure_iot_hub/src/internal_client.dart';
import 'package:test/test.dart';

import '../prototype/support/manual_time.dart';
import '../prototype/support/mqtt_peer.dart';
import 'support/device_test_support.dart';

typedef StatusChange = (ConnectionStatus, ConnectionStatusChangeReason);

const StatusChange connected = (.connected, .connectionOk);
const StatusChange retrying = (.disconnectedRetrying, .communicationError);
const StatusChange disabled = (.disabled, .clientClose);
const StatusChange badCredential = (.disconnected, .badCredential);
const StatusChange communicationError = (.disconnected, .communicationError);

void main() {
  for (final transport in MqttTransportType.values) {
    group(transport.name, () => transportTests(transport));
  }
}

void transportTests(MqttTransportType transport) {
  late MqttPeerServer server;
  late ManualTime time;
  late InternalClient client;
  late List<StatusChange> changes;

  void record(ConnectionStatus status, ConnectionStatusChangeReason reason) =>
      changes.add((status, reason));

  InternalClient createClient({
    IotHubConnectionString? authentication,
    SecurityContext? context,
  }) => InternalClient(
    authentication ?? credentials(),
    transport: transport,
    port: server.port,
    securityContext: context ?? clientContext(),
    operationTimeout: const .new(seconds: 10),
    connectionTimeout: const .new(seconds: 5),
    maxPending: 3,
    schedule: time.schedule,
    now: () => epoch.add(time.elapsed),
    randomInt: (_) => 20,
  );

  setUp(() async {
    server = await switch (transport) {
      .tcp => MqttPeerServer.startTls(serverContext()),
      .webSocket => MqttPeerServer.startWebSocket(serverContext()),
    };
    time = ManualTime();
    changes = [];
    client = createClient()..setConnectionStatusChangesHandler(record);
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
    return peer;
  }

  Future<MqttPeer> establish() async {
    final opening = client.open();
    final peer = await accept();
    await peer.connack(twinResponses: true);
    await opening;
    return peer;
  }

  Future<MqttPeer> retry({
    Duration delay = const .new(milliseconds: 100),
  }) async {
    await until(() => time.activeTimers == client.pendingCount + 1);
    time.elapse(delay);
    return accept();
  }

  test('DeviceClientOnConnectionOpenedInvokeHandlerForStatusChange', () async {
    expect(changes, isEmpty);
    final opening = client.open();
    final peer = await accept();
    await peer.connack();
    final subscription = await peer.nextPacket(8);
    expect(changes, isEmpty);
    expect(client.isConnected, isFalse);
    await peer.suback((subscription.body[0] << 8) | subscription.body[1]);
    await opening;
    expect(changes, [connected]);
  });

  test('DeviceClientOnConnectionOpenedWithNullHandler', () async {
    client.setConnectionStatusChangesHandler(null);
    await establish();
    expect(changes, isEmpty);
  });

  test(
    'DeviceClientOnConnectionOpenedNotInvokeHandlerWithoutStatusChange',
    () async {
      await establish();
      await client.open();
      await client.open();
      expect(changes, [connected]);
    },
  );

  test(
    'registration replaces without replay and removal still tracks state',
    () async {
      final peer = await establish();
      final replacement = <StatusChange>[];
      client.setConnectionStatusChangesHandler((status, reason) {
        replacement.add((status, reason));
      });
      expect(replacement, isEmpty);
      await client.open();
      expect(replacement, isEmpty);
      client.setConnectionStatusChangesHandler(null);
      await peer.close();
      await until(() => !client.isConnected);
      final next = await retry();
      await next.connack(twinResponses: true);
      await until(() => client.isConnected);
      client.setConnectionStatusChangesHandler(record);
      await client.open();
      expect(changes, [connected]);
      expect(replacement, isEmpty);
    },
  );

  test(
    'DeviceClientOnConnectionClosedInvokeHandlerAndRecoveryForStatusChange',
    () async {
      final peer = await establish();
      await peer.close();
      await until(() => changes.length == 2);
      expect(changes, [connected, retrying]);
      final next = await retry();
      await next.connack(twinResponses: true);
      await until(() => client.isConnected);
      expect(changes, [connected, retrying, connected]);
    },
  );

  test('RetryDelegatingHandler_OpenAsyncRetries', () async {
    final opening = client.open();
    final first = await accept();
    await first.connack(code: 3);
    await until(() => changes.isNotEmpty);
    expect(changes, [retrying]);
    final second = await retry();
    await second.connack(code: 3);
    await second.disconnected;
    final third = await retry(delay: const .new(milliseconds: 200));
    expect(changes, [retrying]);
    await third.connack(twinResponses: true);
    await opening;
    expect(changes, [retrying, connected]);
  });

  for (final (code, reason, event) in [
    (4, OperationFailureReason.authentication, badCredential),
    (5, OperationFailureReason.authentication, badCredential),
    (1, OperationFailureReason.protocol, communicationError),
  ]) {
    test(
      'terminal CONNACK $code reports a supported reason and stops retry',
      () async {
        final opening = expectLater(
          client.open(),
          throwsA(failure(reason, .notSubmitted)),
        );
        final peer = await accept();
        await peer.connack(code: code);
        await opening;
        await until(() => time.activeTimers == 0);
        expect(changes, [event]);
        expect(client.isConnected, isFalse);
      },
    );
  }

  test(
    'reason changes notify even when the disconnected status is unchanged',
    () async {
      for (final code in [5, 1]) {
        final opening = expectLater(
          client.open(),
          throwsA(isA<OperationFailure>()),
        );
        final peer = await accept();
        await peer.connack(code: code);
        await opening;
        await pumpEventQueue();
      }
      expect(changes, [badCredential, communicationError]);
    },
  );

  test(
    'rejected twin subscription reports disconnected and never connected',
    () async {
      final opening = expectLater(
        client.open(),
        throwsA(failure(.protocol, .notSubmitted)),
      );
      final peer = await accept();
      await peer.connack();
      final subscription = await peer.nextPacket(8);
      await peer.suback(
        (subscription.body[0] << 8) | subscription.body[1],
        qos: 128,
      );
      await opening;
      expect(changes, [communicationError]);
      expect(client.isConnected, isFalse);
    },
  );

  test('TLS verification failure reports communicationError', () async {
    await client.close();
    changes.clear();
    client = createClient(context: SecurityContext())
      ..setConnectionStatusChangesHandler(record);
    await expectLater(client.open(), throwsA(failure(.tls, .notSubmitted)));
    expect(changes, [communicationError]);
  });

  test(
    'reconnect reports connected only after desired subscription recovery',
    () async {
      final registering = client.setDesiredPropertyUpdateCallback((_) {});
      final first = await accept();
      await first.connack(twinResponses: true);
      var subscription = await first.nextPacket(8);
      await first.suback((subscription.body[0] << 8) | subscription.body[1]);
      await registering;
      await first.close();
      await until(() => changes.length == 2);
      final next = await retry();
      await next.connack(twinResponses: true);
      subscription = await next.nextPacket(8);
      expect(changes, [connected, retrying]);
      expect(client.isConnected, isFalse);
      await next.suback((subscription.body[0] << 8) | subscription.body[1]);
      await until(() => client.isConnected);
      expect(changes, [connected, retrying, connected]);
    },
  );

  test(
    'caller cancellation and a twin service error do not disconnect the client',
    () async {
      final peer = await establish();
      final source = CancellationTokenSource();
      final sending = expectLater(
        client.sendEvent(.new([1]), cancellationToken: source.token),
        throwsA(failure(.cancelled, .unknown)),
      );
      final publish = await peer.nextPacket(3);
      source.cancel();
      await sending;
      await peer.puback(publish.packetId);
      final getting = expectLater(
        client.getTwin(),
        throwsA(failure(.service, .unknown)),
      );
      final request = await peer.nextPacket(3);
      await peer.puback(request.packetId);
      await respond(peer, requestId(request), status: 403, body: '');
      await getting;
      expect(client.isConnected, isTrue);
      expect(changes, [connected]);
    },
  );

  test('an operation deadline during recovery does not report retry exhaustion', () async {
    final peer = await establish();
    final getting = expectLater(
      client.getTwin(),
      throwsA(failure(.timeout, .unknown)),
    );
    await peer.nextPacket(3);
    await peer.close();
    await until(() => changes.length == 2);
    // Leave the next connection attempt's microtask pending until the caller's
    // deadline has elapsed. The connection's recovery lifetime is independent.
    time.elapse(const .new(seconds: 10));
    await getting;
    expect(changes, [connected, retrying]);
  });

  test(
    'handler errors go to its registration zone and recovery continues',
    () async {
      final errors = <Object>[];
      final zones = <Object?>[];
      runZonedGuarded(
        () {
          client.setConnectionStatusChangesHandler((status, reason) {
            record(status, reason);
            zones.add(Zone.current[#handler]);
            throw StateError('application status handler');
          });
        },
        (error, _) => errors.add(error),
        zoneValues: {#handler: 'registered'},
      );
      final peer = await establish();
      await peer.close();
      await until(() => changes.length == 2);
      final next = await retry();
      await next.connack(twinResponses: true);
      await until(() => client.isConnected);
      expect(changes, [connected, retrying, connected]);
      expect(errors, hasLength(3));
      expect(zones, everyElement('registered'));
    },
  );

  test(
    'closing from a connected handler prevents pending publication',
    () async {
      client.setConnectionStatusChangesHandler((status, reason) {
        record(status, reason);
        if (status == .connected) unawaited(client.close());
      });
      final sending = expectLater(
        client.sendEvent(.new([1])),
        throwsA(failure(.closed, .notSubmitted)),
      );
      final peer = await accept();
      await peer.connack(twinResponses: true);
      await sending;
      await peer.disconnected;
      expect(changes, [connected, disabled]);
      expect(client.isConnected, isFalse);
    },
  );

  test(
    'closing from a retrying handler cancels backoff and stale callbacks',
    () async {
      final peer = await establish();
      client.setConnectionStatusChangesHandler((status, reason) {
        record(status, reason);
        if (status == .disconnectedRetrying) unawaited(client.close());
      });
      await peer.close();
      await until(() => changes.length == 3);
      time.elapse(const .new(minutes: 10));
      await pumpEventQueue();
      expect(changes, [connected, retrying, disabled]);
      expect(server.peers, hasLength(1));
    },
  );

  test('a status handler can replace itself during a transition', () async {
    final replacement = <StatusChange>[];
    client.setConnectionStatusChangesHandler((status, reason) {
      record(status, reason);
      client.setConnectionStatusChangesHandler((status, reason) {
        replacement.add((status, reason));
      });
    });
    final peer = await establish();
    await peer.close();
    await until(() => replacement.isNotEmpty);
    expect(changes, [connected]);
    expect(replacement, [retrying]);
  });

  test('callback async work is not awaited', () async {
    final callbackDone = Completer<void>();
    var started = false;
    client.setConnectionStatusChangesHandler((status, reason) async {
      record(status, reason);
      started = true;
      await callbackDone.future;
    });
    await establish();
    expect(started, isTrue);
    expect(client.isConnected, isTrue);
    callbackDone.complete();
  });

  test('a connected handler can send without publishing the same work twice', () async {
    late Future<void> sending;
    client.setConnectionStatusChangesHandler((status, reason) {
      record(status, reason);
      if (status == .connected) sending = client.sendEvent(.new([7]));
    });
    final peer = await establish();
    final packet = await peer.nextPacket(3);
    expect(packet.body.last, 7);
    await peer.puback(packet.packetId);
    await sending;
    // Any duplicate PUBLISH would precede the acknowledgement of this unrelated
    // response in the controlled peer's packet stream.
    await peer.publish(r'$iothub/twin/res/200/?$rid=unused', [123, 125]);
    await peer.nextPacket(4);
    expect(client.pendingCount, 0);
  });

  test(
    'close before open reports disabled once and releases its handler',
    () async {
      await client.close();
      await client.close();
      await expectLater(
        client.open(),
        throwsA(failure(.closed, .notSubmitted)),
      );
      expect(changes, [disabled]);
      expect(server.peers, isEmpty);
    },
  );

  test('close during initial connection reports only disabled', () async {
    final opening = expectLater(
      client.open(),
      throwsA(failure(.closed, .notSubmitted)),
    );
    final peer = await accept();
    await client.close();
    await opening;
    await peer.disconnected;
    time.elapse(const .new(minutes: 10));
    await pumpEventQueue();
    expect(changes, [disabled]);
    expect(server.peers, hasLength(1));
  });

  test('close after a terminal failure reports disabled once', () async {
    final opening = expectLater(
      client.open(),
      throwsA(failure(.authentication, .notSubmitted)),
    );
    final peer = await accept();
    await peer.connack(code: 5);
    await opening;
    await client.close();
    await client.close();
    expect(changes, [badCredential, disabled]);
  });

  test('callback replacement enters the new handler zone', () async {
    final errors = <String>[];
    void register(String zoneName) {
      runZonedGuarded(() {
        client.setConnectionStatusChangesHandler((_, _) {
          throw StateError(zoneName);
        });
      }, (_, _) => errors.add(zoneName));
    }

    register('old');
    await establish();
    register('new');
    await client.close();
    expect(errors, ['old', 'new']);
  });

  for (final transient in [true, false]) {
    test(
      '${transient ? 'transient' : 'terminal'} provider failure uses communicationError',
      () async {
        await client.close();
        changes.clear();
        var calls = 0;
        client = createClient(
          authentication: .withTokenProvider(
            hostName: 'hub.azure-devices.net',
            deviceId: 'device-1',
            gatewayHostName: '127.0.0.1',
            tokenProvider: (_, _) async {
              calls++;
              if (transient) {
                throw const SocketException('provider network failure');
              }
              throw const FormatException('invalid provider credential');
            },
          ),
        )..setConnectionStatusChangesHandler(record);
        final opening = expectLater(
          client.open(),
          throwsA(
            failure(transient ? .closed : .authentication, .notSubmitted),
          ),
        );
        await until(() => changes.isNotEmpty);
        expect(changes, [transient ? retrying : communicationError]);
        expect(calls, 1);
        expect(server.peers, isEmpty);
        await client.close();
        await opening;
      },
    );
  }

  test('stalled provider timeout reports retrying; close suppresses late completion', () async {
    await client.close();
    changes.clear();
    final acquisition = Completer<String>();
    var called = false;
    client = createClient(
      authentication: .withTokenProvider(
        hostName: 'hub.azure-devices.net',
        deviceId: 'device-1',
        gatewayHostName: '127.0.0.1',
        tokenProvider: (_, _) {
          called = true;
          return acquisition.future;
        },
      ),
    )..setConnectionStatusChangesHandler(record);
    final opening = expectLater(
      client.open(),
      throwsA(failure(.closed, .notSubmitted)),
    );
    await until(() => called);
    time.elapse(const .new(seconds: 5));
    expect(changes, [retrying]);
    await client.close();
    await opening;
    acquisition.complete(credentials().createSasToken(now: epoch).value);
    await pumpEventQueue();
    expect(changes, [retrying, disabled]);
    expect(server.peers, isEmpty);
  });
}
