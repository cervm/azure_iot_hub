// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license; see third_party/azure-iot-sdk-csharp-LICENSE.
// Adapted from ConnectionStatus, ConnectionStatusChangeReason and InternalClient.
// See doc/upstream.md for the pinned reference and Dart adaptations.

/// The device client's connection state.
enum ConnectionStatus {
  /// A connection failed and automatic recovery has stopped.
  disconnected,

  /// The connection and required subscriptions are ready for operations.
  connected,

  /// The client is attempting to establish or recover its connection.
  disconnectedRetrying,

  /// The client connection was closed by the application.
  disabled,
}

/// The reason for a connection-status transition.
///
/// Names correspond to C#'s reasons. The MQTT implementation emits only reasons
/// supported by its lifecycle and protocol evidence.
enum ConnectionStatusChangeReason {
  /// The connection and required subscriptions are ready.
  connectionOk,

  /// The SAS token expired and could not be renewed.
  ///
  /// Not emitted by this implementation or the pinned C# SDK.
  expiredSasToken,

  /// The service identified the device as deleted or disabled.
  ///
  /// Not emitted by this MQTT implementation; CONNACK cannot distinguish this
  /// condition from other authentication rejections.
  deviceDisabled,

  /// The service rejected the supplied credentials.
  badCredential,

  /// The connection's retry policy was exhausted.
  ///
  /// Not emitted while the client's unlimited transient recovery remains active.
  /// An individual operation's deadline does not exhaust connection recovery.
  retryExpired,

  /// The network is unavailable.
  ///
  /// Not emitted by this implementation or the pinned C# SDK; network failures
  /// use [communicationError].
  noNetwork,

  /// A network, TLS, protocol or provider failure interrupted the connection.
  communicationError,

  /// The application closed the client.
  clientClose,
}

/// Observes a changed connection status and its reason.
typedef ConnectionStatusChangesHandler = void Function(
  ConnectionStatus status,
  ConnectionStatusChangeReason reason,
);
