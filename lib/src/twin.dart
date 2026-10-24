// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license; see third_party/azure-iot-sdk-csharp-LICENSE.
// Adapted from TwinProperties and MqttTransportHandler; see docs/upstream.md.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// Receives a desired-property patch, including its `$version` and null values.
///
/// Invocation is synchronous. As in the pinned C# callback dispatcher, returned
/// futures are not awaited; applications own any asynchronous work they start.
typedef DesiredPropertyUpdateCallback = void Function(
  Map<String, Object?> patch,
);

/// Decodes a desired-property notification without merging or filtering versions.
Map<String, Object?> decodeDesiredPropertyPatch(List<int> payload) {
  try {
    final value = jsonDecode(utf8.decode(payload));
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Expected desired-property patch.');
    }
    return Map.unmodifiable(value);
  } on FormatException {
    throw const FormatException('Invalid desired-property patch.');
  }
}

/// Encodes a reported-property patch, retaining null values for deletion.
///
/// Captures nested values before queuing so retries use the same bytes.
Uint8List encodeReportedProperties(Map<String, Object?> properties) {
  try {
    final payload = utf8.encode(jsonEncode(properties));
    if (payload.length > 0x3ffff) {
      throw ArgumentError(
        'Reported-property payload exceeds the C# MQTT limit.',
      );
    }
    return payload.asUnmodifiableView();
  } on JsonUnsupportedObjectError {
    // Serializer errors can otherwise include property values or custom objects.
    throw const FormatException(
      'Reported properties must be JSON serializable.',
    );
  }
}

/// The desired and reported property collections returned by a twin GET.
///
/// Collection maps retain `$version`, `$metadata`, nested values and nulls.
/// This model is internal while the public device API is being established.
final class TwinProperties._(
  final Map<String, Object?>? desired,
  final Map<String, Object?>? reported,
) {
  factory fromBytes(List<int> bytes) {
    try {
      final body = jsonDecode(utf8.decode(bytes));
      if (body is! Map<String, dynamic>) {
        throw const FormatException('Expected twin properties.');
      }
      Map<String, Object?>? collection(String name) {
        if (!body.containsKey(name)) return const {};
        return switch (body[name]) {
          final Map<String, Object?> value => Map.unmodifiable(value),
          null => null,
          _ => throw const FormatException('Expected a property collection.'),
        };
      }

      return TwinProperties._(collection('desired'), collection('reported'));
    } on FormatException {
      // JSON parsing errors must not include device properties in diagnostics.
      throw const FormatException('Invalid twin properties.');
    }
  }
}

/// An internal response correlated by the IoT Hub request identifier.
final class TwinResponse(
  final String requestId,
  final int status,
  final Uint8List payload,
) {
  static TwinResponse? parse(String topic, List<int> payload) {
    if (topic.split('/')
        case [r'$iothub', 'twin', 'res', final code, final query]
        when query.startsWith('?')) {
      final status = int.tryParse(code);
      if (status == null || !RegExp(r'^[0-9]+$').hasMatch(code)) return null;
      try {
        final requestIds = <String>[];
        for (final part in query.substring(1).split('&')) {
          final id = Uri.splitQueryString(part)[r'$rid'];
          if (id != null) requestIds.add(id);
        }
        if (requestIds case [final requestId]) {
          return TwinResponse(requestId, status, Uint8List.fromList(payload));
        }
        return null;
      } on ArgumentError {
        return null;
      } on FormatException {
        return null;
      }
    }
    return null;
  }
}

/// Creates a UUID v4 request identifier, matching C#'s Guid.NewGuid format.
String newTwinRequestId() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
