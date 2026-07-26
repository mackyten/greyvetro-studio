/// A single word (or spacing/audio-event token) from an ElevenLabs Scribe
/// transcription, with its timing. Mirrors the web frontend's
/// `TranscriptWord`.
class TranscriptWord {
  final String text;

  /// Seconds from the start of the audio.
  final double start;
  final double end;

  /// 'word' | 'spacing' | 'audio_event' (ElevenLabs Scribe categories).
  final String type;

  const TranscriptWord({
    required this.text,
    required this.start,
    required this.end,
    this.type = 'word',
  });

  Map<String, dynamic> toJson() => {
        'text': text,
        'start': start,
        'end': end,
        'type': type,
      };

  factory TranscriptWord.fromJson(Map<String, dynamic> json) => TranscriptWord(
        text: json['text'] as String? ?? '',
        start: (json['start'] as num?)?.toDouble() ?? 0,
        end: (json['end'] as num?)?.toDouble() ?? 0,
        type: json['type'] as String? ?? 'word',
      );
}

/// A word-timestamped STT result for a clip. Mirrors the web frontend's
/// `Transcript`.
class Transcript {
  final String text;
  final String languageCode;
  final List<TranscriptWord> words;

  const Transcript({
    required this.text,
    required this.languageCode,
    required this.words,
  });

  Map<String, dynamic> toJson() => {
        'text': text,
        'languageCode': languageCode,
        'words': words.map((w) => w.toJson()).toList(),
      };

  factory Transcript.fromJson(Map<String, dynamic> json) => Transcript(
        text: json['text'] as String? ?? '',
        languageCode: json['languageCode'] as String? ?? '',
        words: (json['words'] as List? ?? [])
            .map((w) => TranscriptWord.fromJson(w as Map<String, dynamic>))
            .toList(),
      );
}
