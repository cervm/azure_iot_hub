import 'dart:convert';
import 'dart:io';

import 'package:azure_iot_hub/src/authentication/iot_hub_connection_string.dart';
import 'package:azure_iot_hub/src/device_client.dart';
import 'package:azure_iot_hub/src/telemetry_message.dart';
import 'package:test/test.dart';

void main() {
  test(
    'real IoT Hub accepts QoS 1 telemetry over TLS',
    () async {
      final value =
          Platform.environment['AZURE_IOT_TEST_DEVICE_CONNECTION_STRING'];
      if (value == null || value.isEmpty) {
        throw StateError(
          'Configure AZURE_IOT_TEST_DEVICE_CONNECTION_STRING for a dedicated test device.',
        );
      }
      final client = DeviceClient(
        IotHubConnectionString.parse(value, now: DateTime.now().toUtc()),
        operationTimeout: const Duration(seconds: 30),
      );
      try {
        await client.sendEvent(
          TelemetryMessage(
            utf8.encode(jsonEncode({'sdkSmokeTest': true})),
            messageId: 'dart-smoke-${DateTime.now().microsecondsSinceEpoch}',
            contentType: 'application/json',
            contentEncoding: 'utf-8',
          ),
        );
        expect(client.pendingCount, 0);
      } finally {
        await client.close();
      }
    },
    skip: Platform.environment['AZURE_IOT_RUN_INTEGRATION'] != '1'
        ? 'Opt in with AZURE_IOT_RUN_INTEGRATION=1 and a dedicated test device.'
        : false,
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
