import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:object_detection/src/annotations.dart';
import 'package:object_detection/src/matching.dart';

void main() {
  group('parseAiBoxes', () {
    test('converts Gemini box_2d [ymin, xmin, ymax, xmax] on 0-1000', () {
      final boxes = parseAiBoxes(
        '[{"box_2d": [100, 200, 500, 800], "label": "helm proyek"}]',
      );
      expect(boxes, [const Rect.fromLTRB(0.2, 0.1, 0.8, 0.5)]);
    });

    test('strips a fenced code block', () {
      final boxes = parseAiBoxes(
        '```json\n[{"box_2d": [0, 0, 1000, 1000]}]\n```',
      );
      expect(boxes, [const Rect.fromLTRB(0, 0, 1, 1)]);
    });

    test('reads Qwen bbox_2d [x1, y1, x2, y2] on 0-1000', () {
      final boxes = parseAiBoxes('[{"bbox_2d": [200, 100, 800, 500]}]');
      expect(boxes, [const Rect.fromLTRB(0.2, 0.1, 0.8, 0.5)]);
    });

    test('keeps the old {"boxes": [[l, t, r, b]]} format on 0..1', () {
      final boxes = parseAiBoxes('{"boxes": [[0.2, 0.1, 0.8, 0.5]]}');
      expect(boxes, [const Rect.fromLTRB(0.2, 0.1, 0.8, 0.5)]);
    });

    test('orders swapped corners and skips invalid entries', () {
      final boxes = parseAiBoxes(
        '[{"box_2d": [500, 800, 100, 200]}, {"box_2d": [0, 0, 4000, 3000]}, '
        '{"box_2d": [1, 2, 3]}, {"label": "x"}]',
      );
      expect(boxes, [const Rect.fromLTRB(0.2, 0.1, 0.8, 0.5)]);
    });

    test('returns no boxes for an empty array', () {
      expect(parseAiBoxes('[]'), isEmpty);
    });

    test('rejects too many boxes and unexpected replies', () {
      final many = List.filled(51, '{"box_2d": [0, 0, 10, 10]}').join(',');
      expect(() => parseAiBoxes('[$many]'), throwsFormatException);
      expect(() => parseAiBoxes('{"answer": 1}'), throwsFormatException);
    });
  });

  test('completionText joins multi-part content', () {
    expect(
      completionText('{"choices":[{"message":{"content":[{"type":"text","text":"[]"}]}}]}'),
      '[]',
    );
    expect(completionText('{"choices":[{"message":{"content":"ok"}}]}'), 'ok');
  });

  test('parseBoxes rejects coordinates outside the photo', () {
    expect(parseBoxes('{"boxes": [[0.1, 0.2, 0.3, 0.4]]}'),
        [const Rect.fromLTRB(0.1, 0.2, 0.3, 0.4)]);
    expect(() => parseBoxes('{"boxes": [[0.1, 0.2, 1.3, 0.4]]}'),
        throwsFormatException);
  });

  test('yoloLabel writes class and centre-based boxes', () {
    expect(
      yoloLabel(2, [const Rect.fromLTRB(0.2, 0.1, 0.6, 0.5)]),
      '2 0.400000 0.300000 0.400000 0.400000\n',
    );
    expect(yoloLabel(0, []), '');
    expect(yoloDataYaml(['helm proyek', 'rompi']),
        'path: .\ntrain: images\nval: images\nnames:\n'
        '  0: "helm proyek"\n  1: "rompi"\n');
  });

  group('appearanceDistance', () {
    List<double> vector({required double edge, List<double> embedding = const []}) =>
        [...List.filled(32, edge), ...List.filled(24, 0.0), ...embedding];

    test('is zero for identical vectors with embeddings', () {
      final a = vector(edge: 0.1, embedding: [1, 0]);
      expect(appearanceDistance(a, a), closeTo(0, 1e-12));
    });

    test('uses cosine distance for embeddings', () {
      final a = vector(edge: 0.1, embedding: [1, 0]);
      final b = vector(edge: 0.1, embedding: [-1, 0]);
      expect(appearanceDistance(a, b), closeTo(0.8, 1e-12));
    });

    test('cannot compare vectors of different lengths', () {
      expect(appearanceDistance(vector(edge: 0.1), vector(edge: 0.1, embedding: [1])),
          isNull);
    });

    test('distancesByClass keeps the nearest box per photo', () {
      final query = vector(edge: 0.1, embedding: [1, 0]);
      final result = distancesByClass(query, {
        'helm': [
          [vector(edge: 0.1, embedding: [-1, 0]), query],
        ],
      });
      expect(result['helm']!.single, closeTo(0, 1e-12));
    });
  });

  test('FailureGate stops only after repeated failures', () {
    final gate = FailureGate(limit: 3);
    expect(gate.fail(), isFalse);
    expect(gate.fail(), isFalse);
    gate.succeed();
    expect(gate.fail(), isFalse);
    expect(gate.fail(), isFalse);
    expect(gate.fail(), isTrue);
  });
}
