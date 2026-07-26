/// Pure edit operations on a [Timeline] for the interactive editor (Studio
/// Phase 5 — TL Phases 2/3/overlay). Mirrors the applicable subset of the web
/// frontend's `model/timelineOps.ts`: Flutter's timeline has no video/music
/// tracks yet (those are later, separate phases on web), so the structural
/// ops (reorder/trim/split/delete) and reframe ops (crop/rotation) only ever
/// touch the *base* visual track — the lowest-zIndex photo track, found via
/// [baseVisualTrack] rather than a naive "first photo track" lookup, since a
/// photo/video track with a *higher* zIndex is an overlay (PiP/logo) layer,
/// not part of the base concat (see [isOverlayTrack]). The audio track stays
/// the single voiceover clip untouched, and the caption track is
/// display-only, rebuilt by [reanchor] to mirror the base track (text
/// carried over by source scene id, same as the web version).
///
/// Every function takes a [Timeline] and returns a new one — no mutation, no
/// side effects, so the widget layer can treat edits as plain state updates
/// and persist the result.
library;

import 'timeline.dart';

/// Smallest clip length the editor allows (seconds) — keeps trims/splits well-formed.
const double minClipDuration = 0.3;

bool _isVisual(Track t) => t.type == TrackType.photo || t.type == TrackType.video;

/// The zIndex of the base (lowest) visual layer — the contiguous track the
/// structural/reframe ops operate on. Any other photo/video track sits above
/// it as an overlay. Falls back to 0 for a timeline with no visual tracks yet.
int _baseVisualZIndex(Timeline timeline) {
  var min = 0;
  var found = false;
  for (final t in timeline.tracks) {
    if (!_isVisual(t)) continue;
    if (!found || t.zIndex < min) {
      min = t.zIndex;
      found = true;
    }
  }
  return min;
}

/// The base (lowest-zIndex) visual track — the one every structural edit and
/// reframe op targets. Distinct from `timeline.trackOfType(TrackType.photo)`,
/// which would return the *first* photo-type track in list order and could
/// silently pick an overlay track instead once one exists.
Track? baseVisualTrack(Timeline timeline) {
  final baseZ = _baseVisualZIndex(timeline);
  for (final t in timeline.tracks) {
    if (_isVisual(t) && t.zIndex == baseZ) return t;
  }
  return null;
}

/// True for a photo/video track that floats above the base zIndex — a
/// PiP/logo overlay layer, not part of the base concat.
bool isOverlayTrack(Timeline timeline, String trackId) {
  Track? track;
  for (final t in timeline.tracks) {
    if (t.id == trackId) {
      track = t;
      break;
    }
  }
  return track != null && _isVisual(track) && track.zIndex != _baseVisualZIndex(timeline);
}

Timeline _withTrackClips(Timeline timeline, Track track, List<TimelineClip> clips) => timeline.copyWith(
      tracks: [
        for (final t in timeline.tracks) t.id == track.id ? t.copyWith(clips: clips) : t,
      ],
    );

/// Re-lay the base visual track into a contiguous document (clips anchored
/// from 0 in array order) after a structural edit, and rebuild the
/// (display-only) caption track to mirror it — text carried over by source
/// scene id, so a split scene's captions duplicate onto both halves. The
/// audio track and any overlay tracks are left untouched. Pure.
Timeline reanchor(Timeline timeline) {
  final photoTrack = baseVisualTrack(timeline);
  if (photoTrack == null) return timeline;

  var cursor = 0.0;
  final photoClips = <TimelineClip>[];
  for (final c in photoTrack.clips) {
    photoClips.add(c.copyWith(startTime: cursor));
    cursor += c.duration;
  }

  final captionTrack = timeline.trackOfType(TrackType.caption);
  final textBySource = <String, String>{
    for (final c in captionTrack?.clips ?? const <TimelineClip>[]) c.sourceId: c.text ?? '',
  };
  final captionClips = [
    for (final p in photoClips)
      TimelineClip(
        id: 'caption-${p.id}',
        sourceId: p.sourceId,
        startTime: p.startTime,
        duration: p.duration,
        inPoint: 0,
        outPoint: p.duration,
        text: textBySource[p.sourceId] ?? '',
      ),
  ];

  return timeline.copyWith(
    tracks: [
      for (final t in timeline.tracks)
        if (t.id == photoTrack.id)
          t.copyWith(clips: photoClips)
        else if (t.type == TrackType.caption)
          t.copyWith(clips: captionClips)
        else
          t,
    ],
  );
}

