/// @docImport 'pending_operation.dart';
/// @docImport 'dart:async';
library;

import 'dart:io';

import 'authentication/iot_hub_connection_string.dart';
import 'cancellation.dart';
import 'connection_status.dart';
import 'internal_client.dart';
import 'telemetry_message.dart';
import 'transport/mqtt_transport_type.dart';
import 'twin.dart';

/// An Azure IoT Hub device client for telemetry and device twin properties.
///
/// Operations open the connection implicitly and retry transient failures within
/// one finite deadline, including when a cancellation token is supplied. The
/// default deadline is four minutes. Cancelling an operation does not stop shared
/// connection recovery. Call [close] when the client is no longer needed.
///
/// Operational failures throw [OperationFailure]. Invalid arguments and malformed
/// local data throw [ArgumentError] or [FormatException].
final class DeviceClient {
  /// Creates a client from a device connection string with a shared key or SAS.
  ///
  /// Construction validates credentials without opening a connection. Fixed SAS
  /// tokens are not renewed; shared-key credentials generate tokens as needed.
  /// A connection string may include `GatewayHostName` for gateway routing.
  ///
  /// [transport] defaults to MQTT/TLS. [port] defaults to 8883 for TCP and 443 for
  /// WebSockets. [securityContext] defaults to the platform's trusted roots.
  /// [operationTimeout] covers all attempts; [connectionTimeout] bounds each
  /// connection attempt and [twinResponseTimeout] bounds each twin response wait.
  /// All timeouts must be positive.
  ///
  /// [maxPending] bounds pending operations, including submitted work retained
  /// after cancellation; it must be between 1 and 32767. [maxPendingBytes] bounds
  /// retained operation bytes, including payloads, topics and twin responses,
  /// and must be positive.
  DeviceClient.fromConnectionString(
    String connectionString, {
    MqttTransportType transport = .tcp,
    Duration operationTimeout = const .new(minutes: 4),
    Duration connectionTimeout = const .new(seconds: 60),
    Duration twinResponseTimeout = const .new(seconds: 60),
    int maxPending = 16,
    int maxPendingBytes = 4 * 1024 * 1024,
    int? port,
    SecurityContext? securityContext,
  }) : _client = .new(
         .parse(connectionString, now: DateTime.now().toUtc()),
         transport: transport,
         operationTimeout: operationTimeout,
         connectionTimeout: connectionTimeout,
         twinResponseTimeout: twinResponseTimeout,
         maxPending: maxPending,
         maxPendingBytes: maxPendingBytes,
         port: port,
         securityContext: securityContext,
       );

  /// Creates a client whose SAS credentials come from [tokenProvider].
  ///
  /// Acquisition is serialized and cached. A connection requests a fresh token
  /// when the cached token enters its renewal window; renewal does not schedule
  /// a disconnect. The provider owns its I/O timeouts. Caller cancellation and
  /// client close do not wait for an outstanding provider future.
  ///
  /// [hostName] identifies the hub. [gatewayHostName], when supplied, changes the
  /// network destination without changing the hub identity or token audience.
  /// Transport, timeout and capacity options follow [DeviceClient.fromConnectionString].
  DeviceClient.withTokenProvider({
    required String hostName,
    required String deviceId,
    required SasTokenProvider tokenProvider,
    String? gatewayHostName,
    MqttTransportType transport = .tcp,
    Duration operationTimeout = const .new(minutes: 4),
    Duration connectionTimeout = const .new(seconds: 60),
    Duration twinResponseTimeout = const .new(seconds: 60),
    int maxPending = 16,
    int maxPendingBytes = 4 * 1024 * 1024,
    int? port,
    SecurityContext? securityContext,
  }) : _client = .new(
         .withTokenProvider(
           hostName: hostName,
           deviceId: deviceId,
           tokenProvider: tokenProvider,
           gatewayHostName: gatewayHostName,
         ),
         transport: transport,
         operationTimeout: operationTimeout,
         connectionTimeout: connectionTimeout,
         twinResponseTimeout: twinResponseTimeout,
         maxPending: maxPending,
         maxPendingBytes: maxPendingBytes,
         port: port,
         securityContext: securityContext,
       );

  final InternalClient _client;

  /// Whether the connection is currently ready for operations.
  ///
  /// This is a snapshot; subsequent operations can still encounter a disconnect.
  bool get isConnected => _client.isConnected;

  /// Registers or replaces the connection-status handler; `null` removes it.
  ///
  /// Registration does not replay the current state. Notifications occur when
  /// the status or reason changes, independently of individual operations.
  /// The handler runs synchronously in its registering [Zone]. Handler errors
  /// are reported to that zone without interrupting connection recovery.
  /// Asynchronous work started by the handler is not awaited.
  /// The first [close] reports [ConnectionStatus.disabled] with
  /// [ConnectionStatusChangeReason.clientClose], then releases the handler.
  void setConnectionStatusChangesHandler(
    ConnectionStatusChangesHandler? handler,
  ) => _client.setConnectionStatusChangesHandler(handler);

  /// Opens the connection and subscribes to twin responses.
  Future<void> open({CancellationToken? cancellationToken}) =>
      _client.open(cancellationToken: cancellationToken);

  /// Sends [message] and waits for the hub's MQTT acknowledgement.
  ///
  /// Success does not confirm downstream routing or application processing.
  Future<void> sendEvent(
    TelemetryMessage message, {
    CancellationToken? cancellationToken,
  }) => _client.sendEvent(message, cancellationToken: cancellationToken);

  /// Retrieves the device's desired and reported properties.
  ///
  /// The result contains the properties available to the device, not the full
  /// service-side twin. It does not merge previously received desired patches.
  Future<Twin> getTwin({CancellationToken? cancellationToken}) async =>
      .new(await _client.getTwin(cancellationToken: cancellationToken));

  /// Updates reported properties and waits for the matching service response.
  ///
  /// Null values delete properties; omitted properties remain unchanged. The
  /// JSON-compatible [properties] are captured when called and reused on retries.
  Future<void> updateReportedProperties(
    Map<String, Object?> properties, {
    CancellationToken? cancellationToken,
  }) => _client.updateReportedProperties(
    properties,
    cancellationToken: cancellationToken,
  );

  /// Registers or replaces a desired-property callback; `null` unsubscribes.
  ///
  /// Registration and removal wait for the service's subscription acknowledgement.
  /// Reconnect restores the subscription. Applications own snapshot retrieval,
  /// version reconciliation and any asynchronous work started by the callback.
  Future<void> setDesiredPropertyUpdateCallback(
    DesiredPropertyUpdateCallback? callback, {
    CancellationToken? cancellationToken,
  }) => _client.setDesiredPropertyUpdateCallback(
    callback,
    cancellationToken: cancellationToken,
  );

  /// Permanently closes the client and fails pending operations.
  ///
  /// Repeated calls are harmless. Create a new client to connect again.
  Future<void> close() => _client.close();
}
