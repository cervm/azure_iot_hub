// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license; see third_party/azure-iot-sdk-csharp-LICENSE.
// Adapted from MqttIotHubAdapter.PopulateMessagePropertiesFromPacket and
// UrlEncodedDictionarySerializer.Deserialize. See docs/upstream.md.
import 'dart:typed_data';

/// Receives a message that the application must explicitly complete.
///
/// As with desired-property callbacks, asynchronous work is not awaited.
/// The application owns its asynchronous errors, timeouts and completion order.
typedef ReceiveMessageHandler = void Function(CloudToDeviceMessage message);

/// An immutable cloud-to-device delivery, valid for completion on its client.
final class CloudToDeviceMessage {
  CloudToDeviceMessage._(List<int> bytes, Map<String, String?> fields)
    : payload = Uint8List.fromList(bytes).asUnmodifiableView(),
      properties = .unmodifiable({
        for (final entry in fields.entries)
          if (!entry.key.startsWith(r'$.')) entry.key: entry.value,
      }),
      systemProperties = .unmodifiable({
        for (final entry in fields.entries)
          if (entry.key.startsWith(r'$.')) entry.key: entry.value,
      });

  /// The copied payload, exposed as unmodifiable bytes.
  final Uint8List payload;

  /// Application properties, preserving null and empty values separately.
  final Map<String, String?> properties;

  /// System properties with their MQTT wire names, such as `$.mid`.
  ///
  /// Values remain strings; dates and other optional fields are not converted.
  final Map<String, String?> systemProperties;

  /// The service-supplied message identifier, when present.
  String? get messageId => systemProperties[r'$.mid'];

  /// The correlation identifier, when present.
  String? get correlationId => systemProperties[r'$.cid'];

  /// The content media type, when present.
  String? get contentType => systemProperties[r'$.ct'];

  /// The payload encoding, when present.
  String? get contentEncoding => systemProperties[r'$.ce'];
}

CloudToDeviceMessage decodeCloudToDeviceMessage(
  List<int> payload,
  String propertyBag,
) {
  final fields = <String, String?>{};
  // C# stops at the next topic separator. Encoded slashes remain property data.
  final bag = propertyBag.split('/').first;
  try {
    if (bag.isNotEmpty) {
      for (final field in bag.split('&')) {
        final parts = field.split('=');
        if (parts.length > 2 || parts.first.isEmpty) {
          throw const FormatException();
        }
        fields[Uri.decodeComponent(parts.first)] = parts.length == 1
            ? null
            : Uri.decodeComponent(parts.last);
      }
    }
  } on FormatException {
    throw const FormatException('Invalid cloud-to-device message properties.');
  } on ArgumentError {
    throw const FormatException('Invalid cloud-to-device message properties.');
  }
  return CloudToDeviceMessage._(payload, fields);
}
