// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license; see third_party/azure-iot-sdk-csharp-LICENSE.
// Adapted from AuthenticationWithTokenRefresh and DeviceAuthenticationWithTokenRefresh.
// See docs/upstream.md for the pinned source and test mapping.
import 'dart:typed_data';

import 'iot_hub_connection_string.dart';
import 'shared_access_signature.dart';

/// The internal C#-style SAS cache, queried when establishing a connection.
///
/// Refresh eligibility does not schedule MQTT reconnection. Signing is synchronous
/// within one isolate, so concurrent callers cannot interleave cache updates.
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

  /// The generated token's renewal threshold, or null before signing one.
  DateTime? get refreshesOn => _refreshesOn;

  /// Returns the supplied SAS unchanged, or reuses or refreshes a generated SAS.
  SharedAccessSignature getToken() {
    final supplied = credentials.sharedAccessSignature;
    if (supplied != null) return supplied;
    final cached = _token;
    if (cached != null && now().isBefore(_refreshesOn!)) return cached;

    final token = credentials.createSasToken(
      now: now(),
      timeToLive: _timeToLive,
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
  }
}

double _singlePrecision(double value) => Float32List.fromList([value]).single;
