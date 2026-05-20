import 'package:flutter/material.dart';
import '../theme.dart';

// ---------------------------------------------------------------------------
// Panel — a bordered box with an optional title in the top-left
// ---------------------------------------------------------------------------

class Panel extends StatelessWidget {
  const Panel({
    super.key,
    required this.child,
    this.title,
    this.selected = false,
    this.padding = const EdgeInsets.all(8),
  });

  final Widget child;
  final String? title;
  final bool selected;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final borderColor = selected ? C.borderHi : C.border;
    return Container(
      decoration: BoxDecoration(
        color: C.bgPanel,
        border: Border.all(color: borderColor, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null)
            Container(
              width: double.infinity,
              color: C.bgHeader,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              child: Text(
                ' ${title!} ',
                style: T.header,
              ),
            ),
          Padding(padding: padding, child: child),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// BarGauge — horizontal bar with fill colour driven by value
// ---------------------------------------------------------------------------

class BarGauge extends StatelessWidget {
  const BarGauge({
    super.key,
    required this.value,  // 0.0 – 1.0
    this.warnAt = 0.75,
    this.dangerAt = 0.90,
    this.height = 10,
    this.label,
  });

  final double value;
  final double warnAt;
  final double dangerAt;
  final double height;
  final String? label;

  Color get _fillColor {
    if (value >= dangerAt) return C.barDanger;
    if (value >= warnAt)   return C.barWarn;
    if (value >= 0.4)      return C.barHi;
    if (value >= 0.2)      return C.barMid;
    return C.barLow;
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Container(
            height: height,
            color: C.barBg,
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: value.clamp(0.0, 1.0),
              child: Container(color: _fillColor),
            ),
          ),
        ),
        if (label != null) ...[
          const SizedBox(width: 6),
          SizedBox(
            width: 42,
            child: Text(label!, style: T.value, textAlign: TextAlign.right),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// RangeBar — bar that visualises a value relative to an [optLow, optHigh]
// range, showing green when inside and amber/red outside.
// ---------------------------------------------------------------------------

class RangeBar extends StatelessWidget {
  const RangeBar({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.optLow,
    required this.optHigh,
    this.height = 10,
  });

  final double value;
  final double min;
  final double max;
  final double optLow;
  final double optHigh;
  final double height;

  double get _fraction => ((value - min) / (max - min)).clamp(0.0, 1.0);

  Color get _color {
    if (value < optLow || value > optHigh) {
      final distLow  = (value - optLow).abs();
      final distHigh = (value - optHigh).abs();
      final span = optHigh - optLow;
      if (distLow > span || distHigh > span) return C.barDanger;
      return C.barWarn;
    }
    return C.barHi;
  }

  @override
  Widget build(BuildContext context) => Container(
    height: height,
    color: C.barBg,
    child: FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: _fraction,
      child: Container(color: _color),
    ),
  );
}

// ---------------------------------------------------------------------------
// StatusDot — a coloured dot + label
// ---------------------------------------------------------------------------

class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.label, required this.ok, this.style});
  final String label;
  final bool ok;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text('● ', style: TextStyle(color: ok ? C.good : C.danger, fontFamily: 'monospace', fontSize: 12)),
      Text(label, style: style ?? T.label),
    ],
  );
}

// ---------------------------------------------------------------------------
// KeyHint — bottom-of-screen key binding hints
// ---------------------------------------------------------------------------

class KeyHint extends StatelessWidget {
  const KeyHint(this.key_, this.label, {super.key});
  final String key_;
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 14),
    child: RichText(
      text: TextSpan(
        children: [
          TextSpan(
            text: '[$key_]',
            style: T.label.copyWith(color: C.accent),
          ),
          TextSpan(
            text: ' $label',
            style: T.labelDim,
          ),
        ],
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// SectionDivider
// ---------------------------------------------------------------------------

class SectionDivider extends StatelessWidget {
  const SectionDivider({super.key});
  @override
  Widget build(BuildContext context) =>
      Divider(height: 1, thickness: 1, color: C.border);
}
