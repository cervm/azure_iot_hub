// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license; see third_party/azure-iot-sdk-csharp-LICENSE.
// Named IotHubConnectionStringBuilder cases are adapted from
// Azure/azure-iot-sdk-csharp, commit 7a99b886e81158a31bd6a47f86a32393dcc1c73b,
// iothub/device/tests/Authentication/IotHubConnectionStringBuilderTests.cs.
import 'package:azure_iot_hub/src/authentication/iot_hub_connection_string.dart';
import 'package:test/test.dart';

const _host = 'acme.azure-devices.net';
const _key = 'dGVzdFN0cmluZzE=';
const _complexId = r"device1-.+%_#*?!(),=@;$'";
const _suppliedToken =
    'SharedAccessSignature sr=dh%3a%2f%2facme.azure-devices.net'
    '&sig=dGVzdFN0cmluZzU=&se=87824124985&skn=AllAccessKey';
const _connection = 'HostName=$_host;DeviceId=device1;SharedAccessKey=$_key';
final _now = DateTime.utc(2018);

IotHubConnectionString _parse(String value) =>
    IotHubConnectionString.parse(value, now: _now);

void main() {
  group('IotHubConnectionStringBuilder_ParamConnectionString', () {
    test('ParsesHostName', () => expect(_parse(_connection).hostName, _host));
    test(
      'ParsesDeviceId',
      () => expect(_parse(_connection).deviceId, 'device1'),
    );
    test('ParsesCultureDeviceId', () {
      expect(
        _parse(_connection.replaceFirst('device1', 'IoTDeviceCheck')).deviceId,
        'IoTDeviceCheck',
      );
    });
    test('ParsesComplexDeviceId', () {
      expect(
        _parse(_connection.replaceFirst('device1', _complexId)).deviceId,
        _complexId,
      );
    });
    test('ParsesSharedAccessKey', () {
      final parsed = _parse(_connection);
      expect(parsed.sharedAccessKey, _key);
      expect(parsed.sharedAccessSignature, isNull);
    });
    for (final name in ['X509Cert', 'X509']) {
      test('ParsesX509False ($name)', () {
        expect(_parse('$_connection;$name=false').sharedAccessKey, _key);
      });
    }
    test('ParsesSharedAccessKeyName', () {
      expect(
        _parse('$_connection;SharedAccessKeyName=AllAccessKey')
            .sharedAccessKeyName,
        'AllAccessKey',
      );
    });
    test('ParsesSharedAccessSignature', () {
      final parsed = _parse(
        'HostName=$_host;DeviceId=device1;SharedAccessSignature=$_suppliedToken',
      );
      expect(parsed.sharedAccessSignature!.value, _suppliedToken);
      expect(parsed.sharedAccessKey, isNull);
      expect(parsed.createSasToken(now: _now).value, _suppliedToken);
    });
    test('ParsesGatewayHostName', () {
      final parsed = _parse('$_connection;GatewayHostName=test');
      expect(parsed.gatewayHostName, 'test');
      expect(parsed.connectionHostName, 'test');
      expect(parsed.createSasToken(now: _now).value, contains('sr=$_host%2F'));
    });
    for (final (name, value) in [
      ('MissingHostName_Throws', 'DeviceId=device1;SharedAccessKey=$_key'),
      ('MissingDeviceId_Throws', 'HostName=$_host;SharedAccessKey=$_key'),
      (
        'IncludesBothSharedAcccess_Throws',
        '$_connection;SharedAccessSignature=$_suppliedToken',
      ),
      ('NoAuthSpecied_Throws', 'HostName=$_host;DeviceId=device1'),
    ]) {
      test(name, () => expect(() => _parse(value), throwsFormatException));
    }
  });

  test('field names are case-insensitive without changing values', () {
    final parsed = _parse(
      'hOsTnAmE=$_host;DEVICEID=Device;sharedaccesskey=$_key',
    );
    expect(parsed.deviceId, 'Device');
    expect(parsed.sharedAccessKey, _key);
  });

  test('duplicate fields are rejected case-insensitively', () {
    expect(() => _parse('$_connection;DEVICEID=other'), throwsFormatException);
  });

  test('device IDs reject characters and lengths outside the C# contract', () {
    for (final id in ['', 'device/name', 'device name', 'deviceé', 'a' * 129]) {
      expect(
        () => _parse(_connection.replaceFirst('device1', id)),
        throwsFormatException,
      );
    }
  });

  test('unknown properties and an empty unused SAS field match C# parsing', () {
    final parsed = _parse('$_connection;Unused=value;SharedAccessSignature=');
    expect(parsed.sharedAccessKey, _key);
    expect(parsed.sharedAccessSignature, isNull);
  });

  test('unsupported module and X.509 credentials cannot become device SAS', () {
    for (final property in ['ModuleId=module', 'X509Cert=true', 'x509=TrUe']) {
      expect(() => _parse('$_connection;$property'), throwsUnsupportedError);
    }
  });

  test(
    'device and policy audiences match independently computed signatures',
    () {
      // Golden values computed with Python's hmac/hashlib and WebUtility-compatible
      // URL encoding, using the C# test key and the fixed expiry 1514768400.
      expect(
        _parse(_connection).createSasToken(now: _now).value,
        'SharedAccessSignature sr=acme.azure-devices.net%2Fdevices%2Fdevice1'
        '&sig=xxfqYo9qssbXqYUVNUcxQOv6o6ZpkGEWdqbU5JppdJ4%3D&se=1514768400',
      );
      expect(
        _parse(_connection.replaceFirst('device1', _complexId))
            .createSasToken(now: _now)
            .value,
        'SharedAccessSignature sr=acme.azure-devices.net%2Fdevices%2Fdevice1-.'
        '%252B%2525_%2523*%253F!()%252C%253D%2540%253B%2524%2527'
        '&sig=33KFHI7JcJVz2i%2BxRnFeBqtWB8RsKiOPKiwLeq6MvWQ%3D&se=1514768400',
      );
      expect(
        _parse('$_connection;SharedAccessKeyName=AllAccessKey')
            .createSasToken(now: _now)
            .value,
        'SharedAccessSignature sr=acme.azure-devices.net'
        '&sig=8ikMY35TuhRuPKAkS2bwNSdxZVw7vJ%2FuqXuEcUInQYA%3D'
        '&se=1514768400&skn=AllAccessKey',
      );
    },
  );

  test('connection-string diagnostics never contain credential input', () {
    expect(
      _parse(_connection).toString(),
      'IotHubConnectionString(<redacted>)',
    );
    for (final value in [
      '$_connection;SharedAccessKey=$_key',
      _connection.replaceFirst(_key, 'credential-secret!'),
      _connection.replaceFirst('device1', 'credential-secret/'),
      _connection.replaceFirst(
        'SharedAccessKey=$_key',
        'SharedAccessSignature=credential-secret',
      ),
      'credential-secret',
    ]) {
      expect(
        () => _parse(value),
        throwsA(
          isA<FormatException>()
              .having((error) => error.source, 'source', isNull)
              .having(
                (error) => error.toString(),
                'message',
                allOf(
                  isNot(contains(_key)),
                  isNot(contains('credential-secret')),
                ),
              ),
        ),
      );
    }
  });
}
