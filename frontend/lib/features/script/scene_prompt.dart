/// A storyboard scene proposed from a transcript: a time slice of the
/// voiceover plus an image prompt for it. Mirrors the web frontend's `Scene`
/// (named `ScenePrompt` here to avoid colliding with `dart:ui`'s `Scene`).
class ScenePrompt {
  /// Start time in seconds from the beginning of the audio.
  final double start;

  /// End time in seconds from the beginning of the audio.
  final double end;

  /// The narration excerpt this scene covers.
  final String narration;

  /// Detailed visual prompt for generating the scene image.
  final String imagePrompt;

  const ScenePrompt({
    required this.start,
    required this.end,
    required this.narration,
    required this.imagePrompt,
  });

  factory ScenePrompt.fromJson(Map<String, dynamic> json) => ScenePrompt(
        start: (json['start'] as num?)?.toDouble() ?? 0,
        end: (json['end'] as num?)?.toDouble() ?? 0,
        narration: json['narration'] as String? ?? '',
        imagePrompt: json['imagePrompt'] as String? ?? '',
      );
}
