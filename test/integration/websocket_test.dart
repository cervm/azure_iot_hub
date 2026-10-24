import 'dart:convert';
import 'dart:io';

import 'package:azure_iot_hub/azure_iot_hub.dart';
import 'package:test/test.dart';

void main() {
  test(
    'real IoT Hub accepts telemetry and returns a twin over secure WebSockets',
    () async {
      final value =
          Platform.environment['AZURE_IOT_TEST_DEVICE_CONNECTION_STRING'];
      if (value == null || value.isEmpty) {
        throw StateError(
          'Configure AZURE_IOT_TEST_DEVICE_CONNECTION_STRING for a dedicated test device.',
        );
      }
      final client = DeviceClient.fromConnectionString(
        value,
        transport: .webSocket,
        operationTimeout: const Duration(seconds: 30),
      );
      try {
        await client.open();
        await client.sendEvent(
          TelemetryMessage(
            utf8.encode(jsonEncode({'sdkWebSocketSmokeTest': true})),
            contentType: 'application/json',
            contentEncoding: 'utf-8',
          ),
        );
        final twin = await client.getTwin();
        expect(twin.properties.desired?[r'$version'] is int, isTrue);
        expect(twin.properties.reported?[r'$version'] is int, isTrue);
      } finally {
        await client.close();
      }
    },
    skip: Platform.environment['AZURE_IOT_RUN_INTEGRATION'] != '1'
        ? 'Opt in with AZURE_IOT_RUN_INTEGRATION=1 and a dedicated test device.'
        : false,
    timeout: const Timeout(Duration(seconds: 105)),
  );
}
