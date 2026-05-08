// Drift web worker entry point. Compiled to `drift_worker.dart.js` and
// loaded by `drift_flutter`'s WebDatabase setup. Don't import anything
// here that pulls in the full app — keep it minimal so the dart2js
// payload stays tiny.
import 'package:drift/wasm.dart';

void main() {
  WasmDatabase.workerMainForOpen();
}
