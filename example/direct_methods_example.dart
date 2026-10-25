import 'dart:convert';
import 'dart:io';

import 'package:azure_iot_hub/azure_iot_hub.dart';

Future<void> main() async {
  final connectionString =
      Platform.environment['AZURE_IOT_DEVICE_CONNECTION_STRING'];
  if (connectionString == null || connectionString.isEmpty) {
    throw StateError('Set AZURE_IOT_DEVICE_CONNECTION_STRING before running.');
  }
  final client = DeviceClient.fromConnectionString(connectionString);
  try {
    await client.setMethodHandler('getStatus', (_) async {
      return MethodResponse(200, result: utf8.encode('{"ready":true}'));
    });
    await client.setMethodDefaultHandler((_) async => .new(501));
    print(
      'READY: Invoke getStatus with {} from the test device in Azure Portal.',
    );
    print('Expect method status 200 and payload {"ready":true}.');
    print('An unregistered method returns 501. Press Ctrl+C to close.');
    await ProcessSignal.sigint.watch().first;
  } on OperationFailure catch (error) {
    stderr.writeln(
      'Operation failed: ${error.reason.name}; '
      'delivery: ${error.delivery.name}',
    );
    exitCode = 1;
  } finally {
    await client.close();
  }
}
