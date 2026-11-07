import 'package:flutter/services.dart';

/// Short countdown tones ("3-2-1-Go") for timed tests.
///
/// Android plays a native ToneGenerator tone (MainActivity, channel
/// `athletesetu/beep`). Elsewhere, or if the tone fails, it falls back to the
/// system click plus a vibration, so the countdown never blocks the test.
abstract final class Beep {
  static const _channel = MethodChannel('athletesetu/beep');

  /// One countdown tick (3, 2, 1).
  static Future<void> tick() => _play('tick');

  /// The longer "Go" tone.
  static Future<void> go() => _play('go');

  static Future<void> _play(String kind) async {
    try {
      await _channel.invokeMethod<bool>('tone', {'kind': kind});
    } catch (_) {
      // MissingPluginException (iOS, tests) or PlatformException (tone failed).
      await SystemSound.play(SystemSoundType.click);
      await (kind == 'go' ? HapticFeedback.heavyImpact() : HapticFeedback.selectionClick());
    }
  }
}
