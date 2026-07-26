import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../core/audio_player.dart';
import '../../core/audio_scrubber.dart';
import '../../core/theme.dart';
import 'stored_scene.dart';

/// Browser-side "render preview": plays the voiceover and swaps the displayed
/// scene image at scene boundaries — no video decode needed. Mirrors the web
/// frontend's `StoryboardPreview`.
Future<void> showStoryboardPreview(
  BuildContext context, {
  required String title,
  required List<StoredScene> scenes,
  required Map<String, Uint8List> imageBytes,
  required String audioPath,
  required AudioPlayer player,
}) async {
  await player.play(audioPath);
  if (!context.mounted) return;
  await showDialog(
    context: context,
    builder: (ctx) => Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 760),
        child: _StoryboardPreviewBody(
          title: title,
          scenes: scenes,
          imageBytes: imageBytes,
          audioPath: audioPath,
          player: player,
        ),
      ),
    ),
  );
  await player.stop();
}

class _StoryboardPreviewBody extends StatelessWidget {
  final String title;
  final List<StoredScene> scenes;
  final Map<String, Uint8List> imageBytes;
  final String audioPath;
  final AudioPlayer player;

  const _StoryboardPreviewBody({
    required this.title,
    required this.scenes,
    required this.imageBytes,
    required this.audioPath,
    required this.player,
  });

  StoredScene? _activeScene(double positionSeconds) {
    StoredScene? current = scenes.isEmpty ? null : scenes.first;
    for (final s in scenes) {
      if (positionSeconds >= s.start) {
        current = s;
      } else {
        break;
      }
    }
    return current;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.brand;
    return Container(
      decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(AppRadii.card)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Preview — $title',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: c.text),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.close_rounded, color: c.text3),
                  tooltip: 'Close',
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: c.outline),
          Flexible(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: ValueListenableBuilder<Duration>(
                valueListenable: player.position,
                builder: (context, position, _) {
                  final active = _activeScene(position.inMilliseconds / 1000.0);
                  final activeIndex = active == null ? -1 : scenes.indexOf(active);
                  final bytes = active == null ? null : imageBytes[active.id];
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      AspectRatio(
                        aspectRatio: 9 / 16,
                        child: Container(
                          decoration: BoxDecoration(
                            color: c.surfaceMuted,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: bytes != null
                              ? Image.memory(bytes, fit: BoxFit.cover)
                              : Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.movie_outlined, size: 40, color: c.text3),
                                      const SizedBox(height: 8),
                                      Text(
                                        'Scene ${activeIndex + 1}'
                                        '${active != null && !active.hasImage ? ' — no image yet' : ''}',
                                        style: TextStyle(color: c.text3, fontSize: 12.5),
                                      ),
                                    ],
                                  ),
                                ),
                        ),
                      ),
                      if (active != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          '“${active.narration}”',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: c.text2, fontStyle: FontStyle.italic, fontSize: 13),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final s in scenes)
                            GestureDetector(
                              onTap: () => player.seek(Duration(milliseconds: (s.start * 1000).round())),
                              child: Container(
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: s.id == active?.id ? c.blueDeep : c.outline,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
          Divider(height: 1, color: c.outline),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                ValueListenableBuilder<String?>(
                  valueListenable: player.playing,
                  builder: (context, playingPath, _) {
                    final isPlaying = playingPath == audioPath;
                    return Material(
                      color: Colors.transparent,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => player.toggle(audioPath),
                        child: Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(gradient: c.sliderGradient, shape: BoxShape.circle),
                          child: Icon(
                            isPlaying ? Icons.stop_rounded : Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(width: 12),
                Expanded(child: AudioScrubber(player: player)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
