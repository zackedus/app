import 'dart:convert';
import 'dart:ui';

/// Parses an annotation stored on the phone: `{"boxes": [[left, top, right, bottom]]}`
/// with coordinates relative to the photo (0..1).
List<Rect> parseBoxes(String json) {
  final rows = (jsonDecode(json) as Map<String, dynamic>)['boxes'] as List;
  return rows.map<Rect>((row) {
    if (row is! List ||
        row.length != 4 ||
        row.any((v) => v is! num || !v.isFinite || v < 0 || v > 1)) {
      throw const FormatException('Invalid coordinates');
    }
    final values = row.cast<num>().map((v) => v.toDouble()).toList();
    final box = Rect.fromLTRB(values[0], values[1], values[2], values[3]);
    if (box.isEmpty) throw const FormatException('Empty box');
    return box;
  }).toList();
}

/// Prompt that follows Gemini's native detection format.
String aiBoxPrompt(String label) =>
    'Detect every visible instance of the object class "$label". '
    'A face is a generic class. Never identify a person. '
    'Return only a JSON array such as '
    '[{"box_2d": [ymin, xmin, ymax, xmax], "label": "$label"}] '
    'with coordinates normalized to 0-1000 relative to the full image. '
    'Use tight boxes around each instance. If none is visible, return [].';

/// Parses a vision-model reply into boxes relative to the photo (0..1).
///
/// Supports Gemini `box_2d` ([ymin, xmin, ymax, xmax], 0-1000), Qwen `bbox_2d`
/// ([x1, y1, x2, y2], 0-1000) and the older `{"boxes": [[l, t, r, b]]}` (0..1).
/// Invalid entries are skipped so one bad box does not discard the others.
List<Rect> parseAiBoxes(String reply, {int maximum = 50}) {
  final text = reply
      .trim()
      .replaceFirst(RegExp(r'^\s*```(?:json)?\s*'), '')
      .replaceFirst(RegExp(r'\s*```\s*$'), '');
  final decoded = jsonDecode(text);
  final List<Object?> rows;
  var legacy = false;
  if (decoded is List) {
    rows = decoded;
  } else if (decoded is Map && decoded['boxes'] is List) {
    rows = decoded['boxes'] as List;
    legacy = true;
  } else {
    throw const FormatException('Unexpected reply');
  }
  if (rows.length > maximum) throw const FormatException('Too many boxes');

  final boxes = <Rect>[];
  for (final row in rows) {
    List<double>? values;
    var yFirst = false;
    var scale = 1000.0;
    if (legacy && row is List) {
      values = _numbers(row);
      scale = 1;
    } else if (row is Map && row['box_2d'] is List) {
      values = _numbers(row['box_2d'] as List);
      yFirst = true;
    } else if (row is Map && row['bbox_2d'] is List) {
      values = _numbers(row['bbox_2d'] as List);
    } else if (row is List) {
      values = _numbers(row);
      yFirst = true;
    }
    if (values == null) continue;
    // Allow a small overshoot from the model, but reject pixel coordinates.
    if (values.any((v) => v < -0.01 * scale || v > 1.01 * scale)) continue;
    final n = values.map((v) => (v / scale).clamp(0.0, 1.0).toDouble()).toList();
    final box = yFirst
        ? Rect.fromPoints(Offset(n[1], n[0]), Offset(n[3], n[2]))
        : Rect.fromPoints(Offset(n[0], n[1]), Offset(n[2], n[3]));
    if (box.width >= 0.002 && box.height >= 0.002) boxes.add(box);
  }
  return boxes;
}

List<double>? _numbers(List<Object?> row) {
  if (row.length != 4 || row.any((v) => v is! num || !v.isFinite)) return null;
  return row.cast<num>().map((v) => v.toDouble()).toList();
}

/// Reads the text of an OpenRouter chat completion, including multi-part content.
String completionText(String body) {
  final envelope = jsonDecode(body) as Map<String, dynamic>;
  final choices = envelope['choices'] as List<dynamic>;
  final content = (choices.first as Map)['message']['content'];
  if (content is String) return content;
  if (content is List) {
    return content
        .whereType<Map>()
        .map((part) => part['text'])
        .whereType<String>()
        .join();
  }
  throw const FormatException('Empty reply');
}

/// YOLO label lines: `class cx cy w h`, all relative to the image.
String yoloLabel(int classIndex, List<Rect> boxes) => boxes
    .map((b) => [
          classIndex,
          b.center.dx.toStringAsFixed(6),
          b.center.dy.toStringAsFixed(6),
          b.width.toStringAsFixed(6),
          b.height.toStringAsFixed(6),
        ].join(' '))
    .map((line) => '$line\n')
    .join();

/// Ultralytics-style dataset description for the exported ZIP.
String yoloDataYaml(List<String> classes) {
  final buffer = StringBuffer()
    ..writeln('path: .')
    ..writeln('train: images')
    ..writeln('val: images')
    ..writeln('names:');
  for (var i = 0; i < classes.length; i++) {
    buffer.writeln('  $i: ${jsonEncode(classes[i])}');
  }
  return buffer.toString();
}
