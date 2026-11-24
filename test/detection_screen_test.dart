import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:object_detection/main.dart';
import 'package:object_detection/src/matching.dart';

void main() {
  test('accepts a class supported by distinct photos', () {
    expect(selectLocalObjectLabel({
      'toples': [0.08, 0.12, 0.18],
      'gelas': [0.29, 0.32, 0.38],
    }, maximumDistance: 0.19), 'toples');
  });

  test('rejects a class supported only by a single close photo', () {
    expect(selectLocalObjectLabel({
      'toples': [0.01, 0.21, 0.22],
    }, maximumDistance: 0.19), isNull);
  });

  test('rejects close competing classes even if both pass the threshold', () {
    expect(selectLocalObjectLabel({
      'toples': [0.10, 0.11, 0.12],
      'gelas': [0.11, 0.12, 0.13],
    }, maximumDistance: 0.19), isNull);
  });

  testWidgets('shows an error and can retry when no rear camera is found', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: DetectionScreen(
          listCameras: () async {
            attempts++;
            return [];
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Kamera belakang tidak tersedia'),
      findsOneWidget,
    );
    expect(attempts, 1);

    await tester.tap(find.text('Coba lagi'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
  });

  testWidgets('shows Android settings guidance when camera access is denied', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DetectionScreen(
          listCameras: () async {
            throw CameraException('CameraAccessDenied', 'Denied');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Izinkan akses kamera'), findsOneWidget);
    expect(find.text('Coba lagi'), findsOneWidget);
  });
}
