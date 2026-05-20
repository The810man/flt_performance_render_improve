import 'dart:async';
import 'dart:io';

class CpuCore {
  final int index;
  final double usage; // 0.0–1.0
  const CpuCore(this.index, this.usage);
}

class NetworkIface {
  final String name;
  final double rxMbps;
  final double txMbps;
  const NetworkIface(this.name, this.rxMbps, this.txMbps);
}

class SystemStats {
  final List<CpuCore> cores;
  final double cpuTempC;
  final int memTotalMb;
  final int memUsedMb;
  final int swapTotalMb;
  final int swapUsedMb;
  final List<NetworkIface> network;
  final DateTime timestamp;

  const SystemStats({
    required this.cores,
    required this.cpuTempC,
    required this.memTotalMb,
    required this.memUsedMb,
    required this.swapTotalMb,
    required this.swapUsedMb,
    required this.network,
    required this.timestamp,
  });

  double get memUsageFraction =>
      memTotalMb > 0 ? memUsedMb / memTotalMb : 0;
  double get swapUsageFraction =>
      swapTotalMb > 0 ? swapUsedMb / swapTotalMb : 0;
  double get cpuAvg =>
      cores.isEmpty ? 0 : cores.map((c) => c.usage).reduce((a, b) => a + b) / cores.length;

  static SystemStats empty() => SystemStats(
    cores: [],
    cpuTempC: 0,
    memTotalMb: 0,
    memUsedMb: 0,
    swapTotalMb: 0,
    swapUsedMb: 0,
    network: [],
    timestamp: DateTime.now(),
  );
}

// --------------------------------------------------------------------------

class SystemService {
  SystemStats _stats = SystemStats.empty();
  SystemStats get stats => _stats;

  VoidCallback? onUpdate;

  Timer? _timer;

  // Previous /proc/stat snapshots for delta calculation.
  List<_CpuRaw>? _prevCpu;
  Map<String, _NetRaw>? _prevNet;
  DateTime? _prevTime;

  void start() {
    _poll();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
  }

  void stop() => _timer?.cancel();

  Future<void> _poll() async {
    try {
      final cores  = await _readCpu();
      final mem    = await _readMem();
      final temp   = await _readTemp();
      final net    = await _readNet();

      _stats = SystemStats(
        cores: cores,
        cpuTempC: temp,
        memTotalMb: mem['total']!,
        memUsedMb: mem['used']!,
        swapTotalMb: mem['swapTotal']!,
        swapUsedMb: mem['swapUsed']!,
        network: net,
        timestamp: DateTime.now(),
      );
      onUpdate?.call();
    } catch (_) {
      // Keep last known stats on error.
    }
  }

  // ---- CPU ------------------------------------------------------------------

  Future<List<CpuCore>> _readCpu() async {
    final lines = await File('/proc/stat').readAsLines();
    final raws  = <_CpuRaw>[];

    for (final line in lines) {
      if (!line.startsWith('cpu')) break;
      final parts = line.split(RegExp(r'\s+'));
      if (parts[0] == 'cpu') continue; // skip aggregate line
      final vals = parts.skip(1).map(int.parse).toList();
      raws.add(_CpuRaw(
        idle:  vals[3] + (vals.length > 4 ? vals[4] : 0),
        total: vals.fold(0, (a, b) => a + b),
      ));
    }

    final prev = _prevCpu;
    _prevCpu = raws;

    if (prev == null || prev.length != raws.length) {
      return List.generate(raws.length, (i) => CpuCore(i, 0));
    }

    return List.generate(raws.length, (i) {
      final dtotal = raws[i].total - prev[i].total;
      final didle  = raws[i].idle  - prev[i].idle;
      final usage  = dtotal > 0 ? (1 - didle / dtotal).clamp(0.0, 1.0) : 0.0;
      return CpuCore(i, usage);
    });
  }

  // ---- Memory ---------------------------------------------------------------

  Future<Map<String, int>> _readMem() async {
    final lines = await File('/proc/meminfo').readAsLines();
    final vals  = <String, int>{};
    for (final line in lines) {
      final m = RegExp(r'^(\w+):\s+(\d+)').firstMatch(line);
      if (m != null) vals[m.group(1)!] = int.parse(m.group(2)!);
    }
    final total = (vals['MemTotal'] ?? 0) ~/ 1024;
    final avail = (vals['MemAvailable'] ?? 0) ~/ 1024;
    return {
      'total':     total,
      'used':      total - avail,
      'swapTotal': (vals['SwapTotal'] ?? 0) ~/ 1024,
      'swapUsed':  ((vals['SwapTotal'] ?? 0) - (vals['SwapFree'] ?? 0)) ~/ 1024,
    };
  }

  // ---- Temperature ----------------------------------------------------------

  Future<double> _readTemp() async {
    try {
      // Try hwmon first (more reliable on many systems).
      final hwmon = Directory('/sys/class/hwmon');
      if (hwmon.existsSync()) {
        for (final entry in hwmon.listSync()) {
          final nameFile = File('${entry.path}/name');
          if (!nameFile.existsSync()) continue;
          final name = nameFile.readAsStringSync().trim();
          if (name.contains('coretemp') || name.contains('k10temp') || name.contains('cpu')) {
            final tempFile = File('${entry.path}/temp1_input');
            if (tempFile.existsSync()) {
              return int.parse(tempFile.readAsStringSync().trim()) / 1000.0;
            }
          }
        }
      }
      // Fallback: thermal_zone0.
      final t = await File('/sys/class/thermal/thermal_zone0/temp').readAsString();
      return int.parse(t.trim()) / 1000.0;
    } catch (_) {
      return 0;
    }
  }

  // ---- Network --------------------------------------------------------------

  Future<List<NetworkIface>> _readNet() async {
    final now   = DateTime.now();
    final lines = await File('/proc/net/dev').readAsLines();
    final curr  = <String, _NetRaw>{};

    for (final line in lines.skip(2)) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 10) continue;
      final name = parts[0].replaceAll(':', '');
      if (name == 'lo') continue;
      curr[name] = _NetRaw(rx: int.parse(parts[1]), tx: int.parse(parts[9]));
    }

    final prev    = _prevNet;
    final prevT   = _prevTime;
    _prevNet  = curr;
    _prevTime = now;

    if (prev == null || prevT == null) {
      return curr.keys.map((n) => NetworkIface(n, 0, 0)).toList();
    }

    final dt = now.difference(prevT).inMilliseconds / 1000.0;
    return curr.entries.map((e) {
      final p = prev[e.key];
      if (p == null || dt <= 0) return NetworkIface(e.key, 0, 0);
      final rx = (e.value.rx - p.rx) / 1024 / 1024 / dt;
      final tx = (e.value.tx - p.tx) / 1024 / 1024 / dt;
      return NetworkIface(e.key, rx.clamp(0, double.infinity), tx.clamp(0, double.infinity));
    }).toList();
  }
}

class _CpuRaw { final int idle, total; _CpuRaw({required this.idle, required this.total}); }
class _NetRaw  { final int rx, tx;     _NetRaw({required this.rx, required this.tx}); }

typedef VoidCallback = void Function();
