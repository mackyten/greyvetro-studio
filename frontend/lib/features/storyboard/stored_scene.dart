import '../script/scene_prompt.dart';

/// A scene persisted on a project's storyboard (the image, if any, lives in a
/// sibling file managed by `SceneRepository`). Mirrors the web frontend's
/// `StoredScene`.
class StoredScene {
  final String id;
  final String projectId;
  final String clipId; // the gallery clip providing the voiceover
  final int order;
  final double start;
  final double end;
  final String narration;
  final String imagePrompt;
  final bool hasImage;

  const StoredScene({
    required this.id,
    required this.projectId,
    required this.clipId,
    required this.order,
    required this.start,
    required this.end,
    required this.narration,
    required this.imagePrompt,
    this.hasImage = false,
  });

  factory StoredScene.fromPrompt(
    ScenePrompt scene, {
    required String id,
    required String projectId,
    required String clipId,
    required int order,
  }) =>
      StoredScene(
        id: id,
        projectId: projectId,
        clipId: clipId,
        order: order,
        start: scene.start,
        end: scene.end,
        narration: scene.narration,
        imagePrompt: scene.imagePrompt,
      );

  StoredScene copyWith({
    int? order,
    double? start,
    double? end,
    String? narration,
    String? imagePrompt,
    bool? hasImage,
  }) =>
      StoredScene(
        id: id,
        projectId: projectId,
        clipId: clipId,
        order: order ?? this.order,
        start: start ?? this.start,
        end: end ?? this.end,
        narration: narration ?? this.narration,
        imagePrompt: imagePrompt ?? this.imagePrompt,
        hasImage: hasImage ?? this.hasImage,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'projectId': projectId,
        'clipId': clipId,
        'order': order,
        'start': start,
        'end': end,
        'narration': narration,
        'imagePrompt': imagePrompt,
        'hasImage': hasImage,
      };

  factory StoredScene.fromJson(Map<String, dynamic> json) => StoredScene(
        id: json['id'] as String,
        projectId: json['projectId'] as String,
        clipId: json['clipId'] as String? ?? '',
        order: (json['order'] as num?)?.toInt() ?? 0,
        start: (json['start'] as num?)?.toDouble() ?? 0,
        end: (json['end'] as num?)?.toDouble() ?? 0,
        narration: json['narration'] as String? ?? '',
        imagePrompt: json['imagePrompt'] as String? ?? '',
        hasImage: json['hasImage'] as bool? ?? false,
      );
}
