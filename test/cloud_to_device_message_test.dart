// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license; see third_party/azure-iot-sdk-csharp-LICENSE.
// Adapted from MqttIotHubAdapter and UrlEncodedDictionarySerializer scenarios.
import 'dart:typed_data';

import 'package:azure_iot_hub/src/cloud_to_device_message.dart';
import 'package:test/test.dart';

void main() {
  test('decodes system and application properties without form encoding', () {
    final message = decodeCloudToDeviceMessage(
      [0, 255],
      r'%24.mid=id&%24.cid=correlation&%24.ct=application%2Fjson&'
      r'%24.ce=utf-8&name=a+b%20c%2F%E2%98%95&flag&empty=/',
    );
    expect(message.payload, [0, 255]);
    expect(message.messageId, 'id');
    expect(message.correlationId, 'correlation');
    expect(message.contentType, 'application/json');
    expect(message.contentEncoding, 'utf-8');
    expect(message.properties, {'name': 'a+b c/☕', 'flag': null, 'empty': ''});
    expect(message.systemProperties, hasLength(4));
  });

  test('empty bag and repeated names follow C# dictionary behaviour', () {
    expect(decodeCloudToDeviceMessage([], '').properties, isEmpty);
    expect(decodeCloudToDeviceMessage([], 'a=1&a=2').properties, {'a': '2'});
  });

  test(
    'captures immutable bytes and properties; preserves unknown system fields',
    () {
      final bytes = Uint8List.fromList([1]);
      final message = decodeCloudToDeviceMessage(
        bytes,
        r'%24.future=value&key=v',
      );
      bytes[0] = 2;
      expect(message.payload, [1]);
      expect(message.systemProperties[r'$.future'], 'value');
      expect(() => message.payload[0] = 3, throwsUnsupportedError);
      expect(
        () => message.properties['key'] = 'changed',
        throwsUnsupportedError,
      );
      expect(() => message.systemProperties.clear(), throwsUnsupportedError);
    },
  );

  test('malformed properties fail without exposing their contents', () {
    for (final bag in ['secret=x=y', 'secret=1&', '=secret', 'secret=%QQ']) {
      expect(
        () => decodeCloudToDeviceMessage([], bag),
        throwsA(
          isA<FormatException>().having(
            (e) => e.toString(),
            'redaction',
            isNot(contains('secret')),
          ),
        ),
      );
    }
  });
}
