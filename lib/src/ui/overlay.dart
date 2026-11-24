part of '../../main.dart';

class _Detection {
  const _Detection(this.box, this.label, this.score, this.appearance, {this.local = false});

  factory _Detection.fromMap(Map<Object?, Object?> map) {
    double number(String key) => (map[key] as num).toDouble();
    return _Detection(
      Rect.fromLTRB(
        number('left'),
        number('top'),
        number('right'),
        number('bottom'),
      ),
      map['label'] as String,
      number('score'),
      ((map['appearance'] as List?) ?? const [])
          .cast<num>()
          .map((value) => value.toDouble())
          .toList(),
    );
  }

  _Detection asLocal(String exampleLabel) =>
      _Detection(box, exampleLabel, score, appearance, local: true);

  final Rect box;
  final String label;
  final double score;
  final List<double> appearance;
  final bool local;
}

class _Overlay extends CustomPainter {
  const _Overlay(this.detections, {this.focus = false});

  final bool focus;

  final List<_Detection> detections;
  static const _accent = Color(0xff79ebbb);

  @override
  void paint(Canvas canvas, Size size) {
    if (focus && detections.isEmpty) {
      canvas.drawRect(
        Rect.fromLTRB(size.width * .2, size.height * .3, size.width * .8, size.height * .7),
        Paint()
          ..color = Colors.white70
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    if (size.isEmpty) return;
    final border = Paint()
      ..color = _accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final fill = Paint()..color = _accent;
    for (final detection in detections) {
      final box = detection.box;
      final rect = Rect.fromLTRB(
        box.left * size.width,
        box.top * size.height,
        box.right * size.width,
        box.bottom * size.height,
      ).intersect(Offset.zero & size);
      if (rect.isEmpty) continue;
      canvas.drawRect(rect, border);
      final label = cocoLabelsId[detection.label] ?? detection.label;
      final text = TextPainter(
        text: TextSpan(
          text: detection.local ? '$label · contoh' : '$label ${(100 * detection.score).round()}%',
          style: const TextStyle(color: Colors.black, fontSize: 13),
        ),
        maxLines: 1,
        ellipsis: '…',
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: (size.width - 8).clamp(0.0, size.width).toDouble());
      final tagWidth = text.width + 8;
      final x = rect.left
          .clamp(0.0, (size.width - tagWidth).clamp(0.0, size.width))
          .toDouble();
      final y = (rect.top - text.height - 4).clamp(0.0, size.height).toDouble();
      canvas.drawRect(Rect.fromLTWH(x, y, tagWidth, text.height + 4), fill);
      text.paint(canvas, Offset(x + 4, y + 2));
      text.dispose();
    }
  }

  @override
  bool shouldRepaint(_Overlay oldDelegate) =>
      detections != oldDelegate.detections || focus != oldDelegate.focus;
}
