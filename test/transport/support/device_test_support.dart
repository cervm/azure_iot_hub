import 'dart:convert';
import 'dart:io';

import 'package:azure_iot_hub/src/authentication/iot_hub_connection_string.dart';
import 'package:azure_iot_hub/src/pending_operation.dart';
import 'package:test/test.dart';

import '../../prototype/support/mqtt_peer.dart';

const certificate = 'test/transport/fixtures/localhost-cert.pem';
const privateKey = 'test/transport/fixtures/localhost-key.pem';
final epoch = DateTime.utc(2026, 10, 24);

SecurityContext serverContext() => SecurityContext()
  ..useCertificateChain(certificate)
  ..usePrivateKey(privateKey);
SecurityContext clientContext() =>
    SecurityContext()
      ..setTrustedCertificates('test/transport/fixtures/ca-cert.pem');

IotHubConnectionString credentials() => IotHubConnectionString.parse(
  'HostName=hub.azure-devices.net;DeviceId=device-1;'
  'GatewayHostName=127.0.0.1;SharedAccessKey=c2VjcmV0',
  now: epoch,
);

Matcher failure(OperationFailureReason reason, DeliveryState delivery) =>
    isA<OperationFailure>()
        .having((error) => error.reason, 'reason', reason)
        .having((error) => error.delivery, 'delivery', delivery);

Future<void> until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('I/O condition did not settle.');
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

String connectPassword(Packet packet) {
  // MQTT 3.1.1 variable header, then client ID, username and password (no will).
  var offset = 10;
  final fields = <String>[];
  while (offset < packet.body.length) {
    final length = (packet.body[offset] << 8) | packet.body[offset + 1];
    offset += 2;
    fields.add(utf8.decode(packet.body.sublist(offset, offset + length)));
    offset += length;
  }
  expect(fields, hasLength(3));
  return fields.last;
}
