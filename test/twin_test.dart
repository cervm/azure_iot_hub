import 'dart:convert';

import 'package:azure_iot_hub/src/twin.dart';
import 'package:test/test.dart';

void main() {
  test('reported patch limit counts encoded UTF-8 bytes', () {
    // {"x":""} adds eight ASCII bytes. Use multibyte characters to distinguish
    // the MQTT byte limit from a Dart string-length check.
    final value = '${'é' * ((0x3ffff - 8) ~/ 2)}a';
    expect(encodeReportedProperties({'x': value}), hasLength(0x3ffff));
    expect(
      () => encodeReportedProperties({'x': '${value}a'}),
      throwsArgumentError,
    );
  });

  test(
    'unsupported and cyclic reported values fail without disclosing data',
    () {
      final cyclic = <String, Object?>{};
      cyclic['self'] = cyclic;
      for (final patch in <Map<String, Object?>>[
        {'secret-property': Object()},
        {'secret-property': double.nan},
        {'secret-property': double.infinity},
        {
          'nested': {1: 'secret-property'},
        },
        {'custom': _InvalidJsonValue()},
        cyclic,
      ]) {
        expect(
          () => encodeReportedProperties(patch),
          throwsA(
            isA<FormatException>()
                .having((e) => e.source, 'source', isNull)
                .having(
                  (e) => e.toString(),
                  'diagnostic',
                  isNot(contains('secret-property')),
                ),
          ),
        );
      }
    },
  );

  test(
    'preserves nested properties, nulls, metadata, versions and strings',
    () {
      final twin = TwinProperties.fromBytes(
        utf8.encode(r'''
      {"desired":{"list":[1,null,{"value":true}],"$version":12,
        "$metadata":{"$lastUpdated":"2023-01-31T10:37:08.4599400"}},
       "reported":{"removed":null,"value":1.5,"$version":123}}
    '''),
      );
      expect(twin.desired![r'$version'], 12);
      expect(twin.desired!['list'], [
        1,
        null,
        {'value': true},
      ]);
      expect(twin.desired![r'$metadata'], {
        r'$lastUpdated': '2023-01-31T10:37:08.4599400',
      });
      expect(twin.reported, {'removed': null, 'value': 1.5, r'$version': 123});
    },
  );

  test(
    'missing collections default to empty while explicit null is retained',
    () {
      final missing = TwinProperties.fromBytes(utf8.encode('{}'));
      expect(missing.desired, isEmpty);
      expect(missing.reported, isEmpty);
      final explicit = TwinProperties.fromBytes(
        utf8.encode('{"desired":null,"reported":null}'),
      );
      expect(explicit.desired, isNull);
      expect(explicit.reported, isNull);
    },
  );

  test(
    'invalid twin JSON and UTF-8 fail without including device properties',
    () {
      for (final bytes in [
        utf8.encode('secret-property: not JSON'),
        utf8.encode('[]'),
        utf8.encode('{"desired":"secret-property"}'),
        utf8.encode('{"reported":[]}'),
        [255],
      ]) {
        expect(
          () => TwinProperties.fromBytes(bytes),
          throwsA(
            isA<FormatException>()
                .having((e) => e.source, 'source', isNull)
                .having(
                  (e) => e.toString(),
                  'diagnostic',
                  isNot(contains('secret-property')),
                ),
          ),
        );
      }
    },
  );

  test('response topic extracts the request ID with query decoding', () {
    final response = TwinResponse.parse(
      r'$iothub/twin/res/200/?$version=1&$rid=a%2Bb',
      [1, 2],
    );
    expect(response!.requestId, 'a+b');
    expect(response.status, 200);
    expect(response.payload, [1, 2]);
  });

  test('unrelated or malformed topics cannot correlate a response', () {
    for (final topic in [
      r'devices/device/messages/devicebound/?$rid=a',
      r'$iothub/twin/res/error/?$rid=a',
      r'$iothub/twin/res/+200/?$rid=a',
      r'$iothub/twin/res/200/?$version=1',
      r'$iothub/twin/res/200/$rid=a',
      r'$iothub/twin/res/200/?$rid=a&$rid=b',
      r'$iothub/twin/res/200/?$rid=%invalid',
    ]) {
      expect(TwinResponse.parse(topic, []), isNull, reason: topic);
    }
  });
}

final class _InvalidJsonValue {
  Object toJson() => throw StateError('secret-property');

  @override
  String toString() => 'secret-property';
}
