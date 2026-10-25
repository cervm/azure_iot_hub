// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license; see third_party/azure-iot-sdk-csharp-LICENSE.
// Adapted from DirectMethod/MethodRequest.cs, MethodResponse.cs and Utils.cs.
// See docs/upstream.md for the pinned reference and protocol constraints.
import 'dart:convert';
import 'dart:typed_data';

/// Handles a direct method and asynchronously returns its response.
///
/// Calls may overlap. The application owns execution timeouts; closing the client
/// does not cancel application work. Exceptions produce a status 500 response.
typedef MethodCallback = Future<MethodResponse> Function(MethodRequest request);

/// A direct-method invocation delivered by IoT Hub.
final class MethodRequest(
  /// The method name used to select a registered handler.
  final String name, [
  List<int>? data,
]) {
  /// The copied request bytes, or `null` when no data was supplied.
  final Uint8List? data = data == null
      ? null
      : Uint8List.fromList(data).asUnmodifiableView();

  /// The UTF-8 request text, or `null` for absent or empty data.
  String? get dataAsJson => _jsonText(data);
}

/// A direct-method result with an application-defined integer status.
///
/// The optional result is copied and must be empty or valid UTF-8 JSON, at most
/// 128 KiB. Invalid JSON throws [FormatException]; excess size throws
/// [ArgumentError]. Omitting the result sends an empty response body.
final class MethodResponse(
  /// The status returned to the cloud caller.
  final int status, {
  List<int>? result,
}) {
  /// The copied response bytes, or `null` for an absent body.
  final Uint8List? result = _copyResult(result);

  /// The UTF-8 result text, or `null` for absent or empty data.
  String? get resultAsJson => _jsonText(result);
}

String? _jsonText(List<int>? bytes) => bytes == null || bytes.isEmpty
    ? null
    : utf8.decode(bytes, allowMalformed: true);

Uint8List? _copyResult(List<int>? bytes) {
  if (bytes == null) return null;
  if (bytes.length > 128 * 1024) {
    throw ArgumentError('Method payload exceeds the IoT Hub limit.');
  }
  final copy = Uint8List.fromList(bytes).asUnmodifiableView();
  validateMethodPayload(copy);
  return copy;
}

void validateMethodPayload(List<int> bytes) {
  if (bytes.length > 128 * 1024) {
    throw ArgumentError('Method payload exceeds the IoT Hub limit.');
  }
  if (bytes.isEmpty) return;
  try {
    jsonDecode(utf8.decode(bytes));
  } on FormatException {
    throw const FormatException('Invalid method JSON payload.');
  }
}

/// Parses the method name and request identifier without retaining the payload.
(String name, String requestId)? parseMethodTopic(String topic) {
  if (topic.split('/')
      case [r'$iothub', 'methods', 'POST', final name, final query]
      when name.isNotEmpty && query.startsWith('?')) {
    try {
      final parameters = Uri(query: query.substring(1)).queryParametersAll;
      if (parameters[r'$rid'] case [final requestId]
          when requestId.isNotEmpty) {
        return (name, requestId);
      }
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
  }
  return null;
}
