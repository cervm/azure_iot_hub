import 'dart:io';

import 'package:azure_iot_hub/src/authentication/iot_hub_connection_string.dart';
import 'package:azure_iot_hub/src/device_client.dart';
import 'package:azure_iot_hub/src/twin.dart';
import 'package:test/test.dart';

void main() {
  test(
    'real IoT Hub applies and deletes reported-property patches over TLS',
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
      final property = 'sdkPatchTest_${newTwinRequestId().replaceAll('-', '')}';
      try {
        await client.updateReportedProperties({
          property: {'value': 'first', 'keep': true, 'removeMe': true},
        });
        await client.updateReportedProperties({
          property: {'value': 'second', 'removeMe': null},
        });
        final entry = (await client.getTwin()).reported?[property];
        // Assert booleans so failures never print device property collections.
        expect(
          entry is Map &&
              entry['value'] == 'second' &&
              entry['keep'] == true &&
              !entry.containsKey('removeMe'),
          isTrue,
        );
      } finally {
        try {
          await client.updateReportedProperties({property: null});
          final reported = (await client.getTwin()).reported;
          expect(reported != null && !reported.containsKey(property), isTrue);
        } finally {
          await client.close();
        }
      }
    },
    skip: Platform.environment['AZURE_IOT_RUN_INTEGRATION'] != '1'
        ? 'Opt in with AZURE_IOT_RUN_INTEGRATION=1 and a dedicated test device.'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
