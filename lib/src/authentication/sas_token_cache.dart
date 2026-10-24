// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license; see third_party/azure-iot-sdk-csharp-LICENSE.
// Adapted from AuthenticationWithTokenRefresh and DeviceAuthenticationWithTokenRefresh.
// See docs/upstream.md for the pinned source and test mapping.
import 'dart:async';
import 'dart:typed_data';

import 'iot_hub_connection_string.dart';
import 'shared_access_signature.dart';

/// The internal C#-style SAS cache, queried when establishing a connection.
///
/// Serializes acquisition and rechecks eligibility after each refresh, as C# does.
/// Refresh eligibility does not schedule MQTT reconnection.
final class SasTokenCache(
  final IotHubConnectionString credentials, {
  int timeToLiveSeconds = 3600,
  int renewalBufferPercentage = 15,
  final DateTime Function() now = DateTime.now,
}) {
  this {
    if (timeToLiveSeconds < 0 ||
        renewalBufferPercentage < 0 ||
        renewalBufferPercentage > 100) {
      throw ArgumentError('Invalid SAS lifetime or renewal buffer.');
    }
  }

  // C# device authentication treats zero as a request for the default.
  final _timeToLive = Duration(
    seconds: timeToLiveSeconds == 0 ? 3600 : timeToLiveSeconds,
  );
  final _bufferFraction = _singlePrecision(
    (renewalBufferPercentage == 0 ? 15 : renewalBufferPercentage) / 100,
  );
  SharedAccessSignature? _token;
  DateTime? _refreshesOn;
  Future<void>? _refreshing;

  /// The acquired token's renewal threshold, or null before acquiring one.
  DateTime? get refreshesOn => _refreshesOn;

  /// Returns the fixed SAS unchanged, or reuses or refreshes a cached SAS.
  Future<SharedAccessSignature> getToken() async {
    final supplied = credentials.sharedAccessSignature;
    if (supplied != null) return supplied;
    // A failed refresh releases the waiters to try independently. A successful
    // refresh may already be eligible again (for example with a 100% buffer).
    while (true) {
      final cached = _token;
      if (cached != null && now().isBefore(_refreshesOn!)) return cached;
      final refreshing = _refreshing;
      if (refreshing == null) break;
      await refreshing;
    }

    final finished = Completer<void>();
    _refreshing = finished.future;
    try {
      final provider = credentials.tokenProvider;
      final token = provider == null
          ? credentials.createSasToken(now: now(), timeToLive: _timeToLive)
          : SharedAccessSignature.parse(
              await provider(credentials.hostName, _timeToLive.inSeconds),
              now: now(),
            );
      // C# truncates the remaining lifetime after signing, then uses single-
      // precision arithmetic to calculate the whole-second renewal buffer.
      final remainingSeconds = token.expiresOn.difference(now()).inSeconds;
      final bufferSeconds = _singlePrecision(
        _singlePrecision(remainingSeconds.toDouble()) * _bufferFraction,
      ).truncate();
      _refreshesOn = token.expiresOn.subtract(Duration(seconds: bufferSeconds));
      _token = token;
      return token;
    } finally {
      _refreshing = null;
      finished.complete();
    }
  }
}

double _singlePrecision(double value) => Float32List.fromList([value]).single;
