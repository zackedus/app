import 'dart:async';
import 'dart:isolate';

import 'matching.dart';

/// Photos per class, boxes per photo, appearance vector per box.
typedef ExampleSet = Map<String, List<List<List<double>>>>;

/// Labels each detection with a local example class, or null when none fits.
List<String?> matchLabels(
  List<List<double>> appearances,
  List<double> scores,
  ExampleSet examples,
) => [
  for (var i = 0; i < appearances.length; i++)
    examples.isEmpty || !hasShape(appearances[i])
        ? null
        : selectLocalObjectLabel(
            distancesByClass(appearances[i], examples),
            maximumDistance: scores[i] < 0.5 ? 0.19 : 0.25,
          ),
];

/// Runs [matchLabels] on a long-lived background isolate so that comparing
/// detections with many example photos does not block the UI thread.
///
/// The examples are copied to the isolate once per change, not per frame.
/// If the isolate cannot start, matching falls back to the calling isolate.
class MatchWorker {
  ExampleSet _examples = const {};
  Future<SendPort>? _port;
  Isolate? _isolate;
  ReceivePort? _replies;
  final _pending = <int, Completer<List<String?>>>{};
  int _nextId = 0;
  bool _unavailable = false;
  bool _disposed = false;

  bool get hasExamples => _examples.isNotEmpty;

  void setExamples(ExampleSet examples) {
    _examples = examples;
    _port?.then((port) => port.send(examples), onError: (_) {});
  }

  Future<List<String?>> match(List<List<double>> appearances, List<double> scores) async {
    if (_examples.isEmpty || appearances.isEmpty) {
      return List<String?>.filled(appearances.length, null);
    }
    if (_unavailable || _disposed) return matchLabels(appearances, scores, _examples);
    final SendPort port;
    try {
      port = await (_port ??= _start());
    } catch (_) {
      _unavailable = true;
      return matchLabels(appearances, scores, _examples);
    }
    if (_disposed) return List<String?>.filled(appearances.length, null);
    final id = _nextId++;
    final reply = Completer<List<String?>>();
    _pending[id] = reply;
    port.send((id, appearances, scores));
    return reply.future;
  }

  Future<SendPort> _start() async {
    final replies = ReceivePort();
    _replies = replies;
    final ready = Completer<SendPort>();
    replies.listen((message) {
      switch (message) {
        case SendPort port:
          ready.complete(port);
        case (int id, List<String?> labels):
          _pending.remove(id)?.complete(labels);
      }
    });
    _isolate = await Isolate.spawn(_run, replies.sendPort, debugName: 'example-matcher');
    final port = await ready.future;
    // Sent after the port exists, so later setExamples calls stay in order.
    port.send(_examples);
    return port;
  }

  void dispose() {
    _disposed = true;
    _isolate?.kill(priority: Isolate.immediate);
    _replies?.close();
    for (final reply in _pending.values) {
      reply.complete(const []);
    }
    _pending.clear();
  }

  static void _run(SendPort replies) {
    final requests = ReceivePort();
    replies.send(requests.sendPort);
    ExampleSet examples = const {};
    requests.listen((message) {
      switch (message) {
        case ExampleSet next:
          examples = next;
        case (int id, List<List<double>> appearances, List<double> scores):
          replies.send((id, matchLabels(appearances, scores, examples)));
      }
    });
  }
}
