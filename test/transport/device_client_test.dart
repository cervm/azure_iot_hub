// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license; see third_party/azure-iot-sdk-csharp-LICENSE.
// Named pre-cancellation cases adapt MqttTransportHandlerTests.cs. The CONNECT
// model-ID case adapts MqttIotHubAdapterTest.cs at the pinned C# commit.
// Additional cases exercise the Dart transport and agreed bounded operations.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:azure_iot_hub/azure_iot_hub.dart';
import 'package:azure_iot_hub/src/authentication/iot_hub_connection_string.dart';
import 'package:azure_iot_hub/src/cancellation.dart'
    show unwrapCancellationToken;
import 'package:azure_iot_hub/src/internal_client.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:test/test.dart';

import '../prototype/support/manual_time.dart';
import '../prototype/support/mqtt_peer.dart';
import 'support/device_test_support.dart';

void main() {
  for (final transport in MqttTransportType.values) {
    group(transport.name, () => transportTests(transport));
  }
}

void transportTests(MqttTransportType transport) {
  late MqttPeerServer server;
  late ManualTime time;
  late InternalClient client;
  late Duration wallClockOffset;

  setUp(() async {
    server = await switch (transport) {
      MqttTransportType.tcp => MqttPeerServer.startTls(serverContext()),
      MqttTransportType.webSocket => MqttPeerServer.startWebSocket(
        serverContext(),
      ),
    };
    time = ManualTime();
    wallClockOffset = Duration.zero;
    client = InternalClient(
      credentials(),
      transport: transport,
      port: server.port,
      securityContext: clientContext(),
      operationTimeout: const Duration(seconds: 10),
      connectionTimeout: const Duration(seconds: 5),
      maxPending: 3,
      schedule: time.schedule,
      now: () => epoch.add(time.elapsed + wallClockOffset),
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

  Future<MqttPeer> establish() async {
    final opening = client.open();
    final peer = await server.nextConnection();
    await peer.nextPacket(1);
    await peer.connack(twinResponses: true);
    await opening;
    return peer;
  }

  test('NotSettingPnpModelIdShouldNotSetModelIdOnConnectPacket', () async {
    final opening = client.open();
    final peer = await server.nextConnection();
    final connect = await peer.nextPacket(1);
    final body = connect.body;
    var offset = 0;
    String readString() {
      final length = (body[offset] << 8) | body[offset + 1];
      offset += 2;
      final value = utf8.decode(body.sublist(offset, offset + length));
      offset += length;
      return value;
    }

    expect(readString(), 'MQTT');
    expect(body[offset++], 4);
    expect(
      body[offset++],
      0xc0,
    ); // SAS credentials; persistent session; no will.
    expect((body[offset++] << 8) | body[offset++], 300);
    expect(readString(), 'device-1');
    expect(
      readString(),
      'hub.azure-devices.net/device-1/?'
      'api-version=2020-09-30&DeviceClientType=azure-iot-hub-dart%2F0.1.0-dev.1',
    );
    expect(readString(), credentials().createSasToken(now: epoch).value);
    expect(offset, body.length);
    await peer.connack(twinResponses: true);
    await opening;
  });

  test('send implicitly opens the transport and completes only after matching PUBACK', () async {
    var completed = false;
    final sending = client
        .sendEvent(
          TelemetryMessage(
            [0, 127, 128, 255],
            messageId: 'a b',
            contentType: 'application/json',
            properties: {'colour': 'blå & green'},
          ),
        )
        .then((_) => completed = true);
    final peer = await server.nextConnection();
    await peer.nextPacket(1);
    await peer.connack(twinResponses: true);
    final publish = await peer.nextPacket(3);
    expect(publish.header, 0x32);
    final length = (publish.body[0] << 8) | publish.body[1];
    expect(
      utf8.decode(publish.body.sublist(2, 2 + length)),
      'devices/device-1/messages/events/%24.mid=a%20b&'
      '%24.ct=application%2Fjson&colour=bl%C3%A5%20%26%20green/',
    );
    expect(publish.body.sublist(4 + length), [0, 127, 128, 255]);
    expect(completed, isFalse);
    await peer.puback(publish.packetId + 1);
    await pumpEventQueue();
    expect(completed, isFalse);
    await peer.puback(publish.packetId);
    await sending;
    expect(client.pendingCount, 0);
  });

  test('MqttTransportHandlerOpenAsyncTokenCancellationRequested', () async {
    final source = CancellationTokenSource()..cancel();
    await expectLater(
      client.open(cancellationToken: source.token),
      throwsA(
        failure(OperationFailureReason.cancelled, DeliveryState.notSubmitted),
      ),
    );
    expect(server.peers, isEmpty);
  });

  test(
    'MqttTransportHandlerSendEventAsyncTokenCancellationRequested',
    () async {
      final source = CancellationTokenSource()..cancel();
      await expectLater(
        client.sendEvent(
          TelemetryMessage([1]),
          cancellationToken: source.token,
        ),
        throwsA(
          failure(OperationFailureReason.cancelled, DeliveryState.notSubmitted),
        ),
      );
      expect(server.peers, isEmpty);
    },
  );

  test(
    'one source cancels shared sends without cancelling an independent send',
    () async {
      final peer = await establish();
      final source = CancellationTokenSource();
      final independent = CancellationTokenSource();
      final cancelled = [
        for (var i = 0; i < 2; i++)
          expectLater(
            client.sendEvent(
              TelemetryMessage([i]),
              cancellationToken: source.token,
            ),
            throwsA(
              failure(OperationFailureReason.cancelled, DeliveryState.unknown),
            ),
          ),
      ];
      final sending = client.sendEvent(
        TelemetryMessage([2]),
        cancellationToken: independent.token,
      );
      final packets = [for (var i = 0; i < 3; i++) await peer.nextPacket(3)];
      source.cancel();
      source.cancel();
      await Future.wait(cancelled);
      expect(source.token.isCancellationRequested, isTrue);
      expect(independent.token.isCancellationRequested, isFalse);
      expect(
        client.pendingCount,
        3,
      ); // Submitted sends retain their reservations.
      for (final packet in packets) {
        await peer.puback(packet.packetId);
      }
      await sending;
      await until(() => client.pendingCount == 0);
      expect(unwrapCancellationToken(source.token)!.hasCancellables, isFalse);
      expect(
        unwrapCancellationToken(independent.token)!.hasCancellables,
        isFalse,
      );
      expect(client.isConnected, isTrue);
    },
  );

  test(
    'successful sends detach and leave the token usable for another operation',
    () async {
      final peer = await establish();
      final source = CancellationTokenSource();
      for (var i = 0; i < 2; i++) {
        final sending = client.sendEvent(
          TelemetryMessage([i]),
          cancellationToken: source.token,
        );
        final packet = await peer.nextPacket(3);
        await peer.puback(packet.packetId);
        await sending;
        expect(source.token.isCancellationRequested, isFalse);
        expect(unwrapCancellationToken(source.token)!.hasCancellables, isFalse);
      }
      source.cancel(); // Completed operations are no longer listening.
      expect(client.pendingCount, 0);
      expect(client.isConnected, isTrue);
    },
  );

  for (final reason in [
    OperationFailureReason.timeout,
    OperationFailureReason.closed,
  ]) {
    test('$reason detaches without cancelling the caller token', () async {
      final peer = await establish();
      final source = CancellationTokenSource();
      final sending = expectLater(
        client.sendEvent(
          TelemetryMessage([1]),
          cancellationToken: source.token,
        ),
        throwsA(failure(reason, DeliveryState.unknown)),
      );
      await peer.nextPacket(3);
      if (reason == OperationFailureReason.timeout) {
        time.elapse(const Duration(seconds: 10));
      } else {
        await client.close();
      }
      await sending;
      expect(source.token.isCancellationRequested, isFalse);
      expect(unwrapCancellationToken(source.token)!.hasCancellables, isFalse);
      source.cancel();
      expect(client.pendingCount, 0);
    });
  }

  test('cancelled submitted send retains capacity until PUBACK', () async {
    final peer = await establish();
    final source = CancellationTokenSource();
    final sending = expectLater(
      client.sendEvent(TelemetryMessage([1]), cancellationToken: source.token),
      throwsA(failure(OperationFailureReason.cancelled, DeliveryState.unknown)),
    );
    final packet = await peer.nextPacket(3);
    source.cancel();
    await sending;
    expect(client.pendingCount, 1);
    expect(client.pendingBytes, greaterThan(0));
    await peer.puback(packet.packetId);
    await until(() => client.pendingCount == 0);
    expect(unwrapCancellationToken(source.token)!.hasCancellables, isFalse);
    expect(client.isConnected, isTrue);
  });

  test(
    'cancelled packet without ACK retires its socket at original deadline',
    () async {
      final peer = await establish();
      final source = CancellationTokenSource();
      final sending = expectLater(
        client.sendEvent(
          TelemetryMessage([1]),
          cancellationToken: source.token,
        ),
        throwsA(
          failure(OperationFailureReason.cancelled, DeliveryState.unknown),
        ),
      );
      await peer.nextPacket(3);
      source.cancel();
      await sending;
      time.elapse(const Duration(seconds: 10));
      await peer.disconnected;
      expect(client.pendingCount, 0);
      expect(client.isConnected, isFalse);
    },
  );

  test('reconnect preserves the deadline even with a caller token', () async {
    final peer = await establish();
    final sending = expectLater(
      client.sendEvent(
        TelemetryMessage([1]),
        cancellationToken: CancellationTokenSource().token,
      ),
      throwsA(failure(OperationFailureReason.timeout, DeliveryState.unknown)),
    );
    await peer.nextPacket(3);
    time.elapse(const Duration(seconds: 6));
    await peer.close();
    await until(() => !client.isConnected);
    time.elapse(const Duration(milliseconds: 100));
    final replacement = await server.nextConnection();
    await replacement.nextPacket(1);
    await replacement.connack(twinResponses: true);
    await replacement.nextPacket(3);
    time.elapse(const Duration(milliseconds: 3900));
    await sending;
    await replacement.disconnected;
  });

  for (final minutes in [10, 51, 61]) {
    test(
      'reconnect at $minutes minutes uses the C# SAS cache window',
      () async {
        final opening = client.open();
        final first = await server.nextConnection();
        final original = connectPassword(await first.nextPacket(1));
        await first.connack(twinResponses: true);
        await opening;
        wallClockOffset = Duration(minutes: minutes);
        await first.close();
        await until(() => !client.isConnected && time.activeTimers == 1);
        time.elapse(const Duration(milliseconds: 100));
        final replacement = await server.nextConnection();
        final password = connectPassword(await replacement.nextPacket(1));
        if (minutes < 51) {
          expect(password, original);
        } else {
          expect(password, isNot(original));
          expect(
            password,
            credentials()
                .createSasToken(now: epoch.add(wallClockOffset + time.elapsed))
                .value,
          );
        }
        await replacement.connack(twinResponses: true);
        final sending = client.sendEvent(TelemetryMessage([1]));
        final publish = await replacement.nextPacket(3);
        await replacement.puback(publish.packetId);
        await sending;
        expect(server.peers, hasLength(2));
      },
    );
  }

  test(
    'healthy MQTT stays connected beyond the SAS renewal window and expiry',
    () async {
      final peer = await establish();
      // Exercise timers through 70 virtual minutes. Regular telemetry keeps the
      // connection active; the local peer does not enforce service-side expiry.
      for (var minute = 0; minute < 70; minute++) {
        time.elapse(const Duration(minutes: 1));
        final sending = client.sendEvent(TelemetryMessage([minute]));
        final publish = await peer.nextPacket(3);
        await peer.puback(publish.packetId);
        await sending;
      }
      expect(client.isConnected, isTrue);
      expect(server.peers, hasLength(1));
      expect(time.activeTimers, 1); // Only the keepalive idle check.
    },
  );

  test(
    'retry refreshes credentials even if the first connection never opened',
    () async {
      final opening = client.open();
      final first = await server.nextConnection();
      final original = connectPassword(await first.nextPacket(1));
      await first.connack(code: 3);
      await first.disconnected;
      await until(() => time.activeTimers == 2);
      wallClockOffset = const Duration(minutes: 51);
      time.elapse(const Duration(milliseconds: 100));
      final replacement = await server.nextConnection();
      final password = connectPassword(await replacement.nextPacket(1));
      expect(password, isNot(original));
      expect(
        password,
        credentials()
            .createSasToken(now: epoch.add(wallClockOffset + time.elapsed))
            .value,
      );
      await replacement.connack(twinResponses: true);
      await opening;
    },
  );

  test(
    'SAS refresh during a send preserves its deadline and delivery uncertainty',
    () async {
      final peer = await establish();
      wallClockOffset = const Duration(minutes: 61);
      final sending = expectLater(
        client.sendEvent(
          TelemetryMessage([1]),
          cancellationToken: CancellationTokenSource().token,
        ),
        throwsA(failure(OperationFailureReason.timeout, DeliveryState.unknown)),
      );
      await peer.nextPacket(3);
      time.elapse(const Duration(seconds: 6));
      await peer.close();
      await until(() => !client.isConnected && time.activeTimers == 2);
      time.elapse(const Duration(milliseconds: 100));
      final replacement = await server.nextConnection();
      expect(
        connectPassword(await replacement.nextPacket(1)),
        credentials()
            .createSasToken(now: epoch.add(wallClockOffset + time.elapsed))
            .value,
      );
      await replacement.connack(twinResponses: true);
      await replacement.nextPacket(3);
      time.elapse(const Duration(milliseconds: 3900));
      await sending;
      await replacement.disconnected;
    },
  );

  test(
    'one cancelled offline send does not stop another send or recovery',
    () async {
      final source = CancellationTokenSource();
      final cancelled = expectLater(
        client.sendEvent(
          TelemetryMessage([1]),
          cancellationToken: source.token,
        ),
        throwsA(
          failure(OperationFailureReason.cancelled, DeliveryState.notSubmitted),
        ),
      );
      final sending = client.sendEvent(TelemetryMessage([2]));
      final peer = await server.nextConnection();
      await peer.nextPacket(1);
      source.cancel();
      await cancelled;
      await peer.connack(twinResponses: true);
      final packet = await peer.nextPacket(3);
      expect(packet.body.last, 2);
      await peer.puback(packet.packetId);
      await sending;
    },
  );

  test(
    'pending capacity rejects before submission and remains bounded',
    () async {
      final peer = await establish();
      final sends = [
        for (var i = 0; i < 3; i++) client.sendEvent(TelemetryMessage([i])),
      ];
      final packets = [for (var i = 0; i < 3; i++) await peer.nextPacket(3)];
      await expectLater(
        client.sendEvent(TelemetryMessage([4])),
        throwsA(
          failure(OperationFailureReason.capacity, DeliveryState.notSubmitted),
        ),
      );
      expect(client.pendingCount, 3);
      for (final packet in packets) {
        await peer.puback(packet.packetId);
      }
      await Future.wait(sends);
    },
  );

  test(
    'authentication refusal stops recovery; a later operation can retry',
    () async {
      final opening = expectLater(
        client.open(),
        throwsA(
          failure(
            OperationFailureReason.authentication,
            DeliveryState.notSubmitted,
          ),
        ),
      );
      final peer = await server.nextConnection();
      await peer.nextPacket(1);
      await peer.connack(code: 5);
      await opening;
      await peer.disconnected;
      time.elapse(const Duration(minutes: 5));
      expect(server.peers, hasLength(1));
      expect(time.activeTimers, 0);
      final retrying = client.open();
      final next = await server.nextConnection();
      await next.nextPacket(1);
      await next.connack(twinResponses: true);
      await retrying;
    },
  );

  test(
    'untrusted TLS certificate fails without bypassing verification',
    () async {
      await client.close();
      client = InternalClient(
        credentials(),
        transport: transport,
        port: server.port,
        schedule: time.schedule,
      );
      await expectLater(
        client.open(),
        throwsA(
          failure(OperationFailureReason.tls, DeliveryState.notSubmitted),
        ),
      );
      expect(server.peers, isEmpty);
      expect(time.activeTimers, 0);
    },
  );

  test('close during CONNACK wait releases socket and settles once', () async {
    final opening = expectLater(
      client.open(),
      throwsA(
        failure(OperationFailureReason.closed, DeliveryState.notSubmitted),
      ),
    );
    final peer = await server.nextConnection();
    await peer.nextPacket(1);
    await client.close();
    await opening;
    await peer.disconnected;
    await client.close();
    await expectLater(
      client.open(),
      throwsA(
        failure(OperationFailureReason.closed, DeliveryState.notSubmitted),
      ),
    );
  });

  test('fragmented CONNACK and PUBACK are decoded once', () async {
    final sending = client.sendEvent(TelemetryMessage([1]));
    final peer = await server.nextConnection();
    await peer.nextPacket(1);
    for (final byte in [0x20, 2, 0, 0]) {
      await peer.sendBytes([byte]);
      await pumpEventQueue();
    }
    await peer.acceptTwinSubscription();
    final packet = await peer.nextPacket(3);
    for (final byte in [0x40, 2, packet.packetId >> 8, packet.packetId & 255]) {
      await peer.sendBytes([byte]);
      await pumpEventQueue();
    }
    await sending;
  });

  test(
    'connection timeout closes a stalled TLS handshake; close stops retries',
    () async {
      await client.close();
      final plain = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final connections = StreamIterator(plain);
      final sockets = <Socket>[];
      addTearDown(() async {
        for (final socket in sockets) {
          socket.destroy();
        }
        await connections.cancel();
        await plain.close();
      });
      client = InternalClient(
        credentials(),
        transport: transport,
        port: plain.port,
        securityContext: clientContext(),
        schedule: time.schedule,
        connectionTimeout: const Duration(seconds: 5),
        randomInt: (_) => 20,
      );
      final opening = expectLater(
        client.open(),
        throwsA(
          failure(OperationFailureReason.closed, DeliveryState.notSubmitted),
        ),
      );
      // Repeat the original leak scenario. Each accepted TCP socket must close
      // before its replacement; no peer ever finishes TLS or sends CONNACK.
      for (var attempt = 0; attempt < 3; attempt++) {
        expect(await connections.moveNext(), isTrue);
        final socket = connections.current;
        sockets.add(socket);
        final hello = Completer<void>();
        final closed = Completer<void>();
        socket.listen(
          (_) {
            if (!hello.isCompleted) hello.complete();
          },
          onDone: closed.complete,
          onError: closed.completeError,
        );
        await hello.future;
        time.elapse(const Duration(seconds: 5));
        await closed.future.timeout(const Duration(seconds: 2));
        if (attempt < 2) {
          await until(() => time.activeTimers == 2); // operation + retry
          time.elapse(Duration(milliseconds: attempt == 0 ? 100 : 200));
        }
      }
      await client.close();
      await opening;
    },
  );

  test(
    'close aborts a stalled TLS handshake without waiting for its deadline',
    () async {
      await client.close();
      final plain = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = Completer<Socket>();
      final listener = plain.listen(accepted.complete);
      addTearDown(() async {
        await listener.cancel();
        await plain.close();
      });
      client = InternalClient(
        credentials(),
        transport: transport,
        port: plain.port,
        schedule: time.schedule,
      );
      final opening = expectLater(
        client.open(),
        throwsA(
          failure(OperationFailureReason.closed, DeliveryState.notSubmitted),
        ),
      );
      final socket = await accepted.future;
      addTearDown(socket.destroy);
      final hello = Completer<void>();
      final closed = Completer<void>();
      socket.listen(
        (_) {
          if (!hello.isCompleted) hello.complete();
        },
        onDone: closed.complete,
        onError: closed.completeError,
      );
      await hello.future;
      await client.close();
      await opening;
      await closed.future.timeout(const Duration(seconds: 2));
      expect(time.elapsed, Duration.zero);
    },
  );

  test('byte capacity rejects before opening a connection', () async {
    await client.close();
    client = InternalClient(
      credentials(),
      maxPendingBytes: 32,
      schedule: time.schedule,
    );
    await expectLater(
      client.sendEvent(TelemetryMessage([1])),
      throwsA(
        failure(OperationFailureReason.capacity, DeliveryState.notSubmitted),
      ),
    );
    expect(server.peers, isEmpty);
    expect(client.pendingCount, 0);
  });

  test('large binary payload survives partial socket writes', () async {
    final peer = await establish();
    final bytes = List<int>.generate(0x3ffff, (i) => i & 255);
    final sending = client.sendEvent(TelemetryMessage(bytes));
    final packet = await peer.nextPacket(3);
    final length = (packet.body[0] << 8) | packet.body[1];
    expect(packet.body.sublist(length + 4), bytes);
    await peer.puback(packet.packetId);
    await sending;
  });

  test('broker unavailable retries after C# initial backoff', () async {
    final opening = client.open();
    final first = await server.nextConnection();
    await first.nextPacket(1);
    await first.connack(code: 3);
    await first.disconnected;
    await until(() => time.activeTimers == 2);
    time.elapse(const Duration(milliseconds: 99));
    expect(server.peers, hasLength(1));
    time.elapse(const Duration(milliseconds: 1));
    final replacement = await server.nextConnection();
    await replacement.nextPacket(1);
    await replacement.connack(twinResponses: true);
    await opening;
  });

  test(
    'malformed MQTT frame fails permanently without retaining input',
    () async {
      final peer = await establish();
      final sending = expectLater(
        client.sendEvent(TelemetryMessage([1])),
        throwsA(
          failure(OperationFailureReason.protocol, DeliveryState.unknown),
        ),
      );
      await peer.nextPacket(3);
      await peer.sendBytes([0x40, 0]); // PUBACK needs a two-byte identifier.
      await sending;
      await peer.disconnected;
      expect(time.activeTimers, 0);
    },
  );

  test('oversized inbound frame is rejected from its length prefix', () async {
    final peer = await establish();
    final sending = expectLater(
      client.sendEvent(TelemetryMessage([1])),
      throwsA(failure(OperationFailureReason.protocol, DeliveryState.unknown)),
    );
    await peer.nextPacket(3);
    // Announce 268,435,455 bytes without allocating or transmitting that body.
    await peer.sendBytes([0x30, 0xff, 0xff, 0xff, 0x7f]);
    await sending;
    await peer.disconnected;
    expect(client.pendingBytes, 0);
    expect(time.activeTimers, 0);
  });

  test(
    'unanswered PINGREQ retires the connection after thirty seconds',
    () async {
      final peer = await establish();
      time.elapse(const Duration(seconds: 150));
      await peer.nextPacket(12);
      time.elapse(const Duration(seconds: 29));
      expect(client.isConnected, isTrue);
      time.elapse(const Duration(seconds: 1));
      await peer.disconnected;
      expect(client.isConnected, isFalse);
    },
  );

  test(
    'PINGRESP clears the watchdog and schedules the next idle check',
    () async {
      final peer = await establish();
      time.elapse(const Duration(seconds: 150));
      await peer.nextPacket(12);
      await peer.sendBytes([0xd0, 0]);
      // A subsequent PUBACK proves the preceding PINGRESP was processed. Merely
      // pumping the event queue does not guarantee that TLS input has arrived.
      final sending = client.sendEvent(TelemetryMessage([1]));
      final publish = await peer.nextPacket(3);
      await peer.puback(publish.packetId);
      await sending;
      time.elapse(const Duration(seconds: 30));
      expect(client.isConnected, isTrue);
    },
  );

  test(
    'external SAS is passed unchanged; the service decides its validity',
    () async {
      await client.close();
      final token = credentials().createSasToken(
        now: epoch,
        timeToLive: const Duration(seconds: 1),
      );
      final supplied = IotHubConnectionString.parse(
        'HostName=hub.azure-devices.net;DeviceId=device-1;'
        'GatewayHostName=127.0.0.1;SharedAccessSignature=${token.value}',
        now: epoch,
      );
      client = InternalClient(
        supplied,
        transport: transport,
        port: server.port,
        securityContext: clientContext(),
        now: () => epoch.add(const Duration(seconds: 2)),
        schedule: time.schedule,
      );
      final opening = expectLater(
        client.open(),
        throwsA(
          failure(
            OperationFailureReason.authentication,
            DeliveryState.notSubmitted,
          ),
        ),
      );
      final peer = await server.nextConnection();
      final packet = await peer.nextPacket(1);
      final passwordBytes = utf8.encode(token.value);
      expect(
        packet.body.sublist(packet.body.length - passwordBytes.length),
        passwordBytes,
      );
      await peer.connack(code: 5);
      await opening;
      expect(time.activeTimers, 0);
    },
  );

  test(
    'SAS is never printed even when MQTT global logging is enabled',
    () async {
      final logs = <String>[];
      try {
        MqttLogger.loggingOn = true;
        await runZoned(
          () async {
            await establish();
            await client.close();
          },
          zoneSpecification: ZoneSpecification(
            print: (_, _, _, line) => logs.add(line),
          ),
        );
      } finally {
        MqttLogger.loggingOn = false;
      }
      expect(logs.join('\n'), isNot(contains('SharedAccessSignature')));
      expect(logs.join('\n'), isNot(contains('c2VjcmV0')));
    },
  );
}
