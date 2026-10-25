// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license; see third_party/azure-iot-sdk-csharp-LICENSE.
// Named cases adapt MqttTransportHandlerTests and MessageReceiveE2ETests.
// See docs/upstream.md for the pinned cases and Dart lifecycle additions.
import 'dart:async';
import 'dart:convert';

import 'package:azure_iot_hub/azure_iot_hub.dart';
import 'package:azure_iot_hub/src/internal_client.dart';
import 'package:test/test.dart';

import '../prototype/support/manual_time.dart';
import '../prototype/support/mqtt_peer.dart';
import 'support/device_test_support.dart';

const topic = 'devices/device-1/messages/devicebound/';
int packetId(Packet packet) => (packet.body[0] << 8) | packet.body[1];

Future<int> receiveControl(MqttPeer peer, {bool subscribe = true}) async {
  final packet = await peer.nextPacket(subscribe ? 8 : 10);
  final length = (packet.body[2] << 8) | packet.body[3];
  expect(utf8.decode(packet.body.sublist(4, 4 + length)), '$topic#');
  if (subscribe) expect(packet.body.last, 1);
  return packetId(packet);
}

void main() {
  for (final transport in MqttTransportType.values) {
    group(transport.name, () => transportTests(transport));
  }
}

void transportTests(MqttTransportType transport) {
  late MqttPeerServer server;
  late ManualTime time;
  late InternalClient client;

  setUp(() async {
    server = await switch (transport) {
      .tcp => MqttPeerServer.startTls(serverContext()),
      .webSocket => MqttPeerServer.startWebSocket(serverContext()),
    };
    time = ManualTime();
    client = InternalClient(
      credentials(),
      transport: transport,
      port: server.port,
      securityContext: clientContext(),
      maxPending: 4,
      maxPendingBytes: 1000,
      operationTimeout: const .new(seconds: 10),
      connectionTimeout: const .new(seconds: 5),
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
    expect(client.incomingCount, 0);
    expect(client.incomingBytes, 0);
    expect(time.activeTimers, 0);
  });

  Future<MqttPeer> accept() async {
    final peer = await server.nextConnection();
    await peer.nextPacket(1);
    await peer.connack(twinResponses: true);
    return peer;
  }

  Future<MqttPeer> register(ReceiveMessageHandler handler) async {
    final registered = client.setReceiveMessageHandler(handler);
    final peer = await accept();
    await peer.suback(await receiveControl(peer));
    await registered;
    return peer;
  }

  Future<void> complete(
    MqttPeer peer,
    CloudToDeviceMessage message,
    int id,
  ) async {
    await client.complete(message);
    expect(packetId(await peer.nextPacket(4)), id);
  }

  // Confirms no PUBACK was sent ahead of telemetry, without timing assumptions.
  Future<void> telemetryBarrier(MqttPeer peer) async {
    final sending = client.sendEvent(.new([1]));
    final packet = await peer.nextPacket(3);
    expect(packet.topic, startsWith('devices/device-1/messages/events/'));
    await peer.puback(packet.packetId);
    await sending;
  }

  test(
    'Message_DeviceReceiveSingleMessage_Mqtt: explicit completion',
    () async {
      final receiving = client.receive();
      final peer = await accept();
      final subscription = await receiveControl(peer);
      await peer.publish('$topic%24.mid=id&flag&empty=', [0, 255], id: 20);
      await until(() => client.incomingCount == 1);
      expect(client.pendingCount, 1);
      await peer.suback(subscription);
      final message = (await receiving)!;
      expect(message.payload, [0, 255]);
      expect(message.messageId, 'id');
      expect(message.properties, {'flag': null, 'empty': ''});
      await telemetryBarrier(peer);
      await complete(peer, message, 20);
      expect(client.incomingCount, 0);
      await expectLater(
        client.complete(message),
        throwsA(failure(.protocol, .notSubmitted)),
      );
    },
  );

  test(
    'Message_DeviceReceiveMessageOperationTimeout: subscription stays active',
    () async {
      final receiving = client.receive(timeout: const .new(seconds: 2));
      final peer = await accept();
      await peer.suback(await receiveControl(peer));
      await until(() => client.isConnected);
      time.elapse(const .new(seconds: 2));
      expect(await receiving, isNull);
      await peer.publish(topic, [2], id: 21);
      await until(() => client.incomingCount == 1);
      final message = (await client.receive())!;
      await complete(peer, message, 21);
    },
  );

  test('ReceiveAsync pre-cancelled and finite with caller token', () async {
    final cancelled = CancellationTokenSource()..cancel();
    await expectLater(
      client.receive(cancellationToken: cancelled.token),
      throwsA(failure(.cancelled, .notSubmitted)),
    );
    expect(server.peers, isEmpty);
    final source = CancellationTokenSource();
    final receiving = client.receive(cancellationToken: source.token);
    final peer = await accept();
    await peer.suback(await receiveControl(peer));
    await telemetryBarrier(peer);
    time.elapse(const .new(seconds: 10));
    expect(await receiving, isNull);
    expect(client.pendingCount, 0);
  });

  test(
    'cancelling a receive releases its slot without stopping recovery',
    () async {
      final source = CancellationTokenSource();
      final receiving = expectLater(
        client.receive(cancellationToken: source.token),
        throwsA(failure(.cancelled, .notSubmitted)),
      );
      final peer = await accept();
      await peer.suback(await receiveControl(peer));
      await telemetryBarrier(peer);
      source.cancel();
      await receiving;
      await peer.close();
      await until(() => !client.isConnected);
      time.elapse(const .new(milliseconds: 100));
      final recovered = await accept();
      await telemetryBarrier(recovered);
    },
  );

  test(
    'DeviceReceiveMessageUsingCallback: callback return is not completion',
    () async {
      final messages = <CloudToDeviceMessage>[];
      final peer = await register(messages.add);
      await peer.publish(topic, [1], id: 22);
      await until(() => messages.length == 1);
      expect(await client.receive(), isNull);
      await telemetryBarrier(peer);
      await complete(peer, messages.single, 22);
    },
  );

  test(
    'DeviceReceiveMessageUsingCallbackUpdateHandler: no wire exchange',
    () async {
      final first = <CloudToDeviceMessage>[];
      final second = <CloudToDeviceMessage>[];
      final peer = await register(first.add);
      await client.setReceiveMessageHandler(second.add);
      await peer.publish(topic, [], id: 23);
      await until(() => second.isNotEmpty);
      expect(first, isEmpty);
      await complete(peer, second.single, 23);
    },
  );

  test(
    'DeviceReceiveMessageUsingCallbackAndUnsubscribe: re-registers',
    () async {
      final messages = <CloudToDeviceMessage>[];
      final peer = await register(messages.add);
      final removing = client.setReceiveMessageHandler(null);
      final id = await receiveControl(peer, subscribe: false);
      await peer.publish(topic, [1], id: 24);
      await until(() => client.incomingCount == 1);
      expect(messages, isEmpty);
      await peer.unsuback(id);
      await removing;
      final registering = client.setReceiveMessageHandler(messages.add);
      await peer.suback(await receiveControl(peer));
      await registering;
      await until(() => messages.isNotEmpty);
      await complete(peer, messages.single, 24);
    },
  );

  test(
    'DeviceReceivePendingMessageUsingCallback: drains the polling queue',
    () async {
      final receiving = client.receive(timeout: const .new(seconds: 1));
      final peer = await accept();
      await peer.suback(await receiveControl(peer));
      await telemetryBarrier(peer);
      time.elapse(const .new(seconds: 1));
      expect(await receiving, isNull);
      await peer.publish(topic, [], id: 25);
      await until(() => client.incomingCount == 1);
      final messages = <CloudToDeviceMessage>[];
      await client.setReceiveMessageHandler(messages.add);
      expect(messages, hasLength(1));
      await complete(peer, messages.single, 25);
    },
  );

  test('out-of-order completion leaves earlier delivery intact', () async {
    final messages = <CloudToDeviceMessage>[];
    final peer = await register(messages.add);
    await peer.publish(topic, [1], id: 26);
    await peer.publish(topic, [2], id: 27);
    await until(() => messages.length == 2);
    await expectLater(
      client.complete(messages.last),
      throwsA(failure(.protocol, .notSubmitted)),
    );
    expect(client.incomingCount, 2);
    await complete(peer, messages.first, 26);
    await complete(peer, messages.last, 27);
  });

  test(
    'twin response progresses but its PUBACK waits for C2D completion',
    () async {
      final messages = <CloudToDeviceMessage>[];
      final peer = await register(messages.add);
      await peer.publish(topic, [], id: 28);
      await until(() => messages.isNotEmpty);
      final getting = client.getTwin();
      final request = await peer.nextPacket(3);
      await peer.puback(request.packetId);
      await peer.publish(
        '${r'$iothub/twin/res/200/?$rid='}${requestId(request)}',
        utf8.encode('{"desired":{"value":1},"reported":{}}'),
        id: 29,
      );
      expect((await getting).desired?['value'], 1);
      await telemetryBarrier(peer);
      await complete(peer, messages.single, 28);
      expect(packetId(await peer.nextPacket(4)), 29);
      expect(client.incomingCount, 0);
    },
  );

  test('CompleteAsync pre-cancellation preserves the delivery', () async {
    final messages = <CloudToDeviceMessage>[];
    final peer = await register(messages.add);
    await peer.publish(topic, [], id: 30);
    await until(() => messages.isNotEmpty);
    final source = CancellationTokenSource()..cancel();
    await expectLater(
      client.complete(messages.single, cancellationToken: source.token),
      throwsA(failure(.cancelled, .notSubmitted)),
    );
    await complete(peer, messages.single, 30);
  });

  test(
    'recovery restores callback; stale completion cannot ACK reused ID',
    () async {
      final messages = <CloudToDeviceMessage>[];
      final peer = await register(messages.add);
      await peer.publish(topic, [], id: 31);
      await until(() => messages.isNotEmpty);
      await peer.close();
      await until(() => !client.isConnected);
      time.elapse(const .new(milliseconds: 100));
      final recovered = await accept();
      final subscription = await receiveControl(recovered);
      expect(client.isConnected, isFalse);
      await recovered.suback(subscription);
      await recovered.publish(topic, [], id: 31);
      await until(() => messages.length == 2);
      await expectLater(
        client.complete(messages.first),
        throwsA(failure(.protocol, .notSubmitted)),
      );
      await complete(recovered, messages.last, 31);
    },
  );

  test(
    'count overflow retires without acknowledging excess messages',
    () async {
      final messages = <CloudToDeviceMessage>[];
      final peer = await register(messages.add);
      for (var id = 1; id <= 4; id++) {
        await peer.publish(topic, [], id: id);
      }
      await until(() => messages.length == 4);
      await telemetryBarrier(peer);
      await peer.publish(topic, [], id: 5);
      await peer.disconnected;
      expect(messages, hasLength(4));
      expect(client.incomingCount, 0);
      expect(client.incomingBytes, 0);
      time.elapse(const .new(milliseconds: 100));
      final recovered = await accept();
      await recovered.suback(await receiveControl(recovered));
      await recovered.publish(topic, [], id: 1);
      await until(() => messages.length == 5);
      await complete(recovered, messages.last, 1);
    },
  );

  test('incoming byte budget includes payload and topic', () async {
    final messages = <CloudToDeviceMessage>[];
    final peer = await register(messages.add);
    await peer.publish(topic, List.filled(1001 - topic.length, 0));
    await peer.disconnected;
    expect(messages, isEmpty);
    expect(client.incomingBytes, 0);
  });

  test('receive waiters share the bounded operation count', () async {
    final source = CancellationTokenSource();
    final waits = [
      for (var i = 0; i < 4; i++)
        expectLater(
          client.receive(cancellationToken: source.token),
          throwsA(failure(.cancelled, .notSubmitted)),
        ),
    ];
    await expectLater(
      client.receive(),
      throwsA(failure(.capacity, .notSubmitted)),
    );
    await expectLater(
      client.sendEvent(.new([])),
      throwsA(failure(.capacity, .notSubmitted)),
    );
    source.cancel();
    await Future.wait(waits);
  });

  test('rejected C2D SUBACK fails registration and stops recovery', () async {
    final registered = expectLater(
      client.setReceiveMessageHandler((_) {}),
      throwsA(failure(.protocol, .unknown)),
    );
    final peer = await accept();
    await peer.suback(await receiveControl(peer), qos: 0x80);
    await registered;
    await peer.disconnected;
    expect(client.isConnected, isFalse);
  });

  test('cancelled registration ignores late SUBACK and cleans up', () async {
    final source = CancellationTokenSource();
    final messages = <CloudToDeviceMessage>[];
    final registered = expectLater(
      client.setReceiveMessageHandler(
        messages.add,
        cancellationToken: source.token,
      ),
      throwsA(failure(.cancelled, .unknown)),
    );
    final peer = await accept();
    final id = await receiveControl(peer);
    source.cancel();
    await registered;
    await peer.suback(id);
    await peer.unsuback(await receiveControl(peer, subscribe: false));
    await peer.publish(topic, [], id: 32);
    await until(() => client.incomingCount == 1);
    expect(messages, isEmpty);
    await telemetryBarrier(peer);
  });

  test('close fails pending receive promptly and remains terminal', () async {
    final receiving = expectLater(
      client.receive(),
      throwsA(failure(.closed, .notSubmitted)),
    );
    final peer = await accept();
    await receiveControl(peer);
    await client.close();
    await receiving;
    await expectLater(
      client.receive(),
      throwsA(failure(.closed, .notSubmitted)),
    );
    await expectLater(
      client.setReceiveMessageHandler((_) {}),
      throwsA(failure(.closed, .notSubmitted)),
    );
  });

  for (final ending in ['cancel', 'timeout', 'close', 'disconnect']) {
    test('completion waiting behind a method supports $ending', () async {
      final messages = <CloudToDeviceMessage>[];
      final peer = await register(messages.add);
      final result = Completer<MethodResponse>();
      final registering = client.setMethodHandler('held', (_) => result.future);
      final subscription = await peer.nextPacket(8);
      await peer.suback(packetId(subscription));
      await registering;
      await peer.publish(r'$iothub/methods/POST/held/?$rid=held', [], id: 40);
      await peer.publish(topic, [], id: 41);
      await until(() => messages.isNotEmpty);
      final source = CancellationTokenSource();
      final completing = expectLater(
        client.complete(messages.single, cancellationToken: source.token),
        throwsA(
          failure(switch (ending) {
            'cancel' => .cancelled,
            'timeout' => .timeout,
            'close' => .closed,
            _ => .protocol,
          }, .notSubmitted),
        ),
      );
      await telemetryBarrier(peer);
      switch (ending) {
        case 'cancel':
          source.cancel();
        case 'timeout':
          time.elapse(const .new(seconds: 10));
        case 'close':
          await client.close();
        case 'disconnect':
          await peer.close();
          await until(() => !client.isConnected);
      }
      await completing;
      if (ending == 'cancel' || ending == 'timeout') {
        // An unsubmitted cancellation leaves the message available to complete.
        final retry = client.complete(messages.single);
        result.complete(.new(200));
        final response = await peer.nextPacket(3);
        await peer.puback(response.packetId);
        expect(packetId(await peer.nextPacket(4)), 40);
        expect(packetId(await peer.nextPacket(4)), 41);
        await retry;
      } else {
        await client.close();
        result.complete(.new(200));
      }
      await until(() => client.methodCallCount == 0);
    });
  }

  test('async receive handlers overlap and are not awaited on close', () async {
    final release = Completer<void>();
    var entered = 0;
    var finished = 0;
    final peer = await register((_) async {
      entered++;
      await release.future;
      finished++;
    });
    await peer.publish(topic, [], id: 42);
    await peer.publish(topic, [], id: 43);
    await until(() => entered == 2);
    expect(finished, 0);
    await client.close();
    release.complete();
    await until(() => finished == 2);
  });

  test('synchronous callback failure retires without acknowledging', () async {
    var calls = 0;
    final peer = await register((_) {
      calls++;
      throw StateError('application data must not escape');
    });
    await peer.publish(topic, []);
    await peer.disconnected;
    expect(calls, 1);
    expect(client.isConnected, isFalse);
  });

  test(
    'pending receive survives disconnect within its original deadline',
    () async {
      final receiving = client.receive();
      final peer = await accept();
      await peer.suback(await receiveControl(peer));
      await telemetryBarrier(peer);
      time.elapse(const .new(seconds: 6));
      await peer.close();
      await until(() => !client.isConnected);
      time.elapse(const .new(milliseconds: 100));
      final recovered = await accept();
      await recovered.suback(await receiveControl(recovered));
      await telemetryBarrier(recovered);
      time.elapse(const .new(milliseconds: 3900));
      expect(await receiving, isNull);
    },
  );

  test('QoS 0 delivery releases storage and cannot be completed', () async {
    final messages = <CloudToDeviceMessage>[];
    final peer = await register(messages.add);
    await peer.publish(topic, [], qos: 0);
    await until(() => messages.isNotEmpty);
    expect(client.incomingCount, 0);
    await expectLater(
      client.complete(messages.single),
      throwsA(failure(.protocol, .notSubmitted)),
    );
    await telemetryBarrier(peer);
  });

  test('callback replacement needs no outgoing capacity', () async {
    final old = <CloudToDeviceMessage>[];
    final next = <CloudToDeviceMessage>[];
    final peer = await register(old.add);
    final sending = [for (var i = 0; i < 4; i++) client.sendEvent(.new([]))];
    final packets = [for (var i = 0; i < 4; i++) await peer.nextPacket(3)];
    await client.setReceiveMessageHandler(next.add);
    await peer.publish(topic, [], id: 44);
    await until(() => next.isNotEmpty);
    expect(old, isEmpty);
    await complete(peer, next.single, 44);
    for (final packet in packets) {
      await peer.puback(packet.packetId);
    }
    await Future.wait(sending);
  });

  test('callback removal while restoring survives cancellation', () async {
    final messages = <CloudToDeviceMessage>[];
    final peer = await register(messages.add);
    await peer.close();
    await until(() => !client.isConnected);
    time.elapse(const .new(milliseconds: 100));
    final recovered = await accept();
    final id = await receiveControl(recovered);
    final source = CancellationTokenSource();
    final removing = expectLater(
      client.setReceiveMessageHandler(null, cancellationToken: source.token),
      throwsA(failure(.cancelled, .notSubmitted)),
    );
    source.cancel();
    await removing;
    await recovered.suback(id);
    await recovered.publish(topic, [], id: 45);
    await until(() => client.incomingCount == 1);
    expect(messages, isEmpty);
    await telemetryBarrier(recovered);
    await client.setReceiveMessageHandler(messages.add);
    expect(messages, hasLength(1));
    await complete(recovered, messages.single, 45);
  });

  test(
    'foreign client completion cannot acknowledge this client delivery',
    () async {
      final messages = <CloudToDeviceMessage>[];
      final peer = await register(messages.add);
      await peer.publish(topic, [], id: 46);
      await until(() => messages.isNotEmpty);
      final other = InternalClient(credentials(), now: () => epoch);
      try {
        await expectLater(
          other.complete(messages.single),
          throwsA(failure(.protocol, .notSubmitted)),
        );
      } finally {
        await other.close();
      }
      await complete(peer, messages.single, 46);
    },
  );

  test(
    'deferred automatic ACKs share the retained incoming count bound',
    () async {
      final peer = await register((_) {});
      await peer.publish(topic, [], id: 47);
      for (var id = 48; id <= 50; id++) {
        await peer.publish(r'$iothub/twin/res/200/?$rid=unknown', [], id: id);
      }
      await until(() => client.incomingCount == 4);
      await telemetryBarrier(peer);
      await peer.publish(r'$iothub/twin/res/200/?$rid=unknown', [], id: 51);
      await peer.disconnected;
      expect(client.incomingCount, 0);
    },
  );

  test(
    'callback can complete and close synchronously during dispatch',
    () async {
      late Future<void> completion;
      final peer = await register((message) {
        completion = client.complete(message);
        unawaited(client.close());
      });
      await peer.publish(topic, [], id: 52);
      await peer.disconnected;
      await completion;
      expect(client.isConnected, isFalse);
    },
  );

  test(
    'registration and polling validate cancellation before connecting',
    () async {
      final source = CancellationTokenSource()..cancel();
      await expectLater(
        client.setReceiveMessageHandler(
          (_) {},
          cancellationToken: source.token,
        ),
        throwsA(failure(.cancelled, .notSubmitted)),
      );
      await expectLater(
        client.receive(timeout: Duration.zero),
        throwsArgumentError,
      );
      expect(server.peers, isEmpty);
    },
  );

  test(
    'duplicate QoS 1 deliveries can each be completed in arrival order',
    () async {
      final messages = <CloudToDeviceMessage>[];
      final peer = await register(messages.add);
      await peer.publish(topic, [1], id: 53);
      await peer.publish(topic, [1], id: 53, duplicate: true);
      await until(() => messages.length == 2);
      await complete(peer, messages.first, 53);
      await complete(peer, messages.last, 53);
      expect(client.incomingCount, 0);
      await telemetryBarrier(peer);
    },
  );

  test(
    'reentrant removal holds queued messages until registration settles',
    () async {
      late Future<void> removing;
      late Future<CloudToDeviceMessage?> receiving;
      late CloudToDeviceMessage first;
      var delivered = false;
      final registering = client.setReceiveMessageHandler((message) {
        first = message;
        removing = client.setReceiveMessageHandler(null);
        receiving = client.receive().then((message) {
          delivered = true;
          return message;
        });
      });
      final peer = await accept();
      final id = await receiveControl(peer);
      await peer.publish(topic, [1], id: 54);
      await peer.publish(topic, [2], id: 55);
      await until(() => client.incomingCount == 2);
      await peer.suback(id);
      await registering;
      final unsubscribe = await receiveControl(peer, subscribe: false);
      await telemetryBarrier(peer);
      expect(delivered, isFalse);
      await peer.unsuback(unsubscribe);
      await removing;
      await peer.suback(await receiveControl(peer));
      final second = (await receiving)!;
      await complete(peer, first, 54);
      await complete(peer, second, 55);
    },
  );
}
