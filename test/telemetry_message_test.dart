// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license; see third_party/azure-iot-sdk-csharp-LICENSE.
// Wire expectations follow MqttIotHubAdapter.PopulateMessagePropertiesFromMessage,
// UrlEncodedDictionarySerializer.Serialize and Utils.MergeDictionaries.
import 'dart:typed_data';

import 'package:azure_iot_hub/src/telemetry_message.dart';
import 'package:test/test.dart';

void main() {
  test('empty property bag preserves base topic', () {
    expect(
      TelemetryMessage([]).topic('device'),
      'devices/device/messages/events/',
    );
  });

  test('system properties take precedence; null and empty values differ', () {
    final message = TelemetryMessage(
      [],
      messageId: 'system',
      properties: {
        r'$.mid': 'application',
        'flag': null,
        'empty': '',
        "!*'()~": 'a b+c/☕',
      },
    );
    expect(
      message.topic('device'),
      'devices/device/messages/events/'
      '%24.mid=system&flag&empty=&%21%2A%27%28%29~=a%20b%2Bc%2F%E2%98%95/',
    );
  });

  test('payload and properties are snapshots across retries', () {
    final bytes = Uint8List.fromList([1, 2]);
    final properties = {'key': 'original'};
    final message = TelemetryMessage(bytes, properties: properties);
    bytes[0] = 255;
    properties['key'] = 'changed';
    expect(message.payload, [1, 2]);
    expect(message.topic('d'), 'devices/d/messages/events/key=original/');
    expect(() => message.payload[0] = 4, throwsUnsupportedError);
  });

  test('C# MQTT payload and topic byte limits are enforced', () {
    expect(TelemetryMessage(Uint8List(0x3ffff)).payload.length, 0x3ffff);
    expect(() => TelemetryMessage(Uint8List(0x40000)), throwsArgumentError);
    expect(
      () => TelemetryMessage([], properties: {'key': '☕' * 8000}).topic('d'),
      throwsArgumentError,
    );
  });
}
