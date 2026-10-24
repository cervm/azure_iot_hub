import 'dart:convert';

import 'package:azure_iot_hub/azure_iot_hub.dart';
import 'package:test/test.dart';

import 'prototype/support/mqtt_peer.dart';
import 'transport/support/device_test_support.dart';

const connectionString =
    'HostName=hub.azure-devices.net;DeviceId=device-1;'
    'GatewayHostName=127.0.0.1;SharedAccessKey=c2VjcmV0';
const providerToken =
    'SharedAccessSignature '
    'sr=hub.azure-devices.net%2Fdevices%2Fdevice-1&sig=test&se=4102444800';

void main() {
  test('connection-string validation redacts credentials', () {
    expect(
      () => DeviceClient.fromConnectionString('secret-credential'),
      throwsA(
        isA<FormatException>()
            .having((error) => error.source, 'source', isNull)
            .having(
              (error) => error.toString(),
              'diagnostic',
              isNot(contains('secret-credential')),
            ),
      ),
    );
  });

  test('both constructors validate timeout and capacity options', () {
    expect(
      () => DeviceClient.fromConnectionString(
        connectionString,
        operationTimeout: Duration.zero,
      ),
      throwsArgumentError,
    );
    expect(
      () => DeviceClient.withTokenProvider(
        hostName: 'hub.azure-devices.net',
        deviceId: 'device-1',
        tokenProvider: (_, _) async => providerToken,
        maxPending: 0,
      ),
      throwsArgumentError,
    );
  });

  for (final deviceId in ['device+1', 'device#1']) {
    test(
      'invalid publication topic for $deviceId exposes a redacted argument error',
      () async {
        final client = DeviceClient.fromConnectionString(
          connectionString.replaceFirst('device-1', deviceId),
        );
        try {
          await expectLater(
            () => client.sendEvent(.new([])),
            throwsA(
              isA<ArgumentError>()
                  .having((error) => error.invalidValue, 'invalidValue', isNull)
                  .having(
                    (error) => error.toString(),
                    'diagnostic',
                    allOf(
                      isNot(contains(deviceId)),
                      isNot(contains('mqtt_client')),
                    ),
                  ),
            ),
          );
          expect(client.isConnected, isFalse);
        } finally {
          await client.close();
        }
      },
    );
  }

  for (final transport in MqttTransportType.values) {
    group(transport.name, () => transportTests(transport));
  }
}

