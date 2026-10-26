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
      telemetryTopic(TelemetryMessage([]), 'device'),
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
      telemetryTopic(message, 'device'),
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
    expect(
      telemetryTopic(message, 'd'),
      'devices/d/messages/events/key=original/',
    );
    expect(() => message.payload[0] = 4, throwsUnsupportedError);
  });

  test('C# MQTT payload and topic byte limits are enforced', () {
    expect(TelemetryMessage(Uint8List(0x3ffff)).payload.length, 0x3ffff);
    expect(() => TelemetryMessage(Uint8List(0x40000)), throwsArgumentError);
    expect(
      () => telemetryTopic(
        TelemetryMessage([], properties: {'key': '☕' * 8000}),
        'd',
      ),
      throwsArgumentError,
    );
  });

  test('Azure limit includes application property names and values', () {
    expect(
      () => TelemetryMessage(Uint8List(262000), properties: {'k': 'x' * 1000}),
      throwsArgumentError,
    );
    expect(
      TelemetryMessage(Uint8List(262000), properties: {'k': 'x' * 143}),
      isA<TelemetryMessage>(),
    );
    expect(
      () => TelemetryMessage(Uint8List(262000), properties: {'k': 'x' * 144}),
      throwsArgumentError,
    );
  });

  test('Azure limit counts effective system values without their names', () {
    TelemetryMessage make(int bodySize) => TelemetryMessage(
      Uint8List(bodySize),
      messageId: 'm',
      correlationId: 'c',
      contentType: 't',
      contentEncoding: 'e',
      properties: {r'$.mid': 'ignored' * 1000},
    );
    expect(make(262140), isA<TelemetryMessage>());
    expect(() => make(262141), throwsArgumentError);
  });

  test('raw system properties use the same Azure size accounting', () {
    expect(
      TelemetryMessage(Uint8List(262143), properties: {r'$.mid': 'm'}),
      isA<TelemetryMessage>(),
    );
    expect(
      () => TelemetryMessage(Uint8List(262143), properties: {r'$.mid': 'mm'}),
      throwsArgumentError,
    );
  });

  for (final value in [null, '']) {
    test('Azure limit counts a property name with value $value', () {
      expect(
        TelemetryMessage(Uint8List(262143), properties: {'k': value}),
        isA<TelemetryMessage>(),
      );
      expect(
        () => TelemetryMessage(Uint8List(262143), properties: {'kk': value}),
        throwsArgumentError,
      );
    });
  }

  test('Azure size uses UTF-8 bytes before MQTT percent encoding', () {
    expect(
      TelemetryMessage(Uint8List(262138), properties: {'☕': '☕'}),
      isA<TelemetryMessage>(),
    );
    expect(
      () => TelemetryMessage(Uint8List(262139), properties: {'☕': '☕'}),
      throwsArgumentError,
    );
    expect(
      TelemetryMessage(Uint8List(262141), messageId: '☕'),
      isA<TelemetryMessage>(),
    );
    expect(
      () => TelemetryMessage(Uint8List(262142), messageId: '☕'),
      throwsArgumentError,
    );
  });
}
