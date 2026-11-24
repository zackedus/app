import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:object_detection/main.dart';

void main() {
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
