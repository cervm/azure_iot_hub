// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license; see third_party/azure-iot-sdk-csharp-LICENSE.
// TestBuildExpiry_ShouldReturnExpireOn adapts SasTokenBuilderTest.cs from
// Azure/azure-iot-sdk-csharp, commit 7a99b886e81158a31bd6a47f86a32393dcc1c73b,
// iothub/device/tests/Authentication/HsmAuthentication/. Other cases verify
// SharedAccessSignatureBuilder / SharedAccessSignature behaviour in Dart.
import 'package:azure_iot_hub/src/authentication/shared_access_signature.dart';
import 'package:test/test.dart';

const _key = 'dGVzdFN0cmluZzE=';
final _now = DateTime.utc(2018);

SharedAccessSignature _generate(DateTime now) => SharedAccessSignature.generate(
  key: _key,
  target: 'acme.azure-devices.net/devices/device1',
  now: now,
);

void main() {
  test('TestBuildExpiry_ShouldReturnExpireOn', () {
    final token = _generate(_now);
    expect(token.expiresOn, DateTime.utc(2018, 1, 1, 1));
    expect(token.value, endsWith('&se=1514768400'));
  });

  test('expiry uses round-to-even, including either side of a midpoint', () {
    for (final (microseconds, seconds) in [
      (499999, 0),
      (500000, 0),
      (500001, 1),
      (1500000, 2),
      (2500000, 2),
    ]) {
      final token = _generate(_now.add(Duration(microseconds: microseconds)));
      expect(token.expiresOn, DateTime.utc(2018, 1, 1, 1, 0, seconds));
    }
  });

  test('expiry uses the instant regardless of the input timezone', () {
    expect(_generate(_now.toLocal()).value, _generate(_now).value);
    expect(_generate(_now.toLocal()).expiresOn.isUtc, isTrue);
  });

  test('SAS encoding matches WebUtility rather than URI defaults', () {
    expect(encodeSasComponent("a b+/'~!*()é"), 'a+b%2B%2F%27%7E!*()%C3%A9');
  });

  test(
    'token parsing preserves field order, escape casing and signature bytes',
    () {
      const raw =
          'SharedAccessSignature sig=a%2Bb%2f%3d&se=1514768400'
          '&SR=acme.azure-devices.net%2fdevices%2fdevice1&skn=device';
      final parsed = SharedAccessSignature.parse(raw, now: _now);
      expect(parsed.value, raw);
      expect(parsed.expiresOn, DateTime.utc(2018, 1, 1, 1));
      expect(parsed.toString(), 'SharedAccessSignature(<redacted>)');
    },
  );

  test('C# expiry tolerance ends strictly after five minutes', () {
    final token = _generate(_now);
    final boundary = token.expiresOn.add(const Duration(minutes: 5));
    expect(
      SharedAccessSignature.parse(token.value, now: boundary).expiresOn,
      token.expiresOn,
    );
    expect(
      () => SharedAccessSignature.parse(
        token.value,
        now: boundary.add(const Duration(microseconds: 1)),
      ),
      throwsFormatException,
    );
  });

  test('malformed tokens fail without including credential input', () {
    for (final raw in [
      'credential-secret',
      'SharedAccessSignature sr=credential-secret&se=1514768400',
      'SharedAccessSignature sr=hub&sig=credential-secret',
      'SharedAccessSignature sig=credential-secret&se=1514768400',
      'SharedAccessSignature sr=hub&sig=credential-secret&se=NaN',
      'SharedAccessSignature sr=hub&sig=credential-secret&se=Infinity',
      'SharedAccessSignature sr=hub&sig=credential-secret&se=%invalid',
      'SharedAccessSignature sr=hub&sig=credential-secret&se=253402300800',
      'SharedAccessSignature sr=hub&sig=credential-secret&se=1514768400&SIG=x',
      'SharedAccessSignature  sr=hub&sig=credential-secret&se=1514768400',
    ]) {
      expect(
        () => SharedAccessSignature.parse(raw, now: _now),
        throwsA(
          isA<FormatException>()
              .having((error) => error.source, 'source', isNull)
              .having(
                (error) => error.toString(),
                'message',
                isNot(contains('credential-secret')),
              ),
        ),
      );
    }
  });

  test('base64 key validation does not inherit Dart-only permissiveness', () {
    for (final key in [
      '',
      'secret!',
      'dGVzdA',
      'dGVzdA== ',
      '____',
      '%2B%2B8=',
    ]) {
      expect(
        () =>
            SharedAccessSignature.generate(key: key, target: 'hub', now: _now),
        throwsA(
          isA<FormatException>()
              .having((error) => error.source, 'source', isNull)
              .having(
                (error) => error.message,
                'message',
                'SharedAccessKey must be base64 encoded.',
              ),
        ),
      );
    }
    expect(
      decodeSharedAccessKey('dGVz\r\ndFN0cmluZzE='),
      decodeSharedAccessKey(_key),
    );
  });
}
