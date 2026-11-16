import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'theme.dart';

/// A 270° arc gauge with the value in the centre.
class RadialGauge extends StatelessWidget {
  const RadialGauge({
    super.key,
    required this.label,
    required this.valueText,
    required this.unit,
    required this.fraction,
    this.color = kAccent,
  });

  final String label;
  final String valueText;
  final String unit;

  /// Needle position from 0 to 1.
  final double fraction;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = math.min(constraints.maxWidth, constraints.maxHeight);
        return Center(
          child: SizedBox(
            width: size,
            height: size,
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(end: fraction.clamp(0.0, 1.0)),
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              builder: (context, animated, child) => CustomPaint(painter: _GaugePainter(animated, color), child: child),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(height: size * 0.06),
                  FittedBox(
                    child: Text(
                      valueText,
                      style: TextStyle(
                        fontSize: size * 0.24,
                        fontWeight: FontWeight.w700,
                        height: 1,
                        fontFeatures: kTabularFigures,
                        color: kText,
                      ),
                    ),
                  ),
                  SizedBox(height: size * 0.02),
                  Text(
                    unit,
                    style: TextStyle(fontSize: size * 0.085, color: kMuted, height: 1.1),
                  ),
                  SizedBox(height: size * 0.10),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: size * 0.2),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: size * 0.085, fontWeight: FontWeight.w600, color: kText, height: 1.1),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _GaugePainter extends CustomPainter {
  _GaugePainter(this.fraction, this.color);

  final double fraction;
  final Color color;

  static const double _start = math.pi * 0.75;
  static const double _sweep = math.pi * 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.shortestSide * 0.075;
    final rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: size.shortestSide / 2 - stroke / 2 - size.shortestSide * 0.04,
    );
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = kSurfaceHigh;
    canvas.drawArc(rect, _start, _sweep, false, track);

    if (fraction <= 0) return;
    final progress = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        startAngle: 0,
        endAngle: _sweep,
        colors: [color.withValues(alpha: 0.55), color],
        transform: const GradientRotation(_start),
      ).createShader(rect);
    canvas.drawArc(rect, _start, _sweep * fraction, false, progress);

    // A bright dot marks the current position.
    final angle = _start + _sweep * fraction;
    final tip = rect.center + Offset(math.cos(angle), math.sin(angle)) * (rect.width / 2);
    canvas.drawCircle(tip, stroke * 0.34, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_GaugePainter old) => old.fraction != fraction || old.color != color;
}

/// A tiny trend line for the live data list.
class Sparkline extends StatelessWidget {
  const Sparkline(this.values, {super.key, this.color = kAccent});

  final List<double> values;
  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _SparklinePainter(List.of(values), color));
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter(this.values, this.color);

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    var low = values.first;
    var high = values.first;
    for (final value in values) {
      low = math.min(low, value);
      high = math.max(high, value);
    }
    final span = high - low;
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = size.width * i / (values.length - 1);
      final normalised = span == 0 ? 0.5 : (values[i] - low) / span;
      final y = size.height - 2 - normalised * (size.height - 4);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_SparklinePainter old) => true;
}
