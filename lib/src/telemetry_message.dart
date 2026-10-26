// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license; see third_party/azure-iot-sdk-csharp-LICENSE.
// Adapted from MqttIotHubAdapter.PopulateMessagePropertiesFromMessage and
// UrlEncodedDictionarySerializer.Serialize. See doc/upstream.md.
import 'dart:convert';
import 'dart:typed_data';

/// An immutable snapshot of a telemetry payload and its message properties.
final class TelemetryMessage {
  /// Captures [payload] and [properties] for sending and retries.
  ///
  /// System fields such as [messageId] take precedence over matching application
  /// properties. Null property values are retained and differ from empty strings.
  /// Throws [ArgumentError] for payloads larger than 262143 bytes or total message
  /// sizes above 262144 bytes. The total includes UTF-8 system-property values
  /// and application-property names and values after merging. Keys starting with
  /// `$.` identify system properties. Encoded topic limits are checked on submission.
  TelemetryMessage(
    List<int> payload, {
    Map<String, String?> properties = const {},
    String? messageId,
    String? correlationId,
    String? contentType,
    String? contentEncoding,
  }) {
    if (payload.length > 0x3ffff) {
      throw ArgumentError('Telemetry payload exceeds the C# MQTT limit.');
    }
    this.payload = Uint8List.fromList(payload).asUnmodifiableView();
    _properties = {
      r'$.mid': ?messageId,
      r'$.cid': ?correlationId,
      r'$.ct': ?contentType,
      r'$.ce': ?contentEncoding,
    };
    for (final entry in properties.entries) {
      _properties.putIfAbsent(entry.key, () => entry.value);
    }
    var size = this.payload.length;
    for (final MapEntry(:key, :value) in _properties.entries) {
      if (!key.startsWith(r'$.')) size += utf8.encode(key).length;
      if (value != null) size += utf8.encode(value).length;
      if (size > 0x40000) {
        throw ArgumentError(
          'Telemetry message exceeds the IoT Hub size limit.',
        );
      }
    }
  }

  /// The copied payload, exposed as unmodifiable bytes.
  late final Uint8List payload;
  late final Map<String, String?> _properties;
}

String telemetryTopic(TelemetryMessage message, String deviceId) {
  final topic = StringBuffer('devices/$deviceId/messages/events/');
  var first = true;
  for (final MapEntry(:key, :value) in message._properties.entries) {
    if (!first) topic.write('&');
    first = false;
    topic.write(escapeDataString(key));
    if (value != null) {
      topic.write('=${escapeDataString(value)}');
    }
    if (topic.length > 0xffff) {
      throw ArgumentError('Telemetry topic exceeds the MQTT limit.');
    }
  }
  if (message._properties.isNotEmpty) topic.write('/');
  final value = topic.toString();
  if (utf8.encode(value).length > 0xffff) {
    throw ArgumentError('Telemetry topic exceeds the MQTT limit.');
  }
  return value;
}

// Uri.EscapeDataString uses RFC 3986, unlike WebUtility.UrlEncode used for SAS.
String escapeDataString(String value) =>
    Uri.encodeComponent(value)
        .replaceAll('!', '%21')
        .replaceAll("'", '%27')
        .replaceAll('(', '%28')
        .replaceAll(')', '%29')
        .replaceAll('*', '%2A');
