import 'dart:convert';
import 'dart:io';

import 'package:azure_iot_hub/azure_iot_hub.dart';
import 'package:test/test.dart';

void main() {
  final transport =
      Platform.environment['AZURE_IOT_TEST_TRANSPORT'] == 'webSocket'
      ? MqttTransportType.webSocket
      : MqttTransportType.tcp;
  test(
    'real IoT Hub accepts X509 telemetry and returns a twin over ${transport.name}',
    () async {
      String requiredSetting(String name) {
        final value = Platform.environment[name];
        if (value == null || value.isEmpty) {
          throw StateError(
            'Configure $name for a dedicated X.509 test device.',
          );
        }
        return value;
      }

      final hostName = requiredSetting('AZURE_IOT_TEST_X509_HOST_NAME');
      final deviceId = requiredSetting('AZURE_IOT_TEST_X509_DEVICE_ID');
      final certificatePath = requiredSetting(
        'AZURE_IOT_TEST_X509_CERTIFICATE_PATH',
      );
      final keyPath = requiredSetting('AZURE_IOT_TEST_X509_PRIVATE_KEY_PATH');
      final context = SecurityContext(withTrustedRoots: true);
      // Explicit application opt-in, limited to this IoT Hub test context.
      if (transport == .webSocket) {
        context.allowLegacyUnsafeRenegotiation = true;
      }
      try {
        context.useCertificateChainBytes(
          await File(certificatePath).readAsBytes(),
        );
        context.usePrivateKeyBytes(
          await File(keyPath).readAsBytes(),
          password:
              Platform.environment['AZURE_IOT_TEST_X509_PRIVATE_KEY_PASSWORD'],
        );
      } catch (_) {
        // Do not expose native certificate diagnostics or application file paths.
        throw StateError(
          'Unable to load the test certificate chain or private key.',
        );
      }
      final client = DeviceClient.withX509(
        hostName: hostName,
        deviceId: deviceId,
        securityContext: context,
        transport: transport,
        operationTimeout: const .new(seconds: 30),
      );
      try {
        await client.sendEvent(
          .new(
            utf8.encode('{"sdkX509Test":true}'),
            contentType: 'application/json',
            contentEncoding: 'utf-8',
          ),
        );
        final twin = await client.getTwin();
        // Assertions use booleans so unexpected twin contents are never logged.
        expect(twin.properties.desired != null, isTrue);
        expect(twin.properties.reported != null, isTrue);
      } finally {
        await client.close();
      }
    },
    skip: Platform.environment['AZURE_IOT_RUN_X509_INTEGRATION'] != '1'
        ? 'Opt in with AZURE_IOT_RUN_X509_INTEGRATION=1 and X.509 test credentials.'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
