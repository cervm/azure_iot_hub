// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license; see third_party/azure-iot-sdk-csharp-LICENSE.
// Adapted from the pinned C# SDK's Common/Security/SharedAccessSignature*.cs.
// See docs/upstream.md for the source mapping.
import 'dart:convert';

import 'package:crypto/crypto.dart';

/// An internal SAS credential with an explicit expiry and redacted diagnostics.
final class SharedAccessSignature {
  const SharedAccessSignature._(this.value, this.expiresOn);

  /// Generates a token using the C# SDK's encoding and expiry rounding.
  factory SharedAccessSignature.generate({
    required String key,
    required String target,
    required DateTime now,
    Duration timeToLive = const Duration(hours: 1),
    String? keyName,
  }) {
    final keyBytes = decodeSharedAccessKey(key);
    final expiry = _roundToEven(
      now.add(timeToLive).microsecondsSinceEpoch /
          Duration.microsecondsPerSecond,
    );
    final audience = encodeSasComponent(target);
    final signature = base64.encode(
      Hmac(sha256, keyBytes).convert(utf8.encode('$audience\n$expiry')).bytes,
    );
    final policy = keyName == null || keyName.trim().isEmpty
        ? ''
        : '&skn=${encodeSasComponent(keyName)}';
    return SharedAccessSignature._(
      'SharedAccessSignature sr=$audience'
      '&sig=${encodeSasComponent(signature)}&se=$expiry$policy',
      DateTime.fromMillisecondsSinceEpoch(expiry * 1000, isUtc: true),
    );
  }

  /// Reads an externally supplied token without rewriting its signed contents.
  ///
  /// Retains C#'s five-minute clock-skew allowance during validation. This does
  /// not extend the token's service-side validity or its renewal deadline.
  factory SharedAccessSignature.parse(String value, {required DateTime now}) {
    // C# requires exactly one whitespace separator after the scheme.
    final parts = value.split(RegExp(r'\s'));
    if (parts.length != 2 || parts[0] != 'SharedAccessSignature') {
      throw const FormatException('Malformed SAS token.');
    }
    final fields = <String, String>{};
    for (final field in parts[1].split('&')) {
      if (field.isEmpty) continue;
      final separator = field.indexOf('=');
      if (separator < 0) throw const FormatException('Malformed SAS token.');
      final name = field.substring(0, separator).toLowerCase();
      if (fields.containsKey(name)) {
        throw const FormatException('Duplicate SAS token field.');
      }
      fields[name] = field.substring(separator + 1);
    }
    if (!fields.containsKey('sr') ||
        !fields.containsKey('sig') ||
        !fields.containsKey('se')) {
      throw const FormatException('SAS token requires sr, sig and se fields.');
    }

    final DateTime expiresOn;
    try {
      final seconds = double.parse(Uri.decodeQueryComponent(fields['se']!));
      // Match the C# DateTime range before converting to Dart's wider range.
      if (!seconds.isFinite ||
          seconds < -62135596800 ||
          seconds >= 253402300800) {
        throw const FormatException();
      }
      expiresOn = DateTime.fromMicrosecondsSinceEpoch(
        (seconds * Duration.microsecondsPerSecond).truncate(),
        isUtc: true,
      );
    } on FormatException {
      // Parser exceptions can contain their input; never forward credentials.
      throw const FormatException('Invalid SAS token expiry.');
    } on ArgumentError {
      throw const FormatException('Invalid SAS token expiry.');
    }
    if (expiresOn.add(const Duration(minutes: 5)).isBefore(now)) {
      throw const FormatException('SAS token has expired.');
    }
    return SharedAccessSignature._(value, expiresOn);
  }

  /// The credential sent as the MQTT password; must never be logged.
  final String value;

  /// The actual expiry in UTC, without a clock-skew allowance.
  final DateTime expiresOn;

  @override
  String toString() => 'SharedAccessSignature(<redacted>)';
}

// WebUtility.UrlEncode differs from Dart's URI encoders for spaces, ' and ~.
String encodeSasComponent(String value) =>
    Uri.encodeComponent(value)
        .replaceAll('%20', '+')
        .replaceAll("'", '%27')
        .replaceAll('~', '%7E');

// Dart accepts URL-safe and unpadded base64; the C# key validator does not.
List<int> decodeSharedAccessKey(String value) {
  final normalized = value.replaceAll('\r', '').replaceAll('\n', '');
  if (normalized.isEmpty ||
      normalized.length % 4 != 0 ||
      !RegExp(r'^[A-Za-z0-9+/]*={0,2}$').hasMatch(normalized)) {
    throw const FormatException('SharedAccessKey must be base64 encoded.');
  }
  try {
    return base64.decode(normalized);
  } on FormatException {
    throw const FormatException('SharedAccessKey must be base64 encoded.');
  }
}

int _roundToEven(double value) {
  final floor = value.floor();
  final fraction = value - floor;
  return fraction < 0.5 || (fraction == 0.5 && floor.isEven)
      ? floor
      : floor + 1;
}
