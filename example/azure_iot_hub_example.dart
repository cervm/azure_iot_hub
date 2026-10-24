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
    await client.sendEvent(
      .new(
        utf8.encode(jsonEncode({'temperature': 21.5})),
        contentType: 'application/json',
        contentEncoding: 'utf-8',
      ),
    );
    final twin = await client.getTwin();
    print(
      'Telemetry acknowledged; desired version: '
      '${twin.properties.desired?[r'$version']}',
    );
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
