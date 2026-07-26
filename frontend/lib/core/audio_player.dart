import 'dart:async';
import 'package:audioplayers/audioplayers.dart' as ap;
import 'package:flutter/foundation.dart';

/// Cross-platform audio player (macOS + Windows) backed by `audioplayers`.
///
/// Keeps the simple play/stop/toggle API the app already uses, and adds
/// [position] / [duration] streams plus [seek] so widgets can render a
/// scrubber. Position and duration reflect the currently [playing] track.
class AudioPlayer {
  final ap.AudioPlayer _player = ap.AudioPlayer();

  /// Absolute path of the file currently playing, or null. Listenable so
  /// widgets can reflect play/stop state.
  final ValueNotifier<String?> playing = ValueNotifier(null);

  /// Playback position of the active track.
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);

  /// Total duration of the active track, or null until known.
  final ValueNotifier<Duration?> duration = ValueNotifier(null);

  late final StreamSubscription<Duration> _posSub;
  late final StreamSubscription<Duration> _durSub;
  late final StreamSubscription<void> _completeSub;

  AudioPlayer() {
    _player.setReleaseMode(ap.ReleaseMode.stop);
    _posSub = _player.onPositionChanged.listen((p) => position.value = p);
    _durSub = _player.onDurationChanged.listen((d) => duration.value = d);
    _completeSub = _player.onPlayerComplete.listen((_) {
      playing.value = null;
      position.value = Duration.zero;
    });
  }

  bool isPlaying(String path) => playing.value == path;

  Future<void> toggle(String path) async {
    if (playing.value == path) {
      await stop();
    } else {
      await play(path);
    }
  }

  Future<void> play(String path) async {
    await _player.stop();
    position.value = Duration.zero;
    duration.value = null;
    await _player.play(ap.DeviceFileSource(path));
    playing.value = path;
  }

  Future<void> stop() async {
    await _player.stop();
    playing.value = null;
    position.value = Duration.zero;
  }

  /// Pauses the active track in place — unlike [stop], the position (and
  /// [playing] path) are left as-is so [resume] can continue from here.
  Future<void> pause() async {
    await _player.pause();
  }

  /// Resumes a track paused via [pause] from its last position.
  Future<void> resume() async {
    await _player.resume();
  }

  /// Jump the active track to [to].
  Future<void> seek(Duration to) async {
    await _player.seek(to);
    position.value = to;
  }

  void dispose() {
    _posSub.cancel();
    _durSub.cancel();
    _completeSub.cancel();
    _player.dispose();
    playing.dispose();
    position.dispose();
    duration.dispose();
  }
}
