// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license; see third_party/azure-iot-sdk-csharp-LICENSE.
// The two named pre-cancellation cases below are adapted from
// Azure/azure-iot-sdk-csharp, commit 7a99b886e81158a31bd6a47f86a32393dcc1c73b,
// iothub/device/tests/Transport/Mqtt/MqttTransportHandlerTests.cs.
// Remaining cases exercise Dart-specific behaviour and our timeout deviation.
import 'dart:async';
import 'dart:io';

import 'package:azure_iot_hub/src/pending_operation.dart';
import 'package:cancellation_token/cancellation_token.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:test/test.dart';

import 'support/manual_time.dart';
import 'support/mqtt_peer.dart';
import 'support/probe_client.dart';

Matcher failure(OperationFailureReason reason, DeliveryState delivery) =>
    isA<OperationFailure>()
        .having((error) => error.reason, 'reason', reason)
        .having((error) => error.delivery, 'delivery', delivery);

void main() {
  late MqttPeerServer server;
  late ManualTime time;
  late ProbeClient probe;
  late List<MqttServerClient> clients;

  setUp(() async {
    server = await MqttPeerServer.start();
    time = ManualTime();
    clients = [];
    probe = ProbeClient(
      () {
        final client = MqttServerClient.withPort(
          '127.0.0.1',
          'probe-${clients.length}',
          server.port,
          maxConnectionAttempts: 1,
        )..setProtocolV311();
        clients.add(client);
        return client;
      },
      schedule: time.schedule,
      operationTimeout: const Duration(seconds: 10),
    );
  });

  tearDown(() async {
    await probe.close();
    await server.close();
    expect(probe.pendingCount, 0);
    expect(probe.retainedPackets, 0);
    expect(probe.hasCancellationListeners, isFalse);
    expect(time.activeTimers, 0);
  });

  Future<MqttPeer> establish() async {
    final opening = probe.open();
    final peer = await server.nextConnection();
    await peer.nextPacket(1);
    await peer.connack();
    await opening;
    return peer;
  }

  test('MqttTransportHandlerOpenAsyncTokenCancellationRequested', () async {
    final token = CancellationToken()..cancel();
    await expectLater(
      probe.open(cancellationToken: token),
      throwsA(
        failure(OperationFailureReason.cancelled, DeliveryState.notSubmitted),
      ),
    );
    expect(clients, isEmpty);
    expect(token.hasCancellables, isFalse);
  });

  test(
    'MqttTransportHandlerSendEventAsyncTokenCancellationRequested',
    () async {
      final token = CancellationToken()..cancel();
      await expectLater(
        probe.send('event', cancellationToken: token),
        throwsA(
          failure(OperationFailureReason.cancelled, DeliveryState.notSubmitted),
        ),
      );
      expect(clients, isEmpty);
      expect(token.hasCancellables, isFalse);
    },
  );

  test('send completes on PUBACK and detaches the caller token', () async {
    final peer = await establish();
    final token = CancellationToken();
    var completed = false;
    final sending = probe.send('event', cancellationToken: token)
      ..then((_) => completed = true);
    final packet = await peer.nextPacket(3);
    expect(completed, isFalse);
    expect(probe.retainedPackets, 1);
    await peer.puback(packet.packetId);
    await sending;
    token.cancel();
    expect(completed, isTrue);
    expect(token.hasCancellables, isFalse);
    expect(probe.pendingCount, 0);
    expect(probe.retainedPackets, 0);
  });

  test(
    'cancelling during connection removes the send but preserves recovery',
    () async {
      final token = CancellationToken();
      final result = expectLater(
        probe.send('cancelled', cancellationToken: token),
        throwsA(
          failure(OperationFailureReason.cancelled, DeliveryState.notSubmitted),
        ),
      );
      final peer = await server.nextConnection();
      await peer.nextPacket(1);
      token.cancel();
      await result;
      expect(probe.pendingCount, 0);
      final sending = probe.send('next');
      await peer.connack();
      final packet = await peer.nextPacket(3);
      expect(packet.body, containsAllInOrder('next'.codeUnits));
      await peer.puback(packet.packetId);
      await sending;
      expect(clients, hasLength(1));
    },
  );

  test('caller token does not disable the whole-operation timeout', () async {
    final token = CancellationToken();
    final result = expectLater(
      probe.send('event', cancellationToken: token),
      throwsA(
        failure(OperationFailureReason.timeout, DeliveryState.notSubmitted),
      ),
    );
    final peer = await server.nextConnection();
    await peer.nextPacket(1);
    time.elapse(const Duration(seconds: 10));
    await result;
    expect(token.isCancelled, isFalse);
    expect(token.hasCancellables, isFalse);
    expect(probe.pendingCount, 0);
  });

  test('late PUBACK after cancellation releases only its own slot', () async {
    final peer = await establish();
    final token = CancellationToken();
    final cancelled = expectLater(
      probe.send('old', cancellationToken: token),
      throwsA(failure(OperationFailureReason.cancelled, DeliveryState.unknown)),
    );
    final old = await peer.nextPacket(3);
    token.cancel();
    await cancelled;
    expect(token.hasCancellables, isFalse);
    expect(probe.retainedPackets, 1);
    expect(probe.pendingCount, 1);
    var completed = false;
    final next = probe.send('next')..then((_) => completed = true);
    final fresh = await peer.nextPacket(3);
    expect(fresh.packetId, isNot(old.packetId));
    await peer.puback(old.packetId);
    await pumpEventQueue();
    expect(completed, isFalse);
    expect(probe.pendingCount, 1);
    expect(probe.retainedPackets, 1);
    await peer.puback(fresh.packetId);
    await next;
  });

  test('repeated cancellation cannot bypass the in-flight limit', () async {
    final peer = await establish();
    for (var i = 0; i < probe.maxPending; i++) {
      final token = CancellationToken();
      final result = expectLater(
        probe.send('event-$i', cancellationToken: token),
        throwsA(
          failure(OperationFailureReason.cancelled, DeliveryState.unknown),
        ),
      );
      await peer.nextPacket(3);
      token.cancel();
      await result;
    }
    expect(probe.pendingCount, probe.maxPending);
    expect(probe.retainedPackets, probe.maxPending);
    await expectLater(
      probe.send('overflow'),
      throwsA(
        failure(OperationFailureReason.capacity, DeliveryState.notSubmitted),
      ),
    );
    time.elapse(const Duration(seconds: 10));
    await peer.disconnected;
    expect(probe.pendingCount, 0);
    expect(probe.retainedPackets, 0);
    time.elapse(probe.retryDelay);
    final next = await server.nextConnection();
    await next.nextPacket(1);
    final sending = probe.send('recovered');
    await next.connack();
    final packet = await next.nextPacket(3);
    await next.puback(packet.packetId);
    await sending;
  });

  test(
    'missing PUBACK times out with unknown delivery and retires the socket',
    () async {
      final peer = await establish();
      final result = expectLater(
        probe.send('event'),
        throwsA(failure(OperationFailureReason.timeout, DeliveryState.unknown)),
      );
      await peer.nextPacket(3);
      time.elapse(const Duration(seconds: 10));
      await result;
      await peer.disconnected;
      expect(probe.retainedPackets, 0);
    },
  );

  test('PUBACK followed by timeout and cancellation completes once', () async {
    final peer = await establish();
    final token = CancellationToken();
    var completions = 0;
    final result = probe.send('event', cancellationToken: token)
      ..then((_) => completions++);
    final packet = await peer.nextPacket(3);
    await peer.puback(packet.packetId);
    await result;
    time.elapse(const Duration(seconds: 10));
    token.cancel();
    await peer.puback(packet.packetId); // Duplicate acknowledgement.
    await pumpEventQueue();
    expect(completions, 1);
    expect(probe.isConnected, isTrue);
  });

  test(
    'connection replacement ignores obsolete disconnect callbacks',
    () async {
      final old = await establish();
      final staleCallback = clients.single.onDisconnected!;
      await old.close();
      await pumpEventQueue();
      expect(probe.isConnected, isFalse);
      time.elapse(probe.retryDelay);
      final fresh = await server.nextConnection();
      await fresh.nextPacket(1);
      final opening = probe.open();
      await fresh.connack();
      await opening;
      staleCallback();
      expect(probe.isConnected, isTrue);
      final result = probe.send('event');
      final packet = await fresh.nextPacket(3);
      await fresh.puback(packet.packetId);
      await result;
    },
  );

  test('reconnect does not restart the original send deadline', () async {
    final peer = await establish();
    final token = CancellationToken();
    final result = expectLater(
      probe.send('event', cancellationToken: token),
      throwsA(failure(OperationFailureReason.timeout, DeliveryState.unknown)),
    );
    await peer.nextPacket(3);
    time.elapse(const Duration(seconds: 4));
    await peer.close();
    await pumpEventQueue();
    time.elapse(probe.retryDelay);
    final next = await server.nextConnection();
    await next.nextPacket(1);
    time.elapse(const Duration(seconds: 5));
    await result;
    expect(time.elapsed, const Duration(seconds: 10));
    expect(token.hasCancellables, isFalse);
  });

  test(
    'transient disconnect republishes within the original deadline',
    () async {
      final peer = await establish();
      final result = probe.send('event');
      await peer.nextPacket(3);
      await peer.close();
      await pumpEventQueue();
      time.elapse(probe.retryDelay);
      final next = await server.nextConnection();
      await next.nextPacket(1);
      await next.connack();
      final retry = await next.nextPacket(3);
      await next.puback(retry.packetId);
      await result;
      expect(clients, hasLength(2));
    },
  );

  test(
    'shutdown while connecting settles the operation and connection',
    () async {
      final token = CancellationToken();
      final result = expectLater(
        probe.open(cancellationToken: token),
        throwsA(
          failure(OperationFailureReason.closed, DeliveryState.notSubmitted),
        ),
      );
      final peer = await server.nextConnection();
      await peer.nextPacket(1);
      await probe.close();
      await result;
      await peer.disconnected;
      expect(token.hasCancellables, isFalse);
      time.elapse(const Duration(minutes: 10));
      expect(clients, hasLength(1));
      await probe.close();
    },
  );

  test('shutdown while publishing reports unknown delivery', () async {
    final peer = await establish();
    final result = expectLater(
      probe.send('event'),
      throwsA(failure(OperationFailureReason.closed, DeliveryState.unknown)),
    );
    await peer.nextPacket(3);
    await probe.close();
    await result;
    await peer.disconnected;
    await expectLater(
      probe.send('after close'),
      throwsA(
        failure(OperationFailureReason.closed, DeliveryState.notSubmitted),
      ),
    );
  });

  test(
    'oversized payload is rejected before allocating a connection',
    () async {
      await expectLater(
        probe.send('x' * (probe.maxPayloadBytes + 1)),
        throwsArgumentError,
      );
      expect(clients, isEmpty);
    },
  );

  test(
    'shutdown before the socket connect completes cannot revive the client',
    () async {
      final result = expectLater(
        probe.send('event'),
        throwsA(
          failure(OperationFailureReason.closed, DeliveryState.notSubmitted),
        ),
      );
      await probe.close();
      await result;
      expect(probe.isConnected, isFalse);
      time.elapse(const Duration(minutes: 10));
      expect(clients, hasLength(1));
    },
  );

  test(
    'one caller token cancels multiple sends without cancelling the client',
    () async {
      final peer = await establish();
      final token = CancellationToken();
      final results = <Future<void>>[];
      final packets = <Packet>[];
      for (var i = 0; i < 3; i++) {
        results.add(
          expectLater(
            probe.send('event-$i', cancellationToken: token),
            throwsA(
              failure(OperationFailureReason.cancelled, DeliveryState.unknown),
            ),
          ),
        );
        packets.add(await peer.nextPacket(3));
      }
      token.cancel();
      await Future.wait(results);
      expect(token.hasCancellables, isFalse);
      expect(probe.isConnected, isTrue);
      for (final packet in packets) {
        await peer.puback(packet.packetId);
      }
      await pumpEventQueue();
      expect(probe.pendingCount, 0);
    },
  );

  test('zero timeout is rejected', () {
    expect(
      () => ProbeClient(
        () => throw StateError('unused'),
        operationTimeout: Duration.zero,
      ),
      throwsArgumentError,
    );
  });

  test(
    'shutdown cancels callers before bounded CONNACK cleanup finishes',
    () async {
      final result = expectLater(
        probe.open(),
        throwsA(
          failure(OperationFailureReason.closed, DeliveryState.notSubmitted),
        ),
      );
      final peer = await server.nextConnection();
      await peer.nextPacket(1);
      var disposed = false;
      final closing = probe.close().then((_) => disposed = true);
      await result;
      expect(disposed, isFalse);
      await closing.timeout(const Duration(seconds: 3));
      await peer.disconnected;
      expect(probe.isConnected, isFalse);
      expect(clients, hasLength(1));
    },
  );

  test(
    'shutdown disposes a socket and CONNACK that arrive after retirement',
    () async {
      final socket = await Socket.connect('127.0.0.1', server.port);
      final peer = await server.nextConnection();
      final release = Completer<Socket>();
      addTearDown(socket.destroy);
      await IOOverrides.runZoned(
        () async {
          final result = expectLater(
            probe.send('must not be published'),
            throwsA(
              failure(
                OperationFailureReason.closed,
                DeliveryState.notSubmitted,
              ),
            ),
          );
          var disposed = false;
          final closing = probe.close().then((_) => disposed = true);
          await result;
          expect(disposed, isFalse);
          release.complete(socket);
          await peer.nextPacket(1);
          await peer.connack();
          await closing;
          final disconnect = await peer.nextPacket(14);
          expect(disconnect.type, 14);
          await peer.disconnected;
          expect(probe.isConnected, isFalse);
          expect(clients, hasLength(1));
        },
        socketConnect: (
          dynamic host,
          int port, {
          dynamic sourceAddress,
          int sourcePort = 0,
          Duration? timeout,
        }) => release.future,
      );
    },
  );

  test(
    'a retired attempt settles before recovery creates another client',
    () async {
      final result = probe.send('after retry');
      final peer = await server.nextConnection();
      await peer.nextPacket(1);
      time.elapse(probe.connectionTimeout);
      time.elapse(probe.retryDelay);
      expect(clients, hasLength(1));
      // The attempt is obsolete, but its public handler remains reachable for cleanup.
      await peer.connack();
      await peer.nextPacket(14);
      await peer.disconnected;
      await pumpEventQueue();
      time.elapse(probe.retryDelay);
      final next = await server.nextConnection();
      await next.nextPacket(1);
      await next.connack();
      final packet = await next.nextPacket(3);
      await next.puback(packet.packetId);
      await result;
      expect(clients, hasLength(2));
    },
  );

  test(
    'mqtt_client preserves outstanding publishes when packet IDs wrap',
    () async {
      final client = MqttServerClient.withPort(
        '127.0.0.1',
        'raw-ids',
        server.port,
        maxConnectionAttempts: 1,
      )..setProtocolV311();
      addTearDown(client.disconnect);
      final connecting = client.connect();
      final peer = await server.nextConnection();
      await peer.nextPacket(1);
      await peer.connack();
      await connecting;
      final payload =
          (MqttClientPayloadBuilder()..addUTF8String('first')).payload!;
      final firstId = client.publishMessage(
        'probe/telemetry',
        MqttQos.atLeastOnce,
        payload,
      );
      await peer.nextPacket(3);
      // Test-only advancement of the shared allocator while PUBACK is withheld.
      final dispenser = MessageIdentifierDispenser();
      for (
        var i = 0;
        i < MessageIdentifierDispenser.maxMessageIdentifier - 2;
        i++
      ) {
        dispenser.getNextMessageIdentifier();
      }
      final secondId = client.publishMessage(
        'probe/telemetry',
        MqttQos.atLeastOnce,
        payload,
      );
      await peer.nextPacket(3);
      expect(secondId, isNot(firstId));
      // ignore: invalid_use_of_protected_member
      expect(client.publishingManager!.publishedMessages, hasLength(2));
      final published = StreamIterator(client.published!);
      addTearDown(published.cancel);
      await peer.puback(firstId);
      expect(await published.moveNext(), isTrue);
      expect(published.current.variableHeader!.messageIdentifier, firstId);
      // ignore: invalid_use_of_protected_member
      expect(client.publishingManager!.publishedMessages.keys, [secondId]);
      await peer.puback(secondId);
      expect(await published.moveNext(), isTrue);
      expect(published.current.variableHeader!.messageIdentifier, secondId);
      // ignore: invalid_use_of_protected_member
      expect(client.publishingManager!.publishedMessages, isEmpty);
    },
  );
}