/// Reorder a base-track clip, dropping it in front of [targetClipId]. No-op
/// for an unknown clip/target, a cross-track id, or an overlay clip id.
/// Re-anchors so the track stays contiguous. Pure.
Timeline moveClip(Timeline timeline, String clipId, String targetClipId) {
  if (clipId == targetClipId) return timeline;
  final track = baseVisualTrack(timeline);
  if (track == null) return timeline;
  final fromIndex = track.clips.indexWhere((c) => c.id == clipId);
  final toIndex = track.clips.indexWhere((c) => c.id == targetClipId);
  if (fromIndex < 0 || toIndex < 0) return timeline;

  final clips = [...track.clips];
  final moved = clips.removeAt(fromIndex);
  clips.insert(clips.indexWhere((c) => c.id == targetClipId), moved);
  return reanchor(_withTrackClips(timeline, track, clips));
}

/// Trim a base-track clip to [duration] seconds (clamped to
/// [minClipDuration]). Stills have no source window, so both edges just
/// resize the on-timeline duration; downstream clips re-anchor to close the
/// gap or make room. Pure.
Timeline trimClip(Timeline timeline, String clipId, double duration) {
  final track = baseVisualTrack(timeline);
  if (track == null || !track.clips.any((c) => c.id == clipId)) return timeline;

  final clamped = duration < minClipDuration ? minClipDuration : duration;
  final clips = [
    for (final c in track.clips)
      if (c.id == clipId) c.copyWith(duration: clamped, inPoint: 0, outPoint: clamped) else c,
  ];
  return reanchor(_withTrackClips(timeline, track, clips));
}

/// Split a base-track clip at [localOffset] seconds into it, yielding two
/// clips over the same source scene (both keep the scene's narration via
/// [reanchor]'s caption rebuild). No-op if the offset would leave either
/// half shorter than [minClipDuration]. Re-anchors. Pure.
Timeline splitClip(Timeline timeline, String clipId, double localOffset) {
  final track = baseVisualTrack(timeline);
  if (track == null) return timeline;
  final idx = track.clips.indexWhere((c) => c.id == clipId);
  if (idx < 0) return timeline;
  final clip = track.clips[idx];
  if (localOffset <= minClipDuration || localOffset >= clip.duration - minClipDuration) return timeline;

  final tag = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final first = clip.copyWith(id: '${clip.id}.${tag}a', duration: localOffset, inPoint: 0, outPoint: localOffset);
  final second = clip.copyWith(
    id: '${clip.id}.${tag}b',
    duration: clip.duration - localOffset,
    inPoint: 0,
    outPoint: clip.duration - localOffset,
  );

  final clips = [...track.clips]..replaceRange(idx, idx + 1, [first, second]);
  return reanchor(_withTrackClips(timeline, track, clips));
}

/// Remove a base-track clip and close the gap. Refuses to remove the last
/// remaining clip (the compiler requires at least one visual clip). Pure.
Timeline deleteClip(Timeline timeline, String clipId) {
  final track = baseVisualTrack(timeline);
  if (track == null || !track.clips.any((c) => c.id == clipId)) return timeline;
  final clips = track.clips.where((c) => c.id != clipId).toList();
  if (clips.isEmpty) return timeline;
  return reanchor(_withTrackClips(timeline, track, clips));
}

/// Deepest punch-in the reframe control allows.
const double maxZoom = 3;

double _clamp(double v, double lo, double hi) => v < lo ? lo : (v > hi ? hi : v);

/// A normalized crop rect from an intuitive zoom (1-[maxZoom]) + pan-center
/// (0-1 each axis). Equal normalized width/height preserve the source
/// aspect, so the crop cover-fits to the output as a uniform zoom regardless
/// of the source's shape. The pan-center is clamped so the box stays
/// in-bounds.
CropRect cropFromZoomPan(double zoom, double panX, double panY) {
  final z = _clamp(zoom, 1, maxZoom);
  final size = 1 / z;
  return CropRect(
    x: _clamp(panX - size / 2, 0, 1 - size),
    y: _clamp(panY - size / 2, 0, 1 - size),
    width: size,
    height: size,
  );
}

