import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'services/system_service.dart';
import 'services/mqtt_service.dart';
import 'tabs/system_tab.dart';
import 'tabs/plant_tab.dart';
import 'theme.dart';
import 'widgets/terminal_widgets.dart';

void main() {
  runApp(const GrowApp());
}

class GrowApp extends StatelessWidget {
  const GrowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GrowOS',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const _Shell(),
    );
  }
}

// ---------------------------------------------------------------------------

class _Shell extends StatefulWidget {
  const _Shell();

  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> {
  final _sys  = SystemService();
  final _mqtt = MqttService();

  int _tab = 0;
  static const _tabCount = 2;

  final _plantKey = GlobalKey<PlantTabState>();

  @override
  void initState() {
    super.initState();
    _sys.onUpdate  = _onUpdate;
    _mqtt.addListener(_onUpdate);
    _sys.start();
    _mqtt.connect();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _sys.stop();
    _mqtt.disconnect();
    super.dispose();
  }

  void _onUpdate() {
    if (mounted) setState(() {});
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final key = event.logicalKey;

    // Tab switching: Tab key or digit keys 1/2
    if (key == LogicalKeyboardKey.tab) {
      setState(() => _tab = (_tab + 1) % _tabCount);
      return true;
    }
    // Digit keys '1'/'2' for direct tab select
    final label = event.character;
    if (label == '1') { setState(() => _tab = 0); return true; }
    if (label == '2') { setState(() => _tab = 1); return true; }

    // Delegate arrow keys to plant tab
    if (_tab == 1) {
      String? dir;
      if (key == LogicalKeyboardKey.arrowUp)    dir = 'ArrowUp';
      if (key == LogicalKeyboardKey.arrowDown)  dir = 'ArrowDown';
      if (key == LogicalKeyboardKey.arrowLeft)  dir = 'ArrowLeft';
      if (key == LogicalKeyboardKey.arrowRight) dir = 'ArrowRight';
      if (dir != null) {
        _plantKey.currentState?.handleKey(dir);
        return true;
      }
    }

    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.bg,
      body: Column(
        children: [
          _Header(tab: _tab),
          const SizedBox(height: 1),
          Expanded(child: _buildTab()),
          const SizedBox(height: 1),
          _StatusBar(sys: _sys, mqtt: _mqtt),
        ],
      ),
    );
  }

  Widget _buildTab() {
    switch (_tab) {
      case 0:
        return SystemTab(sys: _sys, mqtt: _mqtt);
      case 1:
        return PlantTab(key: _plantKey, mqtt: _mqtt);
      default:
        return const SizedBox.shrink();
    }
  }
}

// ---------------------------------------------------------------------------
// Header bar
// ---------------------------------------------------------------------------

class _Header extends StatelessWidget {
  const _Header({required this.tab});
  final int tab;

  static const _tabs = ['SYS', 'GROW'];

  @override
  Widget build(BuildContext context) {
    return Container(
      color: C.bgHeader,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          const Text('GrowOS', style: T.title),
          const SizedBox(width: 16),
          ..._tabs.asMap().entries.map((e) {
            final active = e.key == tab;
            return Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: active ? C.bgSelected : Colors.transparent,
                  border: Border.all(
                    color: active ? C.borderHi : C.border,
                    width: 1,
                  ),
                ),
                child: Text(
                  '[${e.key + 1}] ${e.value}',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: active ? C.textHi : C.textDim,
                    fontWeight: active ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ),
            );
          }),
          const Spacer(),
          const Text('TAB=switch', style: T.muted),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Status bar
// ---------------------------------------------------------------------------

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.sys, required this.mqtt});
  final SystemService  sys;
  final MqttService    mqtt;

  @override
  Widget build(BuildContext context) {
    final s         = sys.stats;
    final connected = mqtt.state == MqttState.connected;
    final cpuPct    = (s.cpuAvg * 100).toStringAsFixed(0).padLeft(3);
    final memPct    = (s.memUsageFraction * 100).toStringAsFixed(0).padLeft(3);
    final now       = DateTime.now();
    final time      = '${now.hour.toString().padLeft(2, '0')}:'
                      '${now.minute.toString().padLeft(2, '0')}:'
                      '${now.second.toString().padLeft(2, '0')}';

    return Container(
      color: C.bgHeader,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: Row(
        children: [
          StatusDot(
            label: connected ? 'MQTT' : 'MQTT:${mqtt.state.name.toUpperCase()}',
            ok: connected,
            style: T.muted,
          ),
          const SizedBox(width: 16),
          Text('CPU $cpuPct%', style: T.muted),
          const SizedBox(width: 10),
          Text('MEM $memPct%', style: T.muted),
          const Spacer(),
          Text(time, style: T.muted),
        ],
      ),
    );
  }
}

