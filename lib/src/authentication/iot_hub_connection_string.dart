// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license; see third_party/azure-iot-sdk-csharp-LICENSE.
// Adapted from the pinned C# SDK's IotHubConnectionStringBuilder,
// CommonExtensionMethods.ToDictionary and DeviceAuthenticationWithSakRefresh.
// See doc/upstream.md for the source mapping.
import 'shared_access_signature.dart';

/// Acquires a SAS for [iotHub], using the suggested lifetime when appropriate.
///
/// Matches C#'s `SafeCreateNewToken` callback. The returned token's expiry controls
/// caching. The provider owns its I/O timeouts; caller cancellation does not stop
/// shared acquisition. The suggested lifetime is in seconds and defaults to one
/// hour. The provider may return a token with a different lifetime.
typedef SasTokenProvider = Future<String> Function(
  String iotHub,
  int suggestedTimeToLiveSeconds,
);

/// The internal device identity and authentication configuration.
final class IotHubConnectionString {
  const IotHubConnectionString._({
    required this.hostName,
    required this.deviceId,
    this.gatewayHostName,
    this.sharedAccessKey,
    this.sharedAccessKeyName,
    this.sharedAccessSignature,
    this.tokenProvider,
    this.usingX509 = false,
  });

  /// Parses supported device credentials using C# connection-string semantics.
  factory IotHubConnectionString.parse(String value, {required DateTime now}) {
    // Splitting on every semicolon corrupts legacy device IDs allowed by C#.
    final matches = RegExp(r'(?:^|;)([^;=]*)=').allMatches(value).toList();
    if (matches.isEmpty) {
      throw const FormatException('Malformed connection string.');
    }
    final fields = <String, String>{};
    for (var i = 0; i < matches.length; i++) {
      final match = matches[i];
      final name = match[1]!.toLowerCase();
      if (fields.containsKey(name)) {
        throw const FormatException('Duplicate connection-string property.');
      }
      final end = i + 1 < matches.length ? matches[i + 1].start : value.length;
      fields[name] = value.substring(match.end, end);
    }

    final hostName = _validate(
      fields['hostname'],
      'HostName',
      _hostNamePattern,
    );
    final deviceId = _validate(
      fields['deviceid'],
      'DeviceId',
      _deviceIdPattern,
    );
    if (fields.containsKey('moduleid')) {
      throw UnsupportedError('Module credentials are not supported.');
    }
    if (fields['x509']?.toLowerCase() == 'true' ||
        fields['x509cert']?.toLowerCase() == 'true') {
      throw UnsupportedError(
        'Use DeviceClient.withX509 for certificate authentication.',
      );
    }

    // C# treats an empty key as absent when selecting SAS authentication.
    final rawKey = fields['sharedaccesskey'];
    final key = rawKey == '' ? null : rawKey;
    final token = fields['sharedaccesssignature'];
    if ((key == null || key.trim().isEmpty) ==
        (token == null || token.trim().isEmpty)) {
      throw const FormatException(
        'Specify either SharedAccessKey or SharedAccessSignature.',
      );
    }
    final keyName = fields['sharedaccesskeyname'];
    if (keyName != null) {
      _validate(keyName, 'SharedAccessKeyName', _keyNamePattern);
      if (key == null) {
        throw const FormatException('SharedAccessKeyName requires a key.');
      }
    }
    if (key != null) {
      _validate(key, 'SharedAccessKey', RegExp(r'^.+$'));
      decodeSharedAccessKey(key);
    }
    final gateway = fields['gatewayhostname'];
    if (gateway != null && gateway.isNotEmpty) {
      _validate(gateway, 'GatewayHostName', _hostNamePattern);
    }
    return ._(
      hostName: hostName,
      deviceId: deviceId,
      gatewayHostName: gateway,
      sharedAccessKey: key,
      sharedAccessKeyName: keyName,
      sharedAccessSignature: key != null ? null : .parse(token!, now: now),
    );
  }

  /// Creates device credentials backed by an asynchronous SAS provider.
  factory IotHubConnectionString.withTokenProvider({
    required String hostName,
    required String deviceId,
    required SasTokenProvider tokenProvider,
    String? gatewayHostName,
  }) {
    _validate(hostName, 'HostName', _hostNamePattern);
    _validate(deviceId, 'DeviceId', _deviceIdPattern);
    if (gatewayHostName != null && gatewayHostName.isNotEmpty) {
      _validate(gatewayHostName, 'GatewayHostName', _hostNamePattern);
    }
    return ._(
      hostName: hostName,
      deviceId: deviceId,
      gatewayHostName: gatewayHostName,
      tokenProvider: tokenProvider,
    );
  }

  /// Creates a device identity for transport-level certificate authentication.
  factory IotHubConnectionString.withX509({
    required String hostName,
    required String deviceId,
    String? gatewayHostName,
  }) {
    _validate(hostName, 'HostName', _hostNamePattern);
    _validate(deviceId, 'DeviceId', _deviceIdPattern);
    if (gatewayHostName != null && gatewayHostName.isNotEmpty) {
      _validate(gatewayHostName, 'GatewayHostName', _hostNamePattern);
    }
    return ._(
      hostName: hostName,
      deviceId: deviceId,
      gatewayHostName: gatewayHostName,
      usingX509: true,
    );
  }

  final String hostName;
  final String deviceId;
  final String? gatewayHostName;
  final String? sharedAccessKey;
  final String? sharedAccessKeyName;
  final SharedAccessSignature? sharedAccessSignature;
  final SasTokenProvider? tokenProvider;
  final bool usingX509;

  /// The network destination, which can differ from the SAS audience.
  String get connectionHostName {
    final gateway = gatewayHostName;
    return gateway != null && gateway.isNotEmpty ? gateway : hostName;
  }

  /// Produces a device-scoped token, or a hub-scoped token for a policy key.
  ///
  /// Returns an externally supplied token unchanged, as the C# provider does.
  /// The client must arrange renewal or replacement before its actual expiry.
  SharedAccessSignature createSasToken({
    required DateTime now,
    Duration timeToLive = const .new(hours: 1),
  }) {
    if (usingX509) {
      throw StateError('X.509 credentials do not use SAS tokens.');
    }
    if (tokenProvider != null) {
      throw StateError(
        'Provider credentials require asynchronous acquisition.',
      );
    }
    final supplied = sharedAccessSignature;
    if (supplied != null) {
      return supplied;
    }
    return .generate(
      key: sharedAccessKey!,
      target: sharedAccessKeyName == null
          ? '$hostName/devices/${encodeSasComponent(deviceId)}'
          : hostName,
      keyName: sharedAccessKeyName,
      now: now,
      timeToLive: timeToLive,
    );
  }

  @override
  String toString() => 'IotHubConnectionString(<redacted>)';
}

// Preserve the reference SDK's validation expressions for supported fields.
final _hostNamePattern = RegExp(r'[a-zA-Z0-9_\-.]+$');
final _deviceIdPattern = RegExp(r"^[A-Za-z0-9\-:.+%_#*?!(),=@;$']{1,128}$");
final _keyNamePattern = RegExp(r'^[a-zA-Z0-9_\-@.]+$');

String _validate(String? value, String property, RegExp pattern) {
  if (value == null || value.trim().isEmpty || !pattern.hasMatch(value)) {
    throw FormatException('Missing or invalid $property.');
  }
  return value;
}