/// Inverse of [cropFromZoomPan]: the zoom + pan-center a crop represents
/// (drives the reframe sliders). `(1, 0.5, 0.5)` for no crop / a degenerate
/// rect.
({double zoom, double panX, double panY}) zoomPanFromCrop(CropRect? crop) {
  if (crop == null || crop.width <= 0) return (zoom: 1, panX: 0.5, panY: 0.5);
  return (
    zoom: 1 / crop.width,
    panX: crop.x + crop.width / 2,
    panY: crop.y + crop.height / 2,
  );
}

/// Set (or clear, with `null` or a full-frame rect) a base-track clip's
/// crop/reframe. Doesn't re-anchor — crop never touches placement/duration.
/// Pure.
Timeline setCrop(Timeline timeline, String clipId, CropRect? crop) {
  final track = baseVisualTrack(timeline);
  if (track == null || !track.clips.any((c) => c.id == clipId)) return timeline;
  final isFull = crop == null || (crop.x <= 0 && crop.y <= 0 && crop.width >= 1 && crop.height >= 1);
  final clips = [
    for (final c in track.clips) if (c.id == clipId) c.withCrop(isFull ? null : crop) else c,
  ];
  return _withTrackClips(timeline, track, clips);
}

/// Widest tilt the reframe control allows, in either direction (degrees).
const double maxRotation = 45;

/// Set (or clear, with `null`) a base-track clip's tilt in degrees. A
/// near-zero value collapses to `null` (no-op for the compiler). Doesn't
/// re-anchor. Pure.
Timeline setRotation(Timeline timeline, String clipId, double? rotation) {
  final track = baseVisualTrack(timeline);
  if (track == null || !track.clips.any((c) => c.id == clipId)) return timeline;
  final normalized = (rotation != null && rotation.abs() > 0.01) ? rotation : null;
  final clips = [
    for (final c in track.clips) if (c.id == clipId) c.withRotation(normalized) else c,
  ];
  return _withTrackClips(timeline, track, clips);
}

/// Default placement/size for a freshly added overlay (top-right-ish PiP,
/// 30% of the frame width).
const _defaultOverlayPosition = NormalizedPoint(x: 0.62, y: 0.04);
const _defaultOverlayScale = 0.3;

/// Add an image overlay (logo/PiP) as its own visual track above the base,
/// one clip spanning the current timeline length by default (a persistent
/// watermark; trimming its duration is a later refinement). The asset is
/// registered so the backend compiler composites it with `overlay` — not
/// strictly required for a still (an unregistered source defaults to
/// image), but kept explicit to match the web reference. Pure.
Timeline addOverlayImage(Timeline timeline, String assetId) {
  final span = timeline.totalDuration > minClipDuration ? timeline.totalDuration : minClipDuration;
  final clip = TimelineClip(
    id: 'overlay-$assetId',
    sourceId: assetId,
    startTime: 0,
    duration: span,
    inPoint: 0,
    outPoint: span,
    position: _defaultOverlayPosition,
    scale: _defaultOverlayScale,
  );
  var maxZ = 0;
  for (final t in timeline.tracks) {
    if (_isVisual(t) && t.zIndex > maxZ) maxZ = t.zIndex;
  }
  final track = Track(id: 'overlay-$assetId', type: TrackType.photo, zIndex: maxZ + 1, clips: [clip]);
  final asset = MediaAsset(id: assetId, type: MediaType.image);
  return timeline.copyWith(tracks: [...timeline.tracks, track], assets: [...timeline.assets, asset]);
}

/// Set an overlay clip's position (normalized 0-1 top-left) and/or scale
/// (0-1 of output width) — finds the clip across every track, since it's
/// only ever meaningful for an overlay clip. Unspecified fields are left as
/// they were. Pure.
Timeline setOverlayTransform(Timeline timeline, String clipId, {NormalizedPoint? position, double? scale}) {
  return timeline.copyWith(
    tracks: [
      for (final t in timeline.tracks)
        t.copyWith(clips: [
          for (final c in t.clips) if (c.id == clipId) c.copyWith(position: position, scale: scale) else c,
        ]),
    ],
  );
}

/// Remove a whole track (used to drop an added overlay). Leaves its asset in
/// place (harmless — an unreferenced asset is simply never uploaded at
/// export). Pure.
Timeline removeTrack(Timeline timeline, String trackId) =>
    timeline.copyWith(tracks: timeline.tracks.where((t) => t.id != trackId).toList());
