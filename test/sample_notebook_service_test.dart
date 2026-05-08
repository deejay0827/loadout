// FILE: test/sample_notebook_service_test.dart
//
// Smoke test for `lib/services/sample_notebook_service.dart`. Exercises
// `buildPdfBytes()` to make sure the PDF generator doesn't throw and
// produces a non-trivial byte string. We don't validate the rendered
// page itself (would require a PDF parser); we just want a regression
// canary for "did I break the layout enough to crash the renderer."

import 'package:flutter_test/flutter_test.dart';
import 'package:loadout/services/sample_notebook_service.dart';

void main() {
  group('SampleNotebookService', () {
    test('buildPdfBytes produces a non-empty PDF', () async {
      const service = SampleNotebookService();
      final bytes = await service.buildPdfBytes();
      // Header check — a PDF file always starts with %PDF.
      expect(bytes.length, greaterThan(1024));
      final header = String.fromCharCodes(bytes.sublist(0, 4));
      expect(header, '%PDF');
    });
  });
}
