package com.athletesetu.athlete_setu

import android.media.AudioManager
import android.media.ToneGenerator
import android.os.StatFs
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // Created lazily; ToneGenerator can fail on some devices, so every use is guarded.
    private var toneGenerator: ToneGenerator? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "athletesetu/storage")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "freeBytes" -> {
                        try {
                            val stat = StatFs(filesDir.absolutePath)
                            result.success(stat.availableBytes)
                        } catch (e: Exception) {
                            result.error("STATFS_FAILED", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // Countdown beeps for timed tests (sit-ups "3-2-1-Go"). Plays offline, no audio files.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "athletesetu/beep")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "tone" -> {
                        try {
                            val gen = toneGenerator
                                ?: ToneGenerator(AudioManager.STREAM_MUSIC, ToneGenerator.MAX_VOLUME)
                                    .also { toneGenerator = it }
                            val isGo = call.argument<String>("kind") == "go"
                            val tone = if (isGo) ToneGenerator.TONE_CDMA_HIGH_L else ToneGenerator.TONE_PROP_BEEP
                            val durationMs = if (isGo) 600 else 150
                            gen.startTone(tone, durationMs)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("TONE_FAILED", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        toneGenerator?.release()
        toneGenerator = null
        super.onDestroy()
    }
}
