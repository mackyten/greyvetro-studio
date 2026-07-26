/// The non-destructive, multi-track document the timeline editor produces and
/// the backend ffmpeg compiler renders. Mirrors the backend C# DTO
/// (`Greyvetro.Domain/Entities/Timeline.cs`) field-for-field — camelCase
/// properties, lowercase-string enums — so it serializes straight to JSON for
/// `POST /render`. Placement (`startTime`/`duration`) is kept separate from
/// trim (`inPoint`/`outPoint`) so edits never touch source media until
/// export; transforms are normalized 0-1 so the output resolution can change
/// without re-authoring.
///
/// Only the photo + audio tracks are populated by this phase's seeding (see
/// `model/seed.dart`); the rest of the fields exist so the model is stable as
/// later timeline-editor phases (trim, crop, motion, transitions, ...) fill
/// them in, matching the web frontend's `model/types.ts`.
library;

enum TrackType { video, photo, audio, caption }

enum MediaType { video, image, audio }

enum TransitionStyle { dissolve, fadeToBlack }

/// A normalized (0-1) point in output space, e.g. an overlay clip's top-left placement.
class NormalizedPoint {
  final double x;
  final double y;

  const NormalizedPoint({required this.x, required this.y});

  Map<String, dynamic> toJson() => {'x': x, 'y': y};

  factory NormalizedPoint.fromJson(Map<String, dynamic> json) => NormalizedPoint(
        x: (json['x'] as num?)?.toDouble() ?? 0,
        y: (json['y'] as num?)?.toDouble() ?? 0,
      );
}

/// A normalized (0-1) crop region of a clip's source. Full-frame (0,0,1,1) is a no-op.
class CropRect {
  final double x;
  final double y;
  final double width;
  final double height;

  const CropRect({this.x = 0, this.y = 0, this.width = 1, this.height = 1});

  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'width': width, 'height': height};

  factory CropRect.fromJson(Map<String, dynamic> json) => CropRect(
        x: (json['x'] as num?)?.toDouble() ?? 0,
        y: (json['y'] as num?)?.toDouble() ?? 0,
        width: (json['width'] as num?)?.toDouble() ?? 1,
        height: (json['height'] as num?)?.toDouble() ?? 1,
      );
}

/// A single Ken Burns keyframe: punch-in factor + normalized (0-1) pan center.
class KenBurnsKeyframe {
  final double zoom;
  final double panX;
  final double panY;

  const KenBurnsKeyframe({this.zoom = 1, this.panX = 0.5, this.panY = 0.5});

  Map<String, dynamic> toJson() => {'zoom': zoom, 'panX': panX, 'panY': panY};

  factory KenBurnsKeyframe.fromJson(Map<String, dynamic> json) => KenBurnsKeyframe(
        zoom: (json['zoom'] as num?)?.toDouble() ?? 1,
        panX: (json['panX'] as num?)?.toDouble() ?? 0.5,
        panY: (json['panY'] as num?)?.toDouble() ?? 0.5,
      );
}

/// Keyframed pan/zoom endpoints a clip animates between over its full duration.
class Motion {
  final KenBurnsKeyframe from;
  final KenBurnsKeyframe to;

  const Motion({required this.from, required this.to});

  Map<String, dynamic> toJson() => {'from': from.toJson(), 'to': to.toJson()};

  factory Motion.fromJson(Map<String, dynamic> json) => Motion(
        from: KenBurnsKeyframe.fromJson(json['from'] as Map<String, dynamic>),
        to: KenBurnsKeyframe.fromJson(json['to'] as Map<String, dynamic>),
      );
}

/// A transition into a clip from its predecessor on the base track.
class Transition {
  final TransitionStyle style;
  final double duration;

  const Transition({this.style = TransitionStyle.dissolve, this.duration = 0.5});

  Map<String, dynamic> toJson() => {'style': style.name, 'duration': duration};

  factory Transition.fromJson(Map<String, dynamic> json) => Transition(
        style: TransitionStyle.values.byName(json['style'] as String? ?? 'dissolve'),
        duration: (json['duration'] as num?)?.toDouble() ?? 0.5,
      );
}

