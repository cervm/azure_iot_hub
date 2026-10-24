import 'dart:io';

import 'package:azure_iot_hub/azure_iot_hub.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

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
      final client = DeviceClient.fromConnectionString(
        value,
        operationTimeout: const Duration(seconds: 30),
      );
      final property = 'sdkPatchTest_${const Uuid().v4().replaceAll('-', '')}';
      try {
        await client.updateReportedProperties({
          property: {'value': 'first', 'keep': true, 'removeMe': true},
        });
        await client.updateReportedProperties({
          property: {'value': 'second', 'removeMe': null},
        });
        final entry = (await client.getTwin()).properties.reported?[property];
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
          final reported = (await client.getTwin()).properties.reported;
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