void transportTests(MqttTransportType transport) {
  late MqttPeerServer server;
  late DeviceClient client;

  setUp(() async {
    server = await switch (transport) {
      .tcp => MqttPeerServer.startTls(serverContext()),
      .webSocket => MqttPeerServer.startWebSocket(serverContext()),
    };
    client = .fromConnectionString(
      connectionString,
      transport: transport,
      port: server.port,
      securityContext: clientContext(),
      operationTimeout: const .new(seconds: 10),
      maxPending: 1,
      maxPendingBytes: 2048,
    );
  });

  tearDown(() async {
    await client.close();
    await server.close();
  });

  Future<MqttPeer> accept() async {
    final peer = await server.nextConnection();
    await peer.nextPacket(1);
    await peer.connack(twinResponses: true);
    return peer;
  }

  test(
    'public operations send telemetry and exchange twin properties',
    () async {
      expect(client.isConnected, isFalse);
      expect(server.peers, isEmpty);
      final sending = client.sendEvent(
        .new(utf8.encode('sample'), messageId: 'public-api'),
      );
      final peer = await accept();
      final telemetry = await peer.nextPacket(3);
      expect(
        telemetry.topic,
        'devices/device-1/messages/events/%24.mid=public-api/',
      );
      expect(
        utf8.decode(
          telemetry.body.sublist(utf8.encode(telemetry.topic).length + 4),
        ),
        'sample',
      );
      await peer.puback(telemetry.packetId);
      await sending;
      expect(client.isConnected, isTrue);

      final getting = client.getTwin();
      final get = await peer.nextPacket(3);
      await peer.puback(get.packetId);
      await respond(
        peer,
        requestId(get),
        body:
            r'{"desired":{"target":21,"$version":3},"reported":{"actual":20}}',
      );
      final Twin twin = await getting;
      expect(twin.properties.desired, {'target': 21, r'$version': 3});
      expect(twin.properties.reported, {'actual': 20});

      final updating = client.updateReportedProperties({
        'actual': 21,
        'old': null,
      });
      final patch = await peer.nextPacket(3);
      expect(
        jsonDecode(
          utf8.decode(patch.body.sublist(utf8.encode(patch.topic).length + 4)),
        ),
        {'actual': 21, 'old': null},
      );
      await peer.puback(patch.packetId);
      await respond(peer, requestId(patch), status: 204, body: '');
      await updating;

      final received = <Map<String, Object?>>[];
      final registering = client.setDesiredPropertyUpdateCallback(received.add);
      final subscription = await peer.nextPacket(8);
      await peer.suback((subscription.body[0] << 8) | subscription.body[1]);
      await registering;
      await peer.publish(
        r'$iothub/twin/PATCH/properties/desired/?$version=4',
        utf8.encode(r'{"target":22,"$version":4}'),
      );
      await peer.nextPacket(4);
      expect(received, [
        {'target': 22, r'$version': 4},
      ]);
      // Delivery of a patch does not merge it into an earlier snapshot.
      expect(twin.properties.desired?['target'], 21);

      final removing = client.setDesiredPropertyUpdateCallback(null);
      final unsubscribe = await peer.nextPacket(10);
      await peer.unsuback((unsubscribe.body[0] << 8) | unsubscribe.body[1]);
      await removing;
      await client.close();
      await client.close();
      expect(client.isConnected, isFalse);
      await expectLater(
        client.open(),
        throwsA(failure(.closed, .notSubmitted)),
      );
    },
  );

  test(
    'provider construction is lazy and passes hub, TTL and returned token',
    () async {
      await client.close();
      var calls = 0;
      Future<String> provider(String host, int ttl) async {
        calls++;
        expect(host, 'hub.azure-devices.net');
        expect(ttl, 3600);
        return providerToken;
      }

      client = .withTokenProvider(
        hostName: 'hub.azure-devices.net',
        deviceId: 'device-1',
        gatewayHostName: '127.0.0.1',
        tokenProvider: provider,
        transport: transport,
        port: server.port,
        securityContext: clientContext(),
        operationTimeout: const .new(seconds: 10),
      );
      expect(calls, 0);
      final opening = client.open();
      final peer = await server.nextConnection();
      expect(connectPassword(await peer.nextPacket(1)), providerToken);
      await peer.connack(twinResponses: true);
      await opening;
      await client.open();
      expect(calls, 1);
      expect(client.isConnected, isTrue);
    },
  );

  test(
    'every cancellable operation accepts a pre-cancelled public token',
    () async {
      final source = CancellationTokenSource()..cancel();
      final operations = <Future<void> Function()>[
        () => client.open(cancellationToken: source.token),
        () => client.sendEvent(.new([]), cancellationToken: source.token),
        () => client.getTwin(cancellationToken: source.token),
        () => client.updateReportedProperties(
          {},
          cancellationToken: source.token,
        ),
        () => client.setDesiredPropertyUpdateCallback(
          (_) {},
          cancellationToken: source.token,
        ),
      ];
      for (final operation in operations) {
        await expectLater(
          operation(),
          throwsA(failure(.cancelled, .notSubmitted)),
        );
      }
      expect(server.peers, isEmpty);
    },
  );

  test(
    'submitted cancellation exposes uncertainty and retains its capacity',
    () async {
      final source = CancellationTokenSource();
      final sending = expectLater(
        client.sendEvent(.new([1]), cancellationToken: source.token),
        throwsA(failure(.cancelled, .unknown)),
      );
      final peer = await accept();
      await peer.nextPacket(3);
      source.cancel();
      await sending;
      await expectLater(
        client.sendEvent(.new([2])),
        throwsA(failure(.capacity, .notSubmitted)),
      );
      expect(client.isConnected, isTrue);
    },
  );

  test(
    'twin service errors expose status and delivery through the public type',
    () async {
      final getting = expectLater(
        client.getTwin(),
        throwsA(
          isA<OperationFailure>()
              .having(
                (error) => error.reason,
                'reason',
                OperationFailureReason.service,
              )
              .having(
                (error) => error.delivery,
                'delivery',
                DeliveryState.unknown,
              )
              .having((error) => error.statusCode, 'statusCode', 403),
        ),
      );
      final peer = await accept();
      final request = await peer.nextPacket(3);
      await peer.puback(request.packetId);
      await respond(peer, requestId(request), status: 403, body: '');
      await getting;
    },
  );
}