/// A single clip placed on a [Track]. Named `TimelineClip` (not `Clip`) to
/// avoid colliding with Flutter's own `Clip` enum (`clipBehavior`).
class TimelineClip {
  final String id;

  /// -> [MediaAsset.id]. Blank for caption clips, which carry text not media.
  final String sourceId;

  // Timeline placement.
  final double startTime; // seconds on the timeline
  final double duration; // seconds shown on the timeline

  // Trim — non-destructive, relative to the source media (0 for stills).
  final double inPoint;
  final double outPoint;

  // Transform — non-destructive, normalized 0-1 (later phases).
  final CropRect? crop;
  final double? rotation;
  final NormalizedPoint? position;
  final double? scale;

  // Audio (later phases).
  final double? volume;
  final double? fadeIn;
  final double? fadeOut;
  final bool includeAudio;

  /// Caption clips carry text; rasterized to an alpha overlay at export.
  final String? text;

  // Ken Burns pan/zoom (later phases). Stills only.
  final Motion? motion;

  // Crossfade into this base-track clip from its predecessor (later phases).
  final Transition? transitionIn;
  final double? fadeInFromBlack;
  final double? fadeOutToBlack;

  const TimelineClip({
    required this.id,
    required this.sourceId,
    required this.startTime,
    required this.duration,
    this.inPoint = 0,
    this.outPoint = 0,
    this.crop,
    this.rotation,
    this.position,
    this.scale,
    this.volume,
    this.fadeIn,
    this.fadeOut,
    this.includeAudio = false,
    this.text,
    this.motion,
    this.transitionIn,
    this.fadeInFromBlack,
    this.fadeOutToBlack,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'sourceId': sourceId,
        'startTime': startTime,
        'duration': duration,
        'inPoint': inPoint,
        'outPoint': outPoint,
        if (crop != null) 'crop': crop!.toJson(),
        if (rotation != null) 'rotation': rotation,
        if (position != null) 'position': position!.toJson(),
        if (scale != null) 'scale': scale,
        if (volume != null) 'volume': volume,
        if (fadeIn != null) 'fadeIn': fadeIn,
        if (fadeOut != null) 'fadeOut': fadeOut,
        'includeAudio': includeAudio,
        if (text != null) 'text': text,
        if (motion != null) 'motion': motion!.toJson(),
        if (transitionIn != null) 'transitionIn': transitionIn!.toJson(),
        if (fadeInFromBlack != null) 'fadeInFromBlack': fadeInFromBlack,
        if (fadeOutToBlack != null) 'fadeOutToBlack': fadeOutToBlack,
      };

  factory TimelineClip.fromJson(Map<String, dynamic> json) => TimelineClip(
        id: json['id'] as String,
        sourceId: json['sourceId'] as String? ?? '',
        startTime: (json['startTime'] as num?)?.toDouble() ?? 0,
        duration: (json['duration'] as num?)?.toDouble() ?? 0,
        inPoint: (json['inPoint'] as num?)?.toDouble() ?? 0,
        outPoint: (json['outPoint'] as num?)?.toDouble() ?? 0,
        crop: json['crop'] == null ? null : CropRect.fromJson(json['crop'] as Map<String, dynamic>),
        rotation: (json['rotation'] as num?)?.toDouble(),
        position: json['position'] == null
            ? null
            : NormalizedPoint.fromJson(json['position'] as Map<String, dynamic>),
        scale: (json['scale'] as num?)?.toDouble(),
        volume: (json['volume'] as num?)?.toDouble(),
        fadeIn: (json['fadeIn'] as num?)?.toDouble(),
        fadeOut: (json['fadeOut'] as num?)?.toDouble(),
        includeAudio: json['includeAudio'] as bool? ?? false,
        text: json['text'] as String?,
        motion: json['motion'] == null ? null : Motion.fromJson(json['motion'] as Map<String, dynamic>),
        transitionIn: json['transitionIn'] == null
            ? null
            : Transition.fromJson(json['transitionIn'] as Map<String, dynamic>),
        fadeInFromBlack: (json['fadeInFromBlack'] as num?)?.toDouble(),
        fadeOutToBlack: (json['fadeOutToBlack'] as num?)?.toDouble(),
      );

  /// Copies placement/id/text/overlay-transform fields. `position`/`scale`
  /// (overlay placement) never need "clear to null" semantics — an overlay
  /// clip always has *some* position/size — so the plain `?? this.field`
  /// idiom is fine here, unlike crop/rotation (see [withCrop]/[withRotation]).
  TimelineClip copyWith({
    String? id,
    String? sourceId,
    double? startTime,
    double? duration,
    double? inPoint,
    double? outPoint,
    String? text,
    NormalizedPoint? position,
    double? scale,
  }) =>
      TimelineClip(
        id: id ?? this.id,
        sourceId: sourceId ?? this.sourceId,
        startTime: startTime ?? this.startTime,
        duration: duration ?? this.duration,
        inPoint: inPoint ?? this.inPoint,
        outPoint: outPoint ?? this.outPoint,
        crop: crop,
        rotation: rotation,
        position: position ?? this.position,
        scale: scale ?? this.scale,
        volume: volume,
        fadeIn: fadeIn,
        fadeOut: fadeOut,
        includeAudio: includeAudio,
        text: text ?? this.text,
        motion: motion,
        transitionIn: transitionIn,
        fadeInFromBlack: fadeInFromBlack,
        fadeOutToBlack: fadeOutToBlack,
      );

  /// Sets (or clears, with `null`) the crop/reframe rect. [copyWith] can't do
  /// this — `crop ?? this.crop` can't tell "not passed" from "explicitly
  /// cleared" — so this constructs the clip directly instead.
  TimelineClip withCrop(CropRect? crop) => TimelineClip(
        id: id,
        sourceId: sourceId,
        startTime: startTime,
        duration: duration,
        inPoint: inPoint,
        outPoint: outPoint,
        crop: crop,
        rotation: rotation,
        position: position,
        scale: scale,
        volume: volume,
        fadeIn: fadeIn,
        fadeOut: fadeOut,
        includeAudio: includeAudio,
        text: text,
        motion: motion,
        transitionIn: transitionIn,
        fadeInFromBlack: fadeInFromBlack,
        fadeOutToBlack: fadeOutToBlack,
      );

  /// Sets (or clears, with `null`) the tilt in degrees. See [withCrop] for
  /// why this bypasses [copyWith].
  TimelineClip withRotation(double? rotation) => TimelineClip(
        id: id,
        sourceId: sourceId,
        startTime: startTime,
        duration: duration,
        inPoint: inPoint,
        outPoint: outPoint,
        crop: crop,
        rotation: rotation,
        position: position,
        scale: scale,
        volume: volume,
        fadeIn: fadeIn,
        fadeOut: fadeOut,
        includeAudio: includeAudio,
        text: text,
        motion: motion,
        transitionIn: transitionIn,
        fadeInFromBlack: fadeInFromBlack,
        fadeOutToBlack: fadeOutToBlack,
      );

  /// Sets (or clears, with `null`) the keyframed Ken Burns pan/zoom. See
  /// [withCrop] for why this bypasses [copyWith].
  TimelineClip withMotion(Motion? motion) => TimelineClip(
        id: id,
        sourceId: sourceId,
        startTime: startTime,
        duration: duration,
        inPoint: inPoint,
        outPoint: outPoint,
        crop: crop,
        rotation: rotation,
        position: position,
        scale: scale,
        volume: volume,
        fadeIn: fadeIn,
        fadeOut: fadeOut,
        includeAudio: includeAudio,
        text: text,
        motion: motion,
        transitionIn: transitionIn,
        fadeInFromBlack: fadeInFromBlack,
        fadeOutToBlack: fadeOutToBlack,
      );
}

class Track {
  final String id;
  final TrackType type;

