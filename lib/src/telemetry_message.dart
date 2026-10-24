// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license; see third_party/azure-iot-sdk-csharp-LICENSE.
// Adapted from MqttIotHubAdapter.PopulateMessagePropertiesFromMessage and
// UrlEncodedDictionarySerializer.Serialize. See docs/upstream.md.
import 'dart:convert';
import 'dart:typed_data';

/// An immutable telemetry snapshot for the internal client.
final class TelemetryMessage {
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
  }

  late final Uint8List payload;
  late final Map<String, String?> _properties;

  String topic(String deviceId) {
    final topic = StringBuffer('devices/$deviceId/messages/events/');
    var first = true;
    for (final entry in _properties.entries) {
      if (!first) topic.write('&');
      first = false;
      topic.write(escapeDataString(entry.key));
      if (entry.value != null) {
        topic.write('=${escapeDataString(entry.value!)}');
      }
      if (topic.length > 0xffff) {
        throw ArgumentError('Telemetry topic exceeds the MQTT limit.');
      }
    }
    if (_properties.isNotEmpty) topic.write('/');
    final value = topic.toString();
    if (utf8.encode(value).length > 0xffff) {
      throw ArgumentError('Telemetry topic exceeds the MQTT limit.');
    }
    return value;
  }
}

// Uri.EscapeDataString uses RFC 3986, unlike WebUtility.UrlEncode used for SAS.
String escapeDataString(String value) =>
    Uri.encodeComponent(value)
        .replaceAll('!', '%21')
        .replaceAll("'", '%27')
        .replaceAll('(', '%28')
        .replaceAll(')', '%29')
        .replaceAll('*', '%2A');
