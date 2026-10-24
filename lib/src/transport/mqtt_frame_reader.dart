import 'dart:typed_data';

import 'package:mqtt_client/mqtt_client.dart';

/// Decodes complete MQTT frames within a bounded buffer across input chunks.
final class MqttFrameReader(
  final int maxBufferedBytes,
  final void Function(MqttMessage) onMessage,
) {
  final _incoming = BytesBuilder(copy: false);

  void add(List<int> bytes) {
    if (_incoming.length + bytes.length > maxBufferedBytes) {
      throw const FormatException('MQTT receive buffer exceeded.');
    }
    _incoming.add(bytes);
    final buffer = _incoming.takeBytes();
    var offset = 0;
    while (offset < buffer.length) {
      var index = offset + 1;
      var remaining = 0;
      var multiplier = 1;
      var completeLength = false;
      while (index < buffer.length) {
        final digit = buffer[index++];
        remaining += (digit & 127) * multiplier;
        if (digit < 128) {
          completeLength = true;
          break;
        }
        if (index - offset == 5) {
          throw const FormatException('Invalid MQTT length.');
        }
        multiplier *= 128;
      }
      if (!completeLength) break;
      if (index - offset + remaining > maxBufferedBytes) {
        throw const FormatException('MQTT frame exceeded limit.');
      }
      final end = index + remaining;
      if (end > buffer.length) break;
      final frame = MqttByteBuffer.fromList(buffer.sublist(offset, end));
      final MqttMessage message;
      try {
        message = MqttMessage.createFrom(frame);
      } catch (_) {
        throw const FormatException('Invalid MQTT frame.');
      }
      if (frame.position != frame.length) {
        throw const FormatException('Invalid MQTT frame.');
      }
      onMessage(message);
      offset = end;
    }
    if (offset < buffer.length) {
      _incoming.add(Uint8List.sublistView(buffer, offset));
    }
  }

  void clear() => _incoming.clear();
}
