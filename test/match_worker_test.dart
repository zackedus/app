import 'package:flutter_test/flutter_test.dart';
import 'package:object_detection/src/match_worker.dart';

List<double> vector(List<double> embedding) =>
    [...List.filled(32, 0.1), ...List.filled(24, 0.0), ...embedding];

final helmet = vector([1, 0]);
final vest = vector([0, 1]);

ExampleSet examples() => {
      'helm': [
        [helmet],
        [helmet],
        [helmet],
      ],
      'rompi': [
        [vest],
        [vest],
        [vest],
      ],
    };

void main() {
  test('matchLabels picks the closest class and leaves unknown shapes', () {
    final labels = matchLabels(
      [helmet, vest, List.filled(56, 0.0)],
      [0.9, 0.3, 0.9],
      examples(),
    );
    expect(labels, ['helm', 'rompi', null]);
  });

  test('matchLabels returns nulls without examples', () {
    expect(matchLabels([helmet], [0.9], {}), [null]);
  });

  test('MatchWorker matches on a background isolate and follows updates', () async {
    final worker = MatchWorker();
    addTearDown(worker.dispose);

    expect(await worker.match([helmet], [0.9]), [null]);

    worker.setExamples(examples());
    expect(await worker.match([helmet, vest], [0.9, 0.9]), ['helm', 'rompi']);

    worker.setExamples({'rompi': examples()['rompi']!});
    expect(await worker.match([vest], [0.9]), ['rompi']);
    expect(await worker.match([helmet], [0.9]), [null]);
  });
}
