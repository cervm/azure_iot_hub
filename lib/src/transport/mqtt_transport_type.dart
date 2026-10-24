/// The internal MQTT transport selection; both options require TLS.
enum MqttTransportType {
  tcp,
  webSocket;

  int get defaultPort => switch (this) {
    .tcp => 8883,
    .webSocket => 443,
  };
}
