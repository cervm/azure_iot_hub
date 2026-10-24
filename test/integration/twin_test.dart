import 'dart:io';

import 'package:azure_iot_hub/src/authentication/iot_hub_connection_string.dart';
import 'package:azure_iot_hub/src/device_client.dart';
import 'package:test/test.dart';

void main() {
  test(
    'real IoT Hub returns twin properties over TLS',
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
        final twin = await client.getTwin();
        // Report only validation booleans, never the device's property values.
        expect(twin.desired?[r'$version'] is int, isTrue);
        expect(twin.reported?[r'$version'] is int, isTrue);
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
