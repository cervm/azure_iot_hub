// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license; see third_party/azure-iot-sdk-csharp-LICENSE.
// Adapts MethodRequest/MethodResponse contracts and DeviceClientTests JSON cases.
import 'dart:convert';

import 'package:azure_iot_hub/azure_iot_hub.dart';
import 'package:azure_iot_hub/src/direct_method.dart'
    show parseMethodTopic, validateMethodPayload;
import 'package:test/test.dart';

void main() {
  test('MethodRequest preserves the name and copies the request bytes', () {
    final bytes = utf8.encode('{"name":"ABC"}');
    final request = MethodRequest('test', bytes);
    bytes[0] = 0;
    expect(request.name, 'test');
    expect(request.dataAsJson, '{"name":"ABC"}');
    expect(() => request.data![0] = 0, throwsUnsupportedError);
  });

  test('MethodResponse preserves status and copies validated result bytes', () {
    final bytes = utf8.encode('[1,null,true]');
    final response = MethodResponse(201, result: bytes);
    bytes[0] = 0;
    expect(response.status, 201);
    expect(response.resultAsJson, '[1,null,true]');
    expect(() => response.result![0] = 0, throwsUnsupportedError);
  });

  test('absent and empty data retain C# JSON getter semantics', () {
    expect(MethodRequest('test').data, isNull);
    expect(MethodRequest('test').dataAsJson, isNull);
    expect(MethodRequest('test', []).dataAsJson, isNull);
    expect(MethodResponse(200).result, isNull);
    expect(MethodResponse(200).resultAsJson, isNull);
    expect(MethodResponse(200, result: []).result, isEmpty);
    expect(MethodResponse(200, result: []).resultAsJson, isNull);
  });

  for (final json in ['{}', '[]', 'null', '42', 'true', '"blå ☕"']) {
    test('accepts JSON document $json', () {
      expect(MethodResponse(200, result: utf8.encode(json)).resultAsJson, json);
    });
  }

  for (final bytes in [
    utf8.encode('{secret'),
    [0xff],
    utf8.encode(' '),
    utf8.encode('{}{}'),
  ]) {
    test('invalid JSON/UTF-8 errors redact the payload $bytes', () {
      expect(
        () => MethodResponse(200, result: bytes),
        throwsA(
          isA<FormatException>()
              .having((error) => error.source, 'source', isNull)
              .having(
                (error) => error.message,
                'message',
                'Invalid method JSON payload.',
              ),
        ),
      );
    });
  }

  test('IoT Hub payload limit applies to both requests and responses', () {
    final atLimit = utf8.encode('"${'a' * (128 * 1024 - 2)}"');
    expect(MethodResponse(200, result: atLimit).result, hasLength(128 * 1024));
    validateMethodPayload(atLimit);
    final tooLarge = [...atLimit, 32];
    expect(() => MethodResponse(200, result: tooLarge), throwsArgumentError);
    expect(() => validateMethodPayload(tooLarge), throwsArgumentError);
  });

  test('status is application-defined, as in C#', () {
    expect(MethodResponse(-1).status, -1);
    expect(MethodResponse(12345).status, 12345);
  });

  test('parses an opaque request ID and retains the raw method name', () {
    expect(parseMethodTopic(r'$iothub/methods/POST/reboot/?$rid=abc123'), (
      'reboot',
      'abc123',
    ));
    expect(
      parseMethodTopic(r'$iothub/methods/POST/a%20b/?x=1&$rid=a%2Bb%2Fc'),
      ('a%20b', 'a+b/c'),
    );
  });

  for (final topic in [
    r'$iothub/methods/POST/reboot/',
    r'$iothub/methods/POST/reboot/?$rid=',
    r'$iothub/methods/POST/reboot/?x=1',
    r'$iothub/methods/POST/reboot/?$rid=a&$rid=b',
    r'$iothub/methods/POST//?$rid=a',
    r'$iothub/methods/POST/reboot/?$rid=a/extra',
    r'$iothub/twin/res/200/?$rid=a',
  ]) {
    test('rejects malformed method topic $topic', () {
      expect(parseMethodTopic(topic), isNull);
    });
  }
}
