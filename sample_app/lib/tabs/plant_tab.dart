import 'package:flutter/material.dart';
import '../services/mqtt_service.dart';
import '../theme.dart';
import '../widgets/terminal_widgets.dart';

// Cannabis-optimal sensor ranges [min, optLow, optHigh, max]
class _Range {
  final String label;
  final String unit;
  final double min;
  final double optLow;
  final double optHigh;
  final double max;
  const _Range(this.label, this.unit, this.min, this.optLow, this.optHigh, this.max);
}

const _kSensors = [
  _Range('TEMP',    '°C',          18,  22,   26,   32),
  _Range('HUMID',   '%',           30,  40,   50,   70),
  _Range('CO2',     'ppm',        400, 1000, 1200, 1600),
  _Range('PPFD',    'μmol/m²/s',    0,  600, 1000, 1500),
  _Range('VPD',     'kPa',        0.4,  0.8,  1.2,  2.0),
  _Range('PH',      '',           5.0,  5.8,  6.2,  7.0),
  _Range('EC',      'mS/cm',      0.5,  1.8,  2.4,  3.5),
];

const _kTopicKeys = [
  'temperature', 'humidity', 'co2', 'ppfd', 'vpd', 'ph', 'ec',
];

class PlantTab extends StatefulWidget {
  const PlantTab({super.key, required this.mqtt});
  final MqttService mqtt;

  @override
  State<PlantTab> createState() => PlantTabState();
}

class PlantTabState extends State<PlantTab> {
  int _zoneIndex = 0;
  int _selectedSensor = 0;

  List<String> get _zones {
    final zones = <String>{};
    for (final topic in widget.mqtt.data.keys) {
      final parts = topic.split('/');
      if (parts.length >= 2) zones.add(parts[1]);
    }
    final list = zones.toList()..sort();
    if (list.isEmpty) list.add('zone1');
    return list;
  }

  void handleKey(String key) {
    final zones = _zones;
    setState(() {
      if (key == 'ArrowUp') {
        _selectedSensor = (_selectedSensor - 1).clamp(0, _kSensors.length - 1);
      } else if (key == 'ArrowDown') {
        _selectedSensor = (_selectedSensor + 1).clamp(0, _kSensors.length - 1);
      } else if (key == 'ArrowLeft') {
        _zoneIndex = (_zoneIndex - 1).clamp(0, zones.length - 1);
      } else if (key == 'ArrowRight') {
        _zoneIndex = (_zoneIndex + 1).clamp(0, zones.length - 1);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final zones = _zones;
    final zone = zones[_zoneIndex.clamp(0, zones.length - 1)];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ZoneSelector(zones: zones, selected: _zoneIndex.clamp(0, zones.length - 1)),
          const SizedBox(height: 6),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 3, child: _SensorPanel(
                  zone: zone,
                  mqtt: widget.mqtt,
                  selectedIndex: _selectedSensor,
                )),
                const SizedBox(width: 6),
                Expanded(flex: 2, child: Column(
                  children: [
                    _ReservoirPanel(zone: zone, mqtt: widget.mqtt),
                    const SizedBox(height: 6),
                    _EnvPanel(zone: zone, mqtt: widget.mqtt),
                  ],
                )),
              ],
            ),
          ),
          const SizedBox(height: 6),
          const _KeyHints(),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _ZoneSelector extends StatelessWidget {
  const _ZoneSelector({required this.zones, required this.selected});
  final List<String> zones;
  final int selected;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Text('◄ ', style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: C.textDim)),
        ...zones.asMap().entries.map((e) {
          final active = e.key == selected;
          return Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              color: active ? C.bgSelected : C.bgPanel,
              child: Text(
                e.value.toUpperCase(),
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
        const Text(' ►', style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: C.textDim)),
      ],
    );
  }
}

// ---------------------------------------------------------------------------

class _SensorPanel extends StatelessWidget {
  const _SensorPanel({
    required this.zone,
    required this.mqtt,
    required this.selectedIndex,
  });
  final String zone;
  final MqttService mqtt;
  final int selectedIndex;

  double? _dval(String key) {
    final v = mqtt.data['grow/$zone/$key'];
    if (v == null) return null;
    return double.tryParse(v);
  }

