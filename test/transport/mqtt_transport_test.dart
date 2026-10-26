// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license; see third_party/azure-iot-sdk-csharp-LICENSE.
// QoS rejection follows MqttIotHubAdapter.ProcessPublish at the pinned commit.
// Dependency retention and wire assertions cover the Dart storage boundary.
import 'package:azure_iot_hub/src/transport/mqtt_transport.dart';
import 'package:azure_iot_hub/src/transport/mqtt_transport_type.dart';
import 'package:test/test.dart';

import '../prototype/support/mqtt_peer.dart';
import 'support/device_test_support.dart';

void main() {
  for (final transport in MqttTransportType.values) {
    test('${transport.name}: rejects QoS 2 before dependency retention', () async {
      final server = await switch (transport) {
        .tcp => MqttPeerServer.startTls(serverContext()),
        .webSocket => MqttPeerServer.startWebSocket(serverContext()),
      };
      final mqtt = MqttTransport(
        '127.0.0.1',
        'device-1',
        port: server.port,
        transport: transport,
        maxBufferedBytes: 512,
        securityContext: clientContext(),
      );
      addTearDown(() async {
        mqtt.retire();
        await server.close();
      });
      final connecting = mqtt.connect('user', 'password');
      final peer = await server.nextConnection();
      await peer.nextPacket(1);
      await peer.connack();
      await connecting;
      // Retain the map so dependency disposal cannot hide a dispatch violation.
      // ignore: invalid_use_of_protected_member
      final received = mqtt.publishingManager!.receivedMessages;
      await peer.publish(
        'devices/device-1/messages/devicebound/',
        List.filled(400, 0),
        qos: 2,
      );
      await peer.disconnected.timeout(const Duration(seconds: 3));
      expect(mqtt.failure?.kind, TransportFailureKind.protocol);
      expect(received, isEmpty);
      // No PUBREC may be sent for the rejected publication.
      await expectLater(peer.nextPacket(5), throwsStateError);
    });
  }
}
