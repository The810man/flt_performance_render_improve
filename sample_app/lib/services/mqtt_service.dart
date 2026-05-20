import 'dart:async';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

// ---------------------------------------------------------------------------
// Configuration — edit these to match your broker.
// ---------------------------------------------------------------------------

class MqttConfig {
  final String host;
  final int    port;
  final String clientId;
  final String? username;
  final String? password;
  final List<String> subscriptions;

  const MqttConfig({
    required this.host,
    this.port = 1883,
    this.clientId = 'flt-grow',
    this.username,
    this.password,
    this.subscriptions = const [],
  });
}

// Default config — override at runtime via MqttService.config.
const kDefaultMqttConfig = MqttConfig(
  host: '127.0.0.1',
  port: 1883,
  subscriptions: [
    'grow/+/temperature',
    'grow/+/humidity',
    'grow/+/co2',
    'grow/+/vpd',
    'grow/+/ppfd',
    'grow/+/ph',
    'grow/+/ec',
    'grow/+/water_temp',
    'grow/+/stage',
    'grow/+/lights',
    'grow/+/day',
  ],
);

// ---------------------------------------------------------------------------

enum MqttState { disconnected, connecting, connected, error }

class MqttService {
  MqttConfig config;

  MqttService({this.config = kDefaultMqttConfig});

  MqttServerClient? _client;

  MqttState state = MqttState.disconnected;
  String? lastError;
  int messageCount = 0;
  int messageRate  = 0;     // msgs/s (updated every second)
  DateTime? connectedSince;

  // topic → last payload string
  final Map<String, String> data = {};

  // Listeners notified on any update.
  final List<VoidCallback> _listeners = [];
  void addListener(VoidCallback cb) => _listeners.add(cb);
  void removeListener(VoidCallback cb) => _listeners.remove(cb);
  void _notify() { for (final cb in _listeners) { cb(); } }

  Timer? _rateTimer;
  int _msgCountSnapshot = 0;

  // ---- Lifecycle ------------------------------------------------------------

  Future<void> connect() async {
    if (state == MqttState.connecting || state == MqttState.connected) return;
    _setState(MqttState.connecting);

    _client?.disconnect();
    _client = MqttServerClient.withPort(config.host, config.clientId, config.port)
      ..logging(on: false)
      ..keepAlivePeriod = 20
      ..connectTimeoutPeriod = 5000
      ..onConnected    = _onConnected
      ..onDisconnected = _onDisconnected
      ..onBadCertificate = (_) => true;

    final connMsg = MqttConnectMessage()
        .withClientIdentifier(config.clientId)
        .startClean()
        .withWillQos(MqttQos.atLeastOnce);
    if (config.username != null) {
      connMsg.authenticateAs(config.username!, config.password ?? '');
    }
    _client!.connectionMessage = connMsg;

    try {
      await _client!.connect();
    } on Exception catch (e) {
      lastError = e.toString();
      _setState(MqttState.error);
      _scheduleReconnect();
      return;
    }

    if (_client!.connectionStatus!.state != MqttConnectionState.connected) {
      lastError = 'Connection refused: ${_client!.connectionStatus!.returnCode}';
      _setState(MqttState.error);
      _scheduleReconnect();
      return;
    }
  }

  void disconnect() {
    _rateTimer?.cancel();
    _client?.disconnect();
    _setState(MqttState.disconnected);
  }

  // ---- Publish --------------------------------------------------------------

  void publish(String topic, String payload, {MqttQos qos = MqttQos.atLeastOnce}) {
    if (state != MqttState.connected) return;
    final builder = MqttClientPayloadBuilder()..addString(payload);
    _client!.publishMessage(topic, qos, builder.payload!);
  }

  // ---- Internal -------------------------------------------------------------

  void _onConnected() {
    _setState(MqttState.connected);
    connectedSince = DateTime.now();

    for (final topic in config.subscriptions) {
      _client!.subscribe(topic, MqttQos.atLeastOnce);
    }

    _client!.updates!.listen((messages) {
      for (final msg in messages) {
        final pub = msg.payload as MqttPublishMessage;
        final payload =
            MqttPublishPayload.bytesToStringAsString(pub.payload.message);
        data[msg.topic] = payload;
        messageCount++;
      }
      _notify();
    });

    _rateTimer?.cancel();
    _rateTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      messageRate  = messageCount - _msgCountSnapshot;
      _msgCountSnapshot = messageCount;
      _notify();
    });
  }

  void _onDisconnected() {
    _setState(MqttState.disconnected);
    _rateTimer?.cancel();
    _scheduleReconnect();
  }

  void _setState(MqttState s) {
    state = s;
    _notify();
  }

  Timer? _reconnectTimer;
  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), connect);
  }
}

typedef VoidCallback = void Function();
