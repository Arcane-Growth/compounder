import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// A rest-timer cue.
enum RestCue {
  /// Five seconds of rest left: one short, quiet warning tick.
  fiveSeconds('sounds/rest_tick.wav'),

  /// Rest over: a rising two-note "go" tone, clearly brighter than the tick.
  go('sounds/rest_go.wav');

  const RestCue(this.asset);

  /// Path under the asset bundle (audioplayers prefixes `assets/`).
  final String asset;
}

/// Plays rest-timer cues.
///
/// Abstract so widget tests can inject a fake and assert which cues fired
/// without touching audio hardware.
abstract class RestSounds {
  Future<void> play(RestCue cue);

  Future<void> dispose();
}

/// Real implementation backed by audioplayers.
///
/// The cues are routed to the Android *media* stream with
/// [AndroidAudioFocus.none]:
///  * media keeps playing when the ringer is on silent, which is the gym case;
///  * no audio focus request means the user's music is neither ducked nor
///    interrupted.
///
/// On iOS the session category is `playback` (ignores the mute switch) with
/// `mixWithOthers` (does not stop other audio).
///
/// Playback failures are swallowed: a device with no audio route must never
/// break a workout, and the plugin is absent in widget tests.
class AudioRestSounds implements RestSounds {
  AudioRestSounds({this.volume = 0.35});

  /// Per-stream volume. The WAVs are already quiet; this is a second cap.
  final double volume;

  final Map<RestCue, AudioPlayer> _players = {};
  final Set<RestCue> _loaded = {};
  bool _disposed = false;

  static final AudioContext _context = AudioContext(
    android: AudioContextAndroid(
      contentType: AndroidContentType.sonification,
      usageType: AndroidUsageType.media,
      audioFocus: AndroidAudioFocus.none,
    ),
    iOS: AudioContextIOS(
      category: AVAudioSessionCategory.playback,
      options: {AVAudioSessionOptions.mixWithOthers},
    ),
  );

  @override
  Future<void> play(RestCue cue) async {
    if (_disposed) return;
    try {
      final player = _players.putIfAbsent(
          cue, () => AudioPlayer(playerId: 'compounder-rest-${cue.name}'));
      if (!_loaded.contains(cue)) {
        // Order matters: the audio context must be set before the source,
        // because the low-latency backend builds its stream from the context
        // when the source is loaded.
        await player.setPlayerMode(PlayerMode.lowLatency);
        await player.setReleaseMode(ReleaseMode.stop);
        await player.setAudioContext(_context);
        await player.setVolume(volume);
        await player.setSource(AssetSource(cue.asset));
        _loaded.add(cue);
      }
      // Rewind a cue that is still sounding, then fire it again.
      await player.stop();
      await player.resume();
    } catch (error) {
      debugPrint('rest cue ${cue.name} failed: $error');
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final player in _players.values) {
      try {
        await player.dispose();
      } catch (error) {
        debugPrint('rest cue dispose failed: $error');
      }
    }
    _players.clear();
    _loaded.clear();
  }
}
