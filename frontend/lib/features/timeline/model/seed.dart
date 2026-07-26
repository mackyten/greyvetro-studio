import '../../storyboard/stored_scene.dart';
import 'timeline.dart';

/// Stable source id for the voiceover audio asset within a seeded timeline.
const voiceoverAssetId = 'voiceover';

/// Seeds a [Timeline] from a project's storyboard. The storyboard is the
/// *seeder*, not the editor: scene images become a photo track, the
/// voiceover becomes a single audio clip, and narration becomes a
/// (display-only) caption track. Mirrors the web frontend's
/// `seedTimelineFromScenes`.
///
/// Segment placement reproduces the storyboard renderer exactly — the first
/// clip is pulled back to 0 and the last is padded 1.5s (trailing silence,
/// trimmed by ffmpeg's `-shortest`) — so a seeded timeline renders
/// byte-for-similar to the existing storyboard export.
Timeline seedTimelineFromScenes(
  String projectId,
  List<StoredScene> scenes,
  double audioDuration,
) {
  final ordered = [...scenes]..sort((a, b) => a.start.compareTo(b.start));

  final photoClips = <TimelineClip>[];
  final captionClips = <TimelineClip>[];
  for (var i = 0; i < ordered.length; i++) {
    final scene = ordered[i];
    final startTime = i == 0 ? 0.0 : scene.start;
    final end = i == ordered.length - 1 ? scene.end + 1.5 : ordered[i + 1].start;
    final duration = (end - startTime) < 0.5 ? 0.5 : end - startTime;

    photoClips.add(TimelineClip(
      id: 'photo-${scene.id}',
      // The composited frame file is keyed by the scene id at export.
      sourceId: scene.id,
      startTime: startTime,
      duration: duration,
      inPoint: 0,
      outPoint: duration,
    ));
    captionClips.add(TimelineClip(
      // Caption clips mirror their photo clip and carry the scene id as
      // sourceId so future edits (reorder/trim/split) can re-derive the
      // caption lane by source. At export each caption clip rasterizes to a
      // transparent PNG the backend overlays on its [startTime, end] window.
      id: 'caption-${scene.id}',
      sourceId: scene.id,
      startTime: startTime,
      duration: duration,
      inPoint: 0,
      outPoint: duration,
      text: scene.narration,
    ));
  }

  var visualEnd = 0.0;
  for (final c in photoClips) {
    final end = c.startTime + c.duration;
    if (end > visualEnd) visualEnd = end;
  }
  final audioLen = audioDuration.isFinite && audioDuration > 0 ? audioDuration : visualEnd;

  final tracks = [
    Track(id: 'photo', type: TrackType.photo, zIndex: 0, clips: photoClips),
    Track(
      id: 'audio',
      type: TrackType.audio,
      zIndex: 0,
      clips: [
        TimelineClip(
          id: 'voiceover',
          sourceId: voiceoverAssetId,
          startTime: 0,
          duration: audioLen,
          inPoint: 0,
          outPoint: audioLen,
        ),
      ],
    ),
    Track(id: 'caption', type: TrackType.caption, zIndex: 1, clips: captionClips),
  ];

  // Register the seeded sources so the backend compiler knows their kinds
  // (stills vs audio). Video assets are added later when the user brings a
  // clip in (a future phase).
  final assets = [
    for (final c in photoClips) MediaAsset(id: c.sourceId, type: MediaType.image),
    MediaAsset(id: voiceoverAssetId, type: MediaType.audio, duration: audioLen),
  ];

  return Timeline(
    id: projectId, // one timeline per project, matching the storyboard's 1:1 scoping
    outputWidth: 1080,
    outputHeight: 1920,
    fps: 30,
    tracks: tracks,
    assets: assets,
  );
}