  /// Stacking order for visual tracks; lowest is the base layer.
  final int zIndex;
  final bool muted;

  /// 0-1 gain for audio tracks (null = unity).
  final double? volume;
  final List<TimelineClip> clips;

  const Track({
    required this.id,
    required this.type,
    this.zIndex = 0,
    this.muted = false,
    this.volume,
    this.clips = const [],
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'zIndex': zIndex,
        'muted': muted,
        if (volume != null) 'volume': volume,
        'clips': clips.map((c) => c.toJson()).toList(),
      };

  factory Track.fromJson(Map<String, dynamic> json) => Track(
        id: json['id'] as String,
        type: TrackType.values.byName(json['type'] as String? ?? 'photo'),
        zIndex: (json['zIndex'] as num?)?.toInt() ?? 0,
        muted: json['muted'] as bool? ?? false,
        volume: (json['volume'] as num?)?.toDouble(),
        clips: (json['clips'] as List? ?? [])
            .map((c) => TimelineClip.fromJson(c as Map<String, dynamic>))
            .toList(),
      );

  Track copyWith({List<TimelineClip>? clips}) =>
      Track(id: id, type: type, zIndex: zIndex, muted: muted, volume: volume, clips: clips ?? this.clips);
}

/// Metadata for a source blob the clips reference; the bytes travel
/// out-of-band (multipart on the wire, a file on disk locally).
class MediaAsset {
  final String id;
  final MediaType type;
  final int? width;
  final int? height;

