// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license; see third_party/azure-iot-sdk-csharp-LICENSE.
// Named cases adapt AuthenticationWithTokenRefreshTests.cs and
// DeviceAuthenticationWithTokenRefreshTests.cs at the pinned C# commit.
// See docs/upstream.md for the source/test mapping and Dart adaptations.
import 'package:azure_iot_hub/src/authentication/iot_hub_connection_string.dart';
import 'package:azure_iot_hub/src/authentication/sas_token_cache.dart';
import 'package:test/test.dart';

final epoch = DateTime.utc(2026, 10, 24);

IotHubConnectionString credentials() => IotHubConnectionString.parse(
  'HostName=contoso.azure-devices.net;DeviceId=device-1;'
  'SharedAccessKey=c2VjcmV0',
  now: epoch,
);

void main() {
  late DateTime now;
  late SasTokenCache cache;

  setUp(() {
    now = epoch;
    cache = SasTokenCache(credentials(), now: () => now);
  });

  test(
    'AuthenticationWithTokenRefresh_InitializedToken_GetProperties_Ok',
    () async {
      cache = SasTokenCache(
        credentials(),
        timeToLiveSeconds: 5,
        renewalBufferPercentage: 20,
        now: () => now,
      );
      expect(cache.refreshesOn, isNull);
      final first = await cache.getToken();
      expect(first.expiresOn, epoch.add(const Duration(seconds: 5)));
      expect(cache.refreshesOn, epoch.add(const Duration(seconds: 4)));
      now = cache.refreshesOn!;
      expect(await cache.getToken(), isNot(same(first)));
    },
  );

  test(
    'AuthenticationWithTokenRefresh_NonExpiredToken_GetTokenCached_Ok',
    () async {
      final first = await cache.getToken();
      expect(first.value, credentials().createSasToken(now: epoch).value);
      expect(await cache.getToken(), same(first));
      now = epoch.add(const Duration(minutes: 10));
      expect(await cache.getToken(), same(first));
    },
  );

  test(
    'AuthenticationWithTokenRefresh_GetTokenAsync_ConcurrentUpdate_Ok',
    () async {
      // Queued callers share one token, both initially and when renewal is due.
      final first = await Future.wait([
        for (var i = 0; i < 5; i++) Future.microtask(cache.getToken),
      ]);
      expect(first, everyElement(same(first.first)));
      now = cache.refreshesOn!;
      final renewed = await Future.wait([
        for (var i = 0; i < 5; i++) Future.microtask(cache.getToken),
      ]);
      expect(renewed, everyElement(same(renewed.first)));
      expect(renewed.first, isNot(same(first.first)));
    },
  );

  test('DeviceAuthenticationWithTokenRefresh_Ctor_WrongArguments_Fail', () {
    for (final (ttl, buffer) in [(-1, 10), (60, -1), (60, 101)]) {
      expect(
        () => SasTokenCache(
          credentials(),
          timeToLiveSeconds: ttl,
          renewalBufferPercentage: buffer,
        ),
        throwsArgumentError,
      );
    }
  });

  test('defaults and zero use a one-hour TTL and 15 percent buffer', () async {
    for (final (ttl, buffer) in [(3600, 15), (0, 15), (3600, 0), (0, 0)]) {
      final candidate = SasTokenCache(
        credentials(),
        timeToLiveSeconds: ttl,
        renewalBufferPercentage: buffer,
        now: () => now,
      );
      expect(
        (await candidate.getToken()).expiresOn,
        epoch.add(const Duration(hours: 1)),
      );
      expect(candidate.refreshesOn, epoch.add(const Duration(minutes: 51)));
    }
    expect(
      (await cache.getToken()).expiresOn,
      epoch.add(const Duration(hours: 1)),
    );
    expect(cache.refreshesOn, epoch.add(const Duration(minutes: 51)));
  });

  test(
    'reuses just before the threshold and refreshes exactly at it',
    () async {
      final first = await cache.getToken();
      final threshold = cache.refreshesOn!;
      now = threshold.subtract(const Duration(microseconds: 1));
      expect(await cache.getToken(), same(first));
      now = threshold;
      final renewed = await cache.getToken();
      expect(renewed.value, isNot(first.value));
      expect(renewed.expiresOn, now.add(const Duration(hours: 1)));
      expect(cache.refreshesOn, now.add(const Duration(minutes: 51)));
    },
  );

  test(
    'refreshes after expiry without applying the parser clock skew',
    () async {
      final first = await cache.getToken();
      now = first.expiresOn.add(const Duration(seconds: 1));
      final renewed = await cache.getToken();
      expect(renewed.value, isNot(first.value));
      expect(renewed.expiresOn, now.add(const Duration(hours: 1)));
    },
  );

  test('fractional creation time uses the actual rounded expiry', () async {
    for (final milliseconds in [400, 600]) {
      now = epoch.add(Duration(milliseconds: milliseconds));
      final candidate = SasTokenCache(credentials(), now: () => now);
      await candidate.getToken();
      expect(candidate.refreshesOn, epoch.add(const Duration(seconds: 3061)));
    }
  });

  test('buffer uses the remaining lifetime after signing', () async {
    var calls = 0;
    cache = SasTokenCache(
      credentials(),
      now: () => calls++ == 0 ? epoch : epoch.add(const Duration(seconds: 10)),
    );
    expect(
      (await cache.getToken()).expiresOn,
      epoch.add(const Duration(hours: 1)),
    );
    expect(cache.refreshesOn, epoch.add(const Duration(seconds: 3062)));
  });

  test(
    'buffer preserves C# single-precision truncation at integer boundaries',
    () async {
      cache = SasTokenCache(
        credentials(),
        timeToLiveSeconds: 100,
        renewalBufferPercentage: 53,
        now: () => now,
      );
      await cache.getToken();
      // C# (int)(100 * ((float)53 / 100)) is 52.
      expect(cache.refreshesOn, epoch.add(const Duration(seconds: 48)));
    },
  );

  test(
    '100 percent buffer makes each credential request eligible to refresh',
    () async {
      cache = SasTokenCache(
        credentials(),
        renewalBufferPercentage: 100,
        now: () => now,
      );
      final first = await cache.getToken();
      expect(cache.refreshesOn, epoch);
      expect(await cache.getToken(), isNot(same(first)));
    },
  );

  test('external SAS is returned unchanged even after its expiry', () async {
    const raw =
        'SharedAccessSignature sig=a%2Bb%2f%3d&se=1792803600'
        '&SR=contoso.azure-devices.net%2fdevices%2fdevice-1';
    final supplied = IotHubConnectionString.parse(
      'HostName=contoso.azure-devices.net;DeviceId=device-1;'
      'SharedAccessSignature=$raw',
      now: epoch,
    );
    cache = SasTokenCache(supplied, now: () => now);
    final first = await cache.getToken();
    expect(first, same(supplied.sharedAccessSignature));
    expect(first.value, raw);
    now = first.expiresOn.add(const Duration(hours: 1));
    expect(await cache.getToken(), same(first));
    expect(cache.refreshesOn, isNull);
  });
}
