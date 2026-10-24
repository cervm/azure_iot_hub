import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:azure_iot_hub/src/authentication/iot_hub_connection_string.dart';
import 'package:azure_iot_hub/src/device_client.dart';
import 'package:azure_iot_hub/src/twin.dart';
import 'package:test/test.dart';

void main() {
  test(
    'real IoT Hub delivers desired patches before and after re-registration',
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
      final property =
          'sdkDesiredTest_${newTwinRequestId().replaceAll('-', '')}';

      Future<int> receivePatch(int expected) async {
        final received = Completer<Map<String, Object?>>();
        await client.setDesiredPropertyUpdateCallback((patch) {
          if (patch[property] == expected && !received.isCompleted) {
            received.complete(patch);
          }
        });
        print(
          'STEP $expected READY: In the test device twin, add/update this entry '
          'inside properties.desired and save within 3 minutes:\n'
          '${jsonEncode({property: expected})}',
        );
        final patch = await received.future.timeout(
          const Duration(minutes: 3),
          onTimeout: () => throw StateError(
            'No matching desired-property patch arrived for step $expected.',
          ),
        );
        // Assert booleans so failures never print the device's property values.
        final version = patch[r'$version'];
        expect(version is int, isTrue);
        print('STEP $expected RECEIVED: matching patch and version verified.');
        return version as int;
      }

      try {
        final firstVersion = await receivePatch(1);
        await client.setDesiredPropertyUpdateCallback(null);
        final secondVersion = await receivePatch(2);
        expect(secondVersion > firstVersion, isTrue);
        expect(client.pendingCount, 0);
      } finally {
        await client.close();
        print(
          'CLEANUP: If added, set "$property" to null in properties.desired '
          'in the portal and save to delete it. The device client cannot delete desired properties.',
        );
      }
    },
    // A separate opt-in keeps ordinary live test runs free of manual prompts.
    skip: Platform.environment['AZURE_IOT_RUN_MANUAL_DESIRED'] != '1'
        ? 'Opt in with AZURE_IOT_RUN_MANUAL_DESIRED=1; requires two portal edits.'
        : false,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