  /// Intrinsic length in seconds for video/audio.
  final double? duration;

  const MediaAsset({required this.id, required this.type, this.width, this.height, this.duration});

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        if (width != null) 'width': width,
        if (height != null) 'height': height,
        if (duration != null) 'duration': duration,
      };

  factory MediaAsset.fromJson(Map<String, dynamic> json) => MediaAsset(
        id: json['id'] as String,
        type: MediaType.values.byName(json['type'] as String? ?? 'image'),
        width: (json['width'] as num?)?.toInt(),
        height: (json['height'] as num?)?.toInt(),
        duration: (json['duration'] as num?)?.toDouble(),
      );
}

class Timeline {
  final String id;
  final int outputWidth;
  final int outputHeight;
  final int fps;
  final List<Track> tracks;
  final List<MediaAsset> assets;

  const Timeline({
    required this.id,
    this.outputWidth = 1080,
    this.outputHeight = 1920,
    this.fps = 30,
    this.tracks = const [],
    this.assets = const [],
  });

  /// Timeline total = the latest clip end across all tracks.
  double get totalDuration {
    var end = 0.0;
    for (final track in tracks) {
      for (final clip in track.clips) {
        final clipEnd = clip.startTime + clip.duration;
        if (clipEnd > end) end = clipEnd;
      }
    }
    return end;
  }

  Track? trackOfType(TrackType type) {
    for (final t in tracks) {
      if (t.type == type) return t;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'outputWidth': outputWidth,
        'outputHeight': outputHeight,
        'fps': fps,
        'tracks': tracks.map((t) => t.toJson()).toList(),
        'assets': assets.map((a) => a.toJson()).toList(),
      };

  factory Timeline.fromJson(Map<String, dynamic> json) => Timeline(
        id: json['id'] as String,
        outputWidth: (json['outputWidth'] as num?)?.toInt() ?? 1080,
        outputHeight: (json['outputHeight'] as num?)?.toInt() ?? 1920,
        fps: (json['fps'] as num?)?.toInt() ?? 30,
        tracks: (json['tracks'] as List? ?? [])
            .map((t) => Track.fromJson(t as Map<String, dynamic>))
            .toList(),
        assets: (json['assets'] as List? ?? [])
            .map((a) => MediaAsset.fromJson(a as Map<String, dynamic>))
            .toList(),
      );

  Timeline copyWith({List<Track>? tracks, List<MediaAsset>? assets}) => Timeline(
        id: id,
        outputWidth: outputWidth,
        outputHeight: outputHeight,
        fps: fps,
        tracks: tracks ?? this.tracks,
        assets: assets ?? this.assets,
      );
}
