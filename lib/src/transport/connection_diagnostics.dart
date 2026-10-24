/// The last observed setup stage, without endpoints or authentication data.
enum ConnectionStage {
  idle,
  authentication,
  tcp,
  tls,
  webSocketUpgrade,
  mqttConnack,
  twinSubscription,
  ready,
}

/// A bounded internal snapshot for diagnosing connection failures safely.
final class ConnectionDiagnostics {
  int attempts = 0;
  ConnectionStage stage = ConnectionStage.idle;
  ConnectionStage? failureStage;
  String? failure;
  int? httpStatus;
  int? lastWebSocketCloseCode;

  // Only enum names are retained, never exception messages or packet data.
  void recordFailure(Enum category, {int? httpStatus}) {
    failureStage = stage;
    failure = category.name;
    this.httpStatus = httpStatus;
  }

  @override
  String toString() =>
      'attempts=$attempts, stage=${stage.name}, '
      'lastFailure=$failure, failureStage=${failureStage?.name}, '
      'httpStatus=$httpStatus, webSocketCloseCode=$lastWebSocketCloseCode';
}
