import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:azure_iot_hub/azure_iot_hub.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

void main() {
  test(
    'real IoT Hub delivers C2D messages through polling and a callback',
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
        transport:
            Platform.environment['AZURE_IOT_TEST_TRANSPORT'] == 'webSocket'
            ? .webSocket
            : .tcp,
        operationTimeout: const .new(seconds: 30),
      );
      final marker = const Uuid().v4();

      void ready(int step) {
        print(
          'STEP $step READY: Send this cloud-to-device message body to the '
          'test device from Azure Portal within 3 minutes:\n'
          '${jsonEncode({'sdkC2dTest': marker, 'step': step})}',
        );
      }

      Future<void> verifyAndComplete(
        CloudToDeviceMessage? message,
        int step,
      ) async {
        if (message == null) throw StateError('No C2D message arrived.');
        // Never print an unexpected application's payload or message properties.
        Object? body;
        try {
          body = jsonDecode(utf8.decode(message.payload));
        } catch (_) {
          throw StateError('The message body was not the expected JSON.');
        }
        expect(
          body is Map && body['sdkC2dTest'] == marker && body['step'] == step,
          isTrue,
          reason: 'The received message did not match this test step.',
        );
        await client.complete(message);
        print(
          'STEP $step RECEIVED: matching body verified; completion submitted.',
        );
      }

      try {
        await client.open();
        final first = client.receive(timeout: const .new(minutes: 3));
        ready(1);
        await verifyAndComplete(await first, 1);
        final second = Completer<CloudToDeviceMessage>();
        await client.setReceiveMessageHandler((message) {
          if (!second.isCompleted) second.complete(message);
        });
        ready(2);
        await verifyAndComplete(
          await second.future.timeout(const .new(minutes: 3)),
          2,
        );
        await client.setReceiveMessageHandler(null);
      } finally {
        await client.close();
      }
    },
    skip: Platform.environment['AZURE_IOT_RUN_MANUAL_C2D'] != '1'
        ? 'Opt in with AZURE_IOT_RUN_MANUAL_C2D=1; requires two portal messages.'
        : false,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