  @override
  Widget build(BuildContext context) {
    return Panel(
      title: 'SENSORS',
      child: Column(
        children: _kSensors.asMap().entries.map((e) {
          final i     = e.key;
          final range = e.value;
          final val   = _dval(_kTopicKeys[i]);
          final selected = i == selectedIndex;
          return _SensorRow(
            range: range,
            value: val,
            selected: selected,
          );
        }).toList(),
      ),
    );
  }
}

class _SensorRow extends StatelessWidget {
  const _SensorRow({required this.range, required this.value, required this.selected});
  final _Range range;
  final double? value;
  final bool selected;

  String _fmt() {
    if (value == null) return '   --';
    return value!.toStringAsFixed(range.label == 'CO2' ? 0 : 1).padLeft(6);
  }

  @override
  Widget build(BuildContext context) {
    final bg = selected ? C.bgSelected : Colors.transparent;
    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
      child: Row(children: [
        SizedBox(
          width: 52,
          child: Text(
            '${selected ? "▶ " : "  "}${range.label}',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: selected ? C.textHi : C.text,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ),
        SizedBox(
          width: 52,
          child: Text(
            '${_fmt()} ${range.unit}',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: _valueColor(),
            ),
            textAlign: TextAlign.right,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: value == null
              ? Container(height: 8, color: C.barBg)
              : RangeBar(
                  value: value!,
                  min: range.min,
                  max: range.max,
                  optLow: range.optLow,
                  optHigh: range.optHigh,
                  height: 8,
                ),
        ),
      ]),
    );
  }

  Color _valueColor() {
    if (value == null) return C.textMuted;
    if (value! < range.optLow || value! > range.optHigh) {
      final span = range.optHigh - range.optLow;
      final dist = value! < range.optLow
          ? range.optLow - value!
          : value! - range.optHigh;
      return dist > span ? C.danger : C.warn;
    }
    return C.textHi;
  }
}

// ---------------------------------------------------------------------------

class _ReservoirPanel extends StatelessWidget {
  const _ReservoirPanel({required this.zone, required this.mqtt});
  final String zone;
  final MqttService mqtt;

  String _v(String key) => mqtt.data['grow/$zone/$key'] ?? '--';

  @override
  Widget build(BuildContext context) {
    return Panel(
      title: 'RESERVOIR',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _kv('pH',       _v('ph')),
          _kv('EC',       '${_v("ec")} mS/cm'),
          _kv('H₂O TEMP', '${_v("water_temp")} °C'),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
    padding: const EdgeInsets.only(bottom: 3),
    child: Row(children: [
      SizedBox(width: 72, child: Text('$k ', style: T.labelDim)),
      Flexible(child: Text(v, style: T.value)),
    ]),
  );
}

// ---------------------------------------------------------------------------

class _EnvPanel extends StatelessWidget {
  const _EnvPanel({required this.zone, required this.mqtt});
  final String zone;
  final MqttService mqtt;

  String _v(String key) => mqtt.data['grow/$zone/$key'] ?? '--';

  @override
  Widget build(BuildContext context) {
    final lights = _v('lights');
    final lightsOn = lights == '1' || lights.toLowerCase() == 'on';
    final stage = _v('stage');
    final day   = _v('day');

    return Panel(
      title: 'ENVIRONMENT',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text('LIGHTS  ', style: T.labelDim),
            Text(
              lightsOn ? '● ON ' : '○ OFF',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: lightsOn ? C.good : C.textDim,
                fontWeight: FontWeight.bold,
              ),
            ),
          ]),
          const SizedBox(height: 4),
          _kv('STAGE', stage.toUpperCase()),
          _kv('DAY',   day),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
    padding: const EdgeInsets.only(bottom: 3),
    child: Row(children: [
      SizedBox(width: 72, child: Text('$k ', style: T.labelDim)),
      Flexible(child: Text(v, style: T.value)),
    ]),
  );
}

// ---------------------------------------------------------------------------

class _KeyHints extends StatelessWidget {
  const _KeyHints();
  @override
  Widget build(BuildContext context) {
    return const Row(children: [
      KeyHint('↑↓', 'select sensor'),
      KeyHint('◄►', 'switch zone'),
    ]);
  }
}
