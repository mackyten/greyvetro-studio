import '../stt/transcript_model.dart';

class GalleryItem {
  final String id;
  final String fileName; // relative to the gallery directory
  final String text;
  final String voiceId;
  final String voiceName;
  final double stability;
  final double similarityBoost;
  final double style;
  final bool useSpeakerBoost;
  final DateTime createdAt;
  final String? projectId; // absent = "Unsorted"
  final String? title; // user-set display name; falls back to a text snippet
  final Transcript? transcript; // word-timestamped STT result, set on demand

  const GalleryItem({
    required this.id,
    required this.fileName,
    required this.text,
    required this.voiceId,
    required this.voiceName,
    required this.stability,
    required this.similarityBoost,
    this.style = 0.0,
    this.useSpeakerBoost = false,
    required this.createdAt,
    this.projectId,
    this.title,
    this.transcript,
  });

  GalleryItem copyWith({
    String? projectId,
    bool clearProjectId = false,
    String? title,
    Transcript? transcript,
  }) =>
      GalleryItem(
        id: id,
        fileName: fileName,
        text: text,
        voiceId: voiceId,
        voiceName: voiceName,
        stability: stability,
        similarityBoost: similarityBoost,
        style: style,
        useSpeakerBoost: useSpeakerBoost,
        createdAt: createdAt,
        projectId: clearProjectId ? null : (projectId ?? this.projectId),
        title: title ?? this.title,
        transcript: transcript ?? this.transcript,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'fileName': fileName,
        'text': text,
        'voiceId': voiceId,
        'voiceName': voiceName,
        'stability': stability,
        'similarityBoost': similarityBoost,
        'style': style,
        'useSpeakerBoost': useSpeakerBoost,
        'createdAt': createdAt.toIso8601String(),
        'projectId': projectId,
        'title': title,
        'transcript': transcript?.toJson(),
      };

  factory GalleryItem.fromJson(Map<String, dynamic> json) => GalleryItem(
        id: json['id'] as String,
        fileName: json['fileName'] as String,
        text: json['text'] as String? ?? '',
        voiceId: json['voiceId'] as String? ?? '',
        voiceName: json['voiceName'] as String? ?? 'Unknown voice',
        stability: (json['stability'] as num?)?.toDouble() ?? 0.5,
        similarityBoost: (json['similarityBoost'] as num?)?.toDouble() ?? 0.75,
        style: (json['style'] as num?)?.toDouble() ?? 0.0,
        useSpeakerBoost: json['useSpeakerBoost'] as bool? ?? false,
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
            DateTime.now(),
        projectId: json['projectId'] as String?,
        title: json['title'] as String?,
        transcript: json['transcript'] == null
            ? null
            : Transcript.fromJson(json['transcript'] as Map<String, dynamic>),
      );
}

/// Display name for a clip: its user-set title, or a snippet of the script
/// text, or a placeholder. Mirrors the web frontend's `clipTitle`.
String clipTitleOf(GalleryItem item) {
  final title = item.title?.trim();
  if (title != null && title.isNotEmpty) return title;
  final text = item.text.trim();
  if (text.isEmpty) return 'Untitled';
  return text.length > 32 ? text.substring(0, 32) : text;
}
