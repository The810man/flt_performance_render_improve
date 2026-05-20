import 'package:flutter/material.dart';
import '../services/system_service.dart';
import '../services/mqtt_service.dart';
import '../theme.dart';
import '../widgets/terminal_widgets.dart';

class SystemTab extends StatelessWidget {
  const SystemTab({
    super.key,
    required this.sys,
    required this.mqtt,
  });

  final SystemService sys;
  final MqttService   mqtt;

  @override
  Widget build(BuildContext context) {
    final s = sys.stats;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(8),
      child: Column(
        children: [
          // Top row: CPU + Memory
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 3, child: _CpuPanel(s: s)),
                const SizedBox(width: 6),
                Expanded(flex: 2, child: _MemPanel(s: s)),
              ],
            ),
          ),
          const SizedBox(height: 6),
          // Bottom row: Network + MQTT status
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 2, child: _NetPanel(s: s)),
                const SizedBox(width: 6),
                Expanded(flex: 3, child: _MqttPanel(mqtt: mqtt)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// CPU panel
// ---------------------------------------------------------------------------

class _CpuPanel extends StatelessWidget {
  const _CpuPanel({required this.s});
  final SystemStats s;

  @override
  Widget build(BuildContext context) {
    return Panel(
      title: 'CPU',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Aggregate
          Row(children: [
            Expanded(
              child: BarGauge(
                value: s.cpuAvg,
                warnAt: 0.8,
                dangerAt: 0.95,
                height: 12,
              ),
            ),
            const SizedBox(width: 6),
            SizedBox(
              width: 52,
              child: Text(
                'AVG ${(s.cpuAvg * 100).toStringAsFixed(0).padLeft(3)}%',
                style: T.value,
                textAlign: TextAlign.right,
              ),
            ),
          ]),
          const SizedBox(height: 6),
          // Per-core
          ...s.cores.map((core) => Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(children: [
              SizedBox(
                width: 44,
                child: Text('C${core.index}'.padLeft(3), style: T.labelDim),
              ),
              Expanded(
                child: BarGauge(
                  value: core.usage,
                  warnAt: 0.80,
                  dangerAt: 0.95,
                  height: 8,
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 38,
                child: Text(
                  '${(core.usage * 100).toStringAsFixed(0).padLeft(3)}%',
                  style: T.labelDim,
                  textAlign: TextAlign.right,
                ),
              ),
            ]),
          )),
          const SizedBox(height: 4),
          if (s.cpuTempC > 0)
            Row(children: [
              const Text('TEMP  ', style: T.labelDim),
              Text(
                '${s.cpuTempC.toStringAsFixed(1)} °C',
                style: T.value.copyWith(
                  color: s.cpuTempC > 85 ? C.danger : s.cpuTempC > 70 ? C.warn : C.textHi,
                ),
              ),
            ]),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Memory panel
// ---------------------------------------------------------------------------

class _MemPanel extends StatelessWidget {
  const _MemPanel({required this.s});
  final SystemStats s;

  String _fmt(int mb) {
    if (mb > 1024) return '${(mb / 1024).toStringAsFixed(1)} GiB';
    return '$mb MiB';
  }

  @override
  Widget build(BuildContext context) {
    return Panel(
      title: 'MEMORY',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row('RAM ', s.memUsageFraction, '${_fmt(s.memUsedMb)} / ${_fmt(s.memTotalMb)}'),
          const SizedBox(height: 8),
          _row('SWAP', s.swapUsageFraction, '${_fmt(s.swapUsedMb)} / ${_fmt(s.swapTotalMb)}'),
        ],
      ),
    );
  }

  Widget _row(String label, double frac, String detail) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(children: [
        Text(label, style: T.label),
        const SizedBox(width: 6),
        Text(
          '${(frac * 100).toStringAsFixed(1)}%',
          style: T.value.copyWith(
            color: frac > 0.9 ? C.danger : frac > 0.75 ? C.warn : C.textHi,
          ),
        ),
      ]),
      const SizedBox(height: 3),
      BarGauge(value: frac, warnAt: 0.75, dangerAt: 0.90, height: 10),
      const SizedBox(height: 2),
      Text(detail, style: T.muted),
    ],
  );
}

// ---------------------------------------------------------------------------
// Network panel
// ---------------------------------------------------------------------------

class _NetPanel extends StatelessWidget {
  const _NetPanel({required this.s});
  final SystemStats s;

  @override
  Widget build(BuildContext context) {
    return Panel(
      title: 'NETWORK',
      child: s.network.isEmpty
          ? const Text('no interfaces', style: T.muted)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: s.network.map((iface) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(iface.name, style: T.label),
                    const SizedBox(height: 2),
                    Text(
                      '↑ ${iface.txMbps.toStringAsFixed(2)} MB/s',
                      style: T.labelDim,
                    ),
                    Text(
                      '↓ ${iface.rxMbps.toStringAsFixed(2)} MB/s',
                      style: T.labelDim,
                    ),
                  ],
                ),
              )).toList(),
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// MQTT status panel
// ---------------------------------------------------------------------------

class _MqttPanel extends StatelessWidget {
  const _MqttPanel({required this.mqtt});
  final MqttService mqtt;

  @override
  Widget build(BuildContext context) {
    final connected = mqtt.state == MqttState.connected;
    final uptime = mqtt.connectedSince != null
        ? _fmtDuration(DateTime.now().difference(mqtt.connectedSince!))
        : '--';

    return Panel(
      title: 'MQTT BROKER',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StatusDot(
            label: connected ? 'CONNECTED' : mqtt.state.name.toUpperCase(),
            ok: connected,
          ),
          const SizedBox(height: 6),
          _kv('Host',     '${mqtt.config.host}:${mqtt.config.port}'),
          _kv('Uptime',   uptime),
          _kv('Messages', '${mqtt.messageCount}'),
          _kv('Rate',     '${mqtt.messageRate} msg/s'),
          _kv('Topics',   '${mqtt.config.subscriptions.length} subscribed'),
          if (mqtt.lastError != null) ...[
            const SizedBox(height: 6),
            Text(
              mqtt.lastError!,
              style: T.muted.copyWith(color: C.danger),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
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

  String _fmtDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    return '${h.toString().padLeft(2, '0')}:'
           '${m.toString().padLeft(2, '0')}:'
           '${s.toString().padLeft(2, '0')}';
  }
}
