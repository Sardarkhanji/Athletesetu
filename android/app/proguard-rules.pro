# AthleteSetu R8 keep rules for libraries reached from native code / reflection.

# SQLCipher (sqflite_sqlcipher): JNI calls back into these classes.
-keep class net.zetetic.** { *; }
-keep class net.sqlcipher.** { *; }
-dontwarn net.sqlcipher.**

# TensorFlow Lite (tflite_flutter uses the C API via FFI; keep JNI/NNAPI glue).
-keep class org.tensorflow.** { *; }
-dontwarn org.tensorflow.**

# CameraX (camera_android_camerax) uses reflection for quirks/extensions.
-keep class androidx.camera.** { *; }
-dontwarn androidx.camera.**

# Flutter plugin registrant + play core references emitted by the engine.
-keep class io.flutter.plugins.GeneratedPluginRegistrant { *; }
-dontwarn com.google.android.play.core.**
