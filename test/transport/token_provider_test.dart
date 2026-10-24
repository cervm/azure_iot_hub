// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license; see third_party/azure-iot-sdk-csharp-LICENSE.
// Exercises C# token-refresh and error-pipeline behaviour with Dart lifecycle
// races and the agreed finite operation deadlines. See docs/upstream.md.
import 'dart:async';
import 'dart:io';

import 'package:azure_iot_hub/azure_iot_hub.dart';
import 'package:azure_iot_hub/src/authentication/iot_hub_connection_string.dart';
import 'package:azure_iot_hub/src/cancellation.dart'
    show unwrapCancellationToken;
import 'package:azure_iot_hub/src/internal_client.dart';
import 'package:azure_iot_hub/src/transport/connection_diagnostics.dart';
import 'package:cancellation_token/cancellation_token.dart'
    show CancelledException;
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
  late SasTokenProvider provider;
  late Duration wallClockOffset;
  late int calls;

  DateTime now() => epoch.add(time.elapsed + wallClockOffset);
  String token() => credentials().createSasToken(now: now()).value;

  setUp(() async {
    server = await switch (transport) {
      MqttTransportType.tcp => MqttPeerServer.startTls(serverContext()),
      MqttTransportType.webSocket => MqttPeerServer.startWebSocket(
        serverContext(),
      ),
    };
    time = ManualTime();
    wallClockOffset = Duration.zero;
    calls = 0;
    provider = (_, _) async => token();
    client = InternalClient(
      IotHubConnectionString.withTokenProvider(
        hostName: 'hub.azure-devices.net',
        deviceId: 'device-1',
        gatewayHostName: '127.0.0.1',
        tokenProvider: (host, ttl) {
          calls++;
          expect(host, 'hub.azure-devices.net');
          expect(ttl, 3600);
          return provider(host, ttl);
        },
      ),
      transport: transport,
      port: server.port,
      securityContext: clientContext(),
      operationTimeout: const Duration(seconds: 10),
      connectionTimeout: const Duration(seconds: 5),
      maxPending: 3,
      schedule: time.schedule,
      now: now,
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
    expect(connectPassword(await peer.nextPacket(1)), token());
    await peer.connack(twinResponses: true);
    await opening;
    return peer;
  }

  test('pre-cancellation does not invoke the provider', () async {
    await expectLater(
      client.open(
        cancellationToken: (CancellationTokenSource()..cancel()).token,
      ),
      throwsA(
        failure(OperationFailureReason.cancelled, DeliveryState.notSubmitted),
      ),
    );
    expect(calls, 0);
    expect(server.peers, isEmpty);
  });

  test(
    'cancelling one caller preserves shared acquisition and another send',
    () async {
      final acquisition = Completer<String>();
      provider = (_, _) => acquisition.future;
      final cancellation = CancellationTokenSource();
      final cancelled = expectLater(
        client.open(cancellationToken: cancellation.token),
        throwsA(
          failure(OperationFailureReason.cancelled, DeliveryState.notSubmitted),
        ),
      );
      final sending = client.sendEvent(TelemetryMessage([1]));
      await until(() => calls == 1);
      cancellation.cancel();
      await cancelled;
      expect(
        unwrapCancellationToken(cancellation.token)!.hasCancellables,
        isFalse,
      );
      expect(client.pendingCount, 1);
      expect(server.peers, isEmpty);
      acquisition.complete(token());
      final peer = await server.nextConnection();
      expect(connectPassword(await peer.nextPacket(1)), token());
      await peer.connack(twinResponses: true);
      final publish = await peer.nextPacket(3);
      await peer.puback(publish.packetId);
      await sending;
      expect(calls, 1);
    },
  );

  test(
    'stalled acquisition is bounded for callers without overlapping providers',
    () async {
      final acquisition = Completer<String>();
      provider = (_, _) =>
          calls == 1 ? acquisition.future : Future.value(token());
      final expired = expectLater(
        client.open(cancellationToken: CancellationTokenSource().token),
        throwsA(
          failure(OperationFailureReason.timeout, DeliveryState.notSubmitted),
        ),
      );
      await until(() => calls == 1);
      time.elapse(const Duration(seconds: 10));
      await expired;
      expect(client.pendingCount, 0);
      expect(
        client.connectionDiagnostics.failureStage,
        ConnectionStage.authentication,
      );
      expect(client.connectionDiagnostics.failure, 'timeout');
      final next = client.open();
      time.elapse(const Duration(seconds: 5));
      expect(calls, 1);
      expect(time.activeTimers, 1); // Only the new caller's deadline.
      acquisition.complete(token());
      await until(
        () => time.activeTimers == 2,
      ); // Retry after acquisition settles.
      expect(server.peers, isEmpty); // The expired attempt cannot connect late.
      time.elapse(const Duration(milliseconds: 100));
      final peer = await server.nextConnection();
      await peer.nextPacket(1);
      await peer.connack(twinResponses: true);
      await next;
      expect(
        calls,
        1,
      ); // The completed acquisition remains usable by the cache.
    },
  );

  test(
    'acquisition and transport setup share the original connection deadline',
    () async {
      final acquisition = Completer<String>();
      provider = (_, _) => acquisition.future;
      final opening = expectLater(
        client.open(),
        throwsA(
          failure(OperationFailureReason.closed, DeliveryState.notSubmitted),
        ),
      );
      await until(() => calls == 1);
      time.elapse(const Duration(seconds: 4));
      acquisition.complete(token());
      final peer = await server.nextConnection();
      await peer.nextPacket(1); // Withhold CONNACK.
      time.elapse(const Duration(seconds: 1));
      await peer.disconnected;
      expect(client.connectionDiagnostics.failure, 'timeout');
      expect(
        client.connectionDiagnostics.failureStage,
        ConnectionStage.mqttConnack,
      );
      await client.close();
      await opening;
    },
  );

  for (final lateFailure in [false, true]) {
    test(
      'close settles during acquisition and ignores its late result ($lateFailure)',
      () async {
        final acquisition = Completer<String>();
        provider = (_, _) => acquisition.future;
        final opening = expectLater(
          client.open(),
          throwsA(
            failure(OperationFailureReason.closed, DeliveryState.notSubmitted),
          ),
        );
        await until(() => calls == 1);
        await client.close();
        await opening;
        expect(time.activeTimers, 0);
        if (lateFailure) {
          acquisition.completeError(StateError('provider secret'));
        } else {
          acquisition.complete(token());
        }
        await Future<void>.delayed(Duration.zero);
        time.elapse(const Duration(minutes: 5));
        expect(calls, 1);
        expect(server.peers, isEmpty);
        expect(client.connectionDiagnostics.failure, isNull);
      },
    );
  }

  for (final error in [
    const SocketException('provider secret'),
    const HttpException('provider secret'),
    TimeoutException('provider secret'),
    const CancelledException(cancellationReason: 'provider secret'),
  ]) {
    test(
      '${error.runtimeType} retries within the original operation deadline',
      () async {
        provider = (_, _) async => throw error;
        final opening = expectLater(
          client.open(),
          throwsA(
            failure(OperationFailureReason.timeout, DeliveryState.notSubmitted),
          ),
        );
        await until(() => calls == 1 && time.activeTimers == 2);
        time.elapse(const Duration(milliseconds: 100));
        await until(() => calls == 2 && time.activeTimers == 2);
        expect(
          client.connectionDiagnostics.failure,
          error is TimeoutException ? 'timeout' : 'network',
        );
        expect(
          client.connectionDiagnostics.toString(),
          isNot(contains('provider secret')),
        );
        expect(server.peers, isEmpty);
        time.elapse(const Duration(milliseconds: 9900));
        await opening;
      },
    );
  }

  for (final (error, reason) in [
    (
      const FormatException('provider secret'),
      OperationFailureReason.authentication,
    ),
    (StateError('provider secret'), OperationFailureReason.authentication),
    (const HandshakeException('provider secret'), OperationFailureReason.tls),
  ]) {
    test(
      '${error.runtimeType} stops recovery without exposing provider details',
      () async {
        provider = (_, _) => throw error;
        await expectLater(
          client.open(),
          throwsA(failure(reason, DeliveryState.notSubmitted)),
        );
        await Future<void>.delayed(Duration.zero);
        time.elapse(const Duration(minutes: 5));
        expect(calls, 1);
        expect(server.peers, isEmpty);
        expect(time.activeTimers, 0);
        expect(
          client.connectionDiagnostics.failureStage,
          ConnectionStage.authentication,
        );
        expect(client.connectionDiagnostics.failure, reason.name);
        expect(
          client.connectionDiagnostics.toString(),
          isNot(contains('provider secret')),
        );
      },
    );
  }

  test('malformed provider SAS fails before network setup', () async {
    provider = (_, _) async => 'malformed secret';
    await expectLater(
      client.open(),
      throwsA(
        failure(
          OperationFailureReason.authentication,
          DeliveryState.notSubmitted,
        ),
      ),
    );
    expect(server.peers, isEmpty);
    expect(client.connectionDiagnostics.toString(), isNot(contains('secret')));
  });

  for (final minutes in [10, 51, 61]) {
    test(
      'reconnect at $minutes minutes requests a provider token only when eligible',
      () async {
        final first = await establish();
        final original = token();
        wallClockOffset = Duration(minutes: minutes);
        await first.close();
        await until(() => !client.isConnected && time.activeTimers == 1);
        time.elapse(const Duration(milliseconds: 100));
        final replacement = await server.nextConnection();
        expect(
          connectPassword(await replacement.nextPacket(1)),
          minutes < 51 ? original : token(),
        );
        expect(calls, minutes < 51 ? 1 : 2);
        await replacement.connack(twinResponses: true);
        await until(() => client.isConnected);
      },
    );
  }

  test('provider acquisition during reconnect preserves delivery uncertainty and deadline', () async {
    final peer = await establish();
    final sending = expectLater(
      client.sendEvent(TelemetryMessage([1])),
      throwsA(failure(OperationFailureReason.timeout, DeliveryState.unknown)),
    );
    await peer.nextPacket(3); // Withhold PUBACK.
    time.elapse(const Duration(seconds: 6));
    wallClockOffset = const Duration(hours: 1);
    final acquisition = Completer<String>();
    provider = (_, _) => acquisition.future;
    await peer.close();
    await until(() => !client.isConnected && time.activeTimers == 2);
    time.elapse(const Duration(milliseconds: 100));
    await until(() => calls == 2);
    time.elapse(const Duration(milliseconds: 3900));
    await sending;
    await client.close();
    acquisition.complete(token());
    await Future<void>.delayed(Duration.zero);
    expect(server.peers, hasLength(1));
  });
}
