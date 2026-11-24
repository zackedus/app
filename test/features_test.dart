import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:object_detection/src/detection_settings.dart';
import 'package:object_detection/src/tracker.dart';

void main() {
  group('DetectionSettings', () {
    test('round-trips through JSON', () {
      const settings = DetectionSettings(
        minScore: 0.35,
        hiddenLabels: {'cup', 'person'},
        maxFps: 10,
        includeLocation: false,
      );
      expect(DetectionSettings.fromJson(settings.toJson()), settings);
    });

    test('falls back to safe defaults for bad input', () {
      final settings = DetectionSettings.fromJson({
        'minScore': 5,
        'maxFps': 7,
        'hiddenLabels': ['cup', 3],
        'includeLocation': 'yes',
      });
      expect(settings.minScore, 0.9);
      expect(settings.maxFps, 0);
      expect(settings.hiddenLabels, {'cup'});
      expect(settings.includeLocation, isTrue);
      expect(DetectionSettings.fromJson('rusak'), const DetectionSettings());
    });

    test('filters labels and limits frame rate', () {
      const settings = DetectionSettings(hiddenLabels: {'cup'}, maxFps: 10);
      expect(settings.shows('cup'), isFalse);
      expect(settings.shows('person'), isTrue);
      expect(settings.minFrameGap, const Duration(milliseconds: 100));
      expect(const DetectionSettings().minFrameGap, isNull);
    });

    test('formats timestamps for photo captions', () {
      expect(formatTimestamp(DateTime(2026, 11, 5, 7, 3, 9)), '05-11-2026 07:03:09');
    });
  });

  group('ObjectTracker', () {
    const a = Rect.fromLTRB(0.1, 0.1, 0.3, 0.3);
    const aMoved = Rect.fromLTRB(0.12, 0.1, 0.32, 0.3);
    const b = Rect.fromLTRB(0.6, 0.6, 0.8, 0.8);

    test('iou is 1 for equal boxes and 0 for disjoint ones', () {
      expect(iou(a, a), closeTo(1, 1e-9));
      expect(iou(a, b), 0);
    });

    test('confirms an object after three frames and counts it once', () {
      final tracker = ObjectTracker();
      expect(tracker.update([('person', a)]), [null]);
      expect(tracker.update([('person', aMoved)]), [null]);
      final ids = tracker.update([('person', a)]);
      expect(ids.single, isNotNull);
      expect(tracker.update([('person', aMoved)]), ids);
      expect(tracker.totals, {'person': 1});
      expect(tracker.visible, {'person': 1});
    });

    test('keeps the id through a short dropout and counts new objects', () {
      final tracker = ObjectTracker();
      for (var i = 0; i < 3; i++) {
        tracker.update([('person', a)]);
      }
      final id = tracker.update([('person', a)]).single;
      tracker.update([]);
      tracker.update([]);
      expect(tracker.visible, isEmpty);
      expect(tracker.update([('person', a)]).single, id);

      for (var i = 0; i < 3; i++) {
        tracker.update([('person', a), ('helm', b)]);
      }
      expect(tracker.totals, {'person': 1, 'helm': 1});
    });

    test('does not match different labels and forgets lost tracks', () {
      final tracker = ObjectTracker(maxMissed: 1);
      for (var i = 0; i < 3; i++) {
        tracker.update([('person', a)]);
      }
      for (var i = 0; i < 3; i++) {
        tracker.update([('helm', a)]);
      }
      expect(tracker.totals, {'person': 1, 'helm': 1});
      tracker.reset();
      expect(tracker.totals, isEmpty);
    });
  });
}
