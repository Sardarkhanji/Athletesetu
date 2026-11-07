# On-device models

| File | Model | Input | Output |
|------|-------|-------|--------|
| `movenet_lightning_int8.tflite` (bundled) | MoveNet SinglePose Lightning (INT8, from TF Hub, Apache-2.0) | uint8 `[1,192,192,3]` | float32 `[1,1,17,3]` (y, x, score) |

`movenet_thunder_int8.tflite` (256×256) also works. The isolate reads the input shape from the interpreter when it loads.

Weight-scale OCR needs no model: `assisted_ocr_engine.dart` runs a seven-segment decoder written in pure Dart.

If the model file is missing, the camera workbench forces **Demo Simulation Mode**, so all 10 SAI tests can still be run end-to-end.
