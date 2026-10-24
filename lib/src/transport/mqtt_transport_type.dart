/// The MQTT transport selection; both options require TLS.
enum MqttTransportType {
  /// MQTT over TLS, using port 8883 by default.
  tcp,

  /// MQTT over secure WebSockets, using port 443 by default.
  webSocket;

  /// The standard port for this transport.
  int get defaultPort => switch (this) {
    .tcp => 8883,
    .webSocket => 443,
  };
}
