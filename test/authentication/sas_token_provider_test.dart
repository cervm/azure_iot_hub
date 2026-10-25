// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license; see third_party/azure-iot-sdk-csharp-LICENSE.
// Named cases adapt AuthenticationWithTokenRefreshTests.cs and
// DeviceAuthenticationWithTokenRefreshTests.cs at the pinned C# commit.
// See doc/upstream.md for the source/test mapping and Dart adaptations.
import 'dart:async';

import 'package:azure_iot_hub/src/authentication/iot_hub_connection_string.dart';
import 'package:azure_iot_hub/src/authentication/sas_token_cache.dart';
import 'package:test/test.dart';

final epoch = DateTime.utc(2026, 10, 24);

String token(DateTime expiry) =>
    'SharedAccessSignature sig=a%2Bb%2f%3d&se='
    '${expiry.millisecondsSinceEpoch ~/ 1000}'
    '&SR=contoso.azure-devices.net%2fdevices%2fdevice-1';

IotHubConnectionString credentials(SasTokenProvider provider) =>
    IotHubConnectionString.withTokenProvider(
      hostName: 'contoso.azure-devices.net',
      deviceId: 'device-1',
      gatewayHostName: 'gateway.local',
      tokenProvider: provider,
    );

void main() {
  late DateTime now;
  setUp(() => now = epoch);

  test('provider credentials carry identity without a key or fixed SAS', () {
    var calls = 0;
    final identity = credentials((_, _) async {
      calls++;
      return token(epoch);
    });
    expect(identity.hostName, 'contoso.azure-devices.net');
    expect(identity.deviceId, 'device-1');
    expect(identity.connectionHostName, 'gateway.local');
    expect(identity.sharedAccessKey, isNull);
    expect(identity.sharedAccessKeyName, isNull);
    expect(identity.sharedAccessSignature, isNull);
    expect(calls, 0);
    expect(() => identity.createSasToken(now: now), throwsStateError);
    expect(identity.toString(), 'IotHubConnectionString(<redacted>)');
  });

  test(
    'provider identity uses existing host, device and gateway validation',
    () {
      for (final (host, device, gateway) in [
        ('', 'device-1', null),
        ('hub.azure-devices.net', 'bad/device', null),
        ('hub.azure-devices.net', 'device-1', 'bad/gateway/'),
      ]) {
        expect(
          () => IotHubConnectionString.withTokenProvider(
            hostName: host,
            deviceId: device,
            gatewayHostName: gateway,
            tokenProvider: (_, _) async => token(epoch),
          ),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'AuthenticationWithTokenRefresh_InitializedToken_GetProperties_Ok',
    () async {
      var calls = 0;
      final raw = token(epoch.add(const Duration(hours: 1)));
      final cache = SasTokenCache(
        credentials((host, ttl) async {
          expect(host, 'contoso.azure-devices.net'); // Not the gateway.
          expect(ttl, 3600);
          calls++;
          return raw;
        }),
        now: () => now,
      );
      expect(cache.refreshesOn, isNull);
      final first = await cache.getToken();
      expect(first.value, raw); // Preserve encoding, field order and casing.
      expect(first.expiresOn, epoch.add(const Duration(hours: 1)));
      expect(cache.refreshesOn, epoch.add(const Duration(minutes: 51)));
      now = cache.refreshesOn!.subtract(const Duration(microseconds: 1));
      expect(await cache.getToken(), same(first));
      expect(calls, 1);
    },
  );

  test(
    'AuthenticationWithTokenRefresh_GetTokenAsync_ConcurrentUpdate_Ok',
    () async {
      var calls = 0;
      var acquisition = Completer<String>();
      final cache = SasTokenCache(
        credentials((_, _) {
          calls++;
          return acquisition.future;
        }),
        now: () => now,
      );
      for (var round = 1; round <= 2; round++) {
        final waiting = Future.wait([
          for (var i = 0; i < 5; i++) cache.getToken(),
        ]);
        expect(calls, round);
        acquisition.complete(token(now.add(const Duration(hours: 1))));
        final tokens = await waiting;
        expect(tokens, everyElement(same(tokens.first)));
        expect(calls, round);
        now = cache.refreshesOn!;
        acquisition = Completer<String>();
      }
    },
  );

  test('AuthenticationWithTokenRefresh_GetTokenAsync_NewTtl_Ok', () async {
    var ttl = 1;
    final cache = SasTokenCache(
      credentials((_, suggestedTtl) async {
        expect(suggestedTtl, 1);
        return token(now.add(Duration(seconds: ttl)));
      }),
      timeToLiveSeconds: 1,
      renewalBufferPercentage: 90,
      now: () => now,
    );
    expect(
      (await cache.getToken()).expiresOn,
      epoch.add(const Duration(seconds: 1)),
    );
    now = cache.refreshesOn!;
    ttl = 10;
    expect(
      (await cache.getToken()).expiresOn,
      now.add(const Duration(seconds: 10)),
    );
    expect(cache.refreshesOn, now.add(const Duration(seconds: 1)));
  });

  test(
    'buffer uses lifetime remaining after asynchronous acquisition',
    () async {
      final acquisition = Completer<String>();
      final cache = SasTokenCache(
        credentials((_, _) => acquisition.future),
        now: () => now,
      );
      final waiting = cache.getToken();
      now = epoch.add(const Duration(minutes: 10));
      acquisition.complete(token(epoch.add(const Duration(hours: 1))));
      await waiting;
      expect(
        cache.refreshesOn,
        epoch.add(const Duration(minutes: 52, seconds: 30)),
      );
    },
  );

  test(
    'waiters recheck eligibility instead of always sharing the result',
    () async {
      var calls = 0;
      var active = 0;
      final cache = SasTokenCache(
        credentials((_, _) async {
          expect(++active, 1);
          calls++;
          await Future<void>.value();
          active--;
          return token(epoch.add(const Duration(hours: 1)));
        }),
        renewalBufferPercentage: 100,
        now: () => now,
      );
      await Future.wait([for (var i = 0; i < 5; i++) cache.getToken()]);
      expect(calls, 5);
    },
  );

  for (final synchronous in [true, false]) {
    test(
      'failed acquisition releases waiters (synchronous=$synchronous)',
      () async {
        var calls = 0;
        final rejected = Completer<String>();
        final cache = SasTokenCache(
          credentials((_, _) {
            if (++calls == 1) {
              if (synchronous) throw StateError('provider failed');
              return rejected.future;
            }
            return Future.value(token(now.add(const Duration(hours: 1))));
          }),
          now: () => now,
        );
        final failed = expectLater(cache.getToken(), throwsStateError);
        final next = cache.getToken();
        if (!synchronous) rejected.completeError(StateError('provider failed'));
        await failed;
        expect((await next).expiresOn, epoch.add(const Duration(hours: 1)));
        expect(calls, 2);
      },
    );
  }

  for (final (description, invalid) in [
    ('malformed', 'malformed secret'),
    ('expired', token(epoch.subtract(const Duration(minutes: 6)))),
  ]) {
    test(
      '$description provider SAS is rejected without replacing the cache',
      () async {
        var calls = 0;
        final cache = SasTokenCache(
          credentials(
            (_, _) async => ++calls == 2
                ? invalid
                : token(now.add(const Duration(hours: 1))),
          ),
          now: () => now,
        );
        await cache.getToken();
        now = cache.refreshesOn!;
        final threshold = cache.refreshesOn;
        await expectLater(cache.getToken(), throwsFormatException);
        expect(cache.refreshesOn, threshold);
        expect(
          (await cache.getToken()).expiresOn,
          now.add(const Duration(hours: 1)),
        );
        expect(calls, 3);
      },
    );
  }

  test('parser clock skew does not delay provider refresh', () async {
    var calls = 0;
    final cache = SasTokenCache(
      credentials((_, _) async {
        calls++;
        return token(epoch.subtract(const Duration(seconds: 1)));
      }),
      now: () => now,
    );
    await cache.getToken();
    await cache.getToken();
    expect(calls, 2);
    expect(cache.refreshesOn!.isBefore(now), isTrue);
  });
}
