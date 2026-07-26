import 'dart:io';
import 'dart:math' as math;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/api_client.dart';
import '../../core/audio_player.dart';
import '../../core/theme.dart';
import '../gallery/gallery_item.dart';
import '../gallery/gallery_repository.dart';
import '../projects/project.dart';
import '../projects/project_repository.dart';
import '../storyboard/composite.dart';
import '../storyboard/scene_repository.dart';
import '../storyboard/stored_scene.dart';
import 'model/seed.dart';
import 'model/timeline.dart';
import 'model/timeline_ops.dart';
import 'timeline_asset_repository.dart';
import 'timeline_repository.dart';

const _pxPerSecond = 40.0;
const _rulerHeight = 20.0;
const _laneGap = 10.0;
const _previewWidth = 110.0;
const _previewHeight = 195.0;

String _fmtTime(double seconds) {
  final m = seconds ~/ 60;
  final s = seconds - m * 60;
  return '$m:${s.toStringAsFixed(1).padLeft(4, '0')}';
}

double _clampD(double v, double lo, double hi) => v < lo ? lo : (v > hi ? hi : v);

String _slugify(String s) {
  final lower =
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  final trimmed = lower.length > 48 ? lower.substring(0, 48) : lower;
  return trimmed.isEmpty ? 'video' : trimmed;
}

/// Smallest-to-largest ruler tick spacing (seconds) as the timeline gets
/// longer — mirrors the web editor's `tickStep`.
double _tickStep(double total) {
  if (total <= 15) return 2;
  if (total <= 40) return 5;
  if (total <= 90) return 10;
  return 15;
}

/// Transient trim-drag state (committed to the timeline on pointer-up).
class _TrimDrag {
  final String clipId;
  final bool isStart;
  final double startDuration;
  double deltaPx = 0;

  _TrimDrag({required this.clipId, required this.isStart, required this.startDuration});
}

/// One lane row in the tracks panel — a label, a fixed height, and a content
/// builder. See `_buildLanes`.
class _Lane {
  final String label;
  final double height;
  final Widget Function() build;

  _Lane({required this.label, required this.height, required this.build});
}

/// Transient reframe-drag state (committed to the timeline when a slider
/// gesture ends). Holds all four axes together — a slider drag only ever
/// touches one, but a fresh drag always seeds from the clip's current
/// committed crop/rotation, so partial edits across a quick sequence of
/// slider drags never mix stale values.
class _TransformDrag {
  final String clipId;
  double zoom;
  double panX;
  double panY;
  double rotation;

  _TransformDrag({
    required this.clipId,
    required this.zoom,
    required this.panX,
    required this.panY,
    required this.rotation,
  });
}

/// Transient overlay position/size-drag state — same seed-on-first-touch,
/// commit-on-release lifecycle as [_TransformDrag].
class _OverlayDrag {
  final String clipId;
  double x;
  double y;
  double scale;

  _OverlayDrag({required this.clipId, required this.x, required this.y, required this.scale});
}

/// Transient Ken Burns keyframe-drag state — same seed-on-first-touch,
/// commit-on-release lifecycle as [_TransformDrag], but holding both
/// keyframes' zoom/pan (6 axes) since a motion clip edits Start and End
/// together in one inspector.
class _MotionDrag {
  final String clipId;
  double fromZoom;
  double fromPanX;
  double fromPanY;
  double toZoom;
  double toPanX;
  double toPanY;

  _MotionDrag({
    required this.clipId,
    required this.fromZoom,
    required this.fromPanX,
    required this.fromPanY,
    required this.toZoom,
    required this.toPanX,
    required this.toPanY,
  });
}

/// Per-project timeline editor (Greyvetro Studio Phase 5, TL Phases 2-3 +
/// overlay layering + Ken Burns motion): a photo track seeded from the
/// storyboard, editable in place — select, drag-to-reorder, trim both edges,
/// split at the playhead, delete (guarded so at least one scene always
/// remains), reframe (crop/pan/zoom) + tilt a selected scene via the
/// "Reframe" sliders, or swap that for animated Start/End Ken Burns keyframes
/// via "Add motion" (mutually exclusive with the static crop/tilt on the same
/// clip) — plus image overlays (PiP/logo watermarks): added via a file
/// picker, each its own photo track above the base track's zIndex,
/// positioned/sized via the "Overlay" sliders and removable as a whole track.
/// A click-to-scrub playhead and Play/Pause are driven by the shared
/// [AudioPlayer], with a live preview that swaps the displayed still and
/// caption text as the playhead moves, approximates the selected base clip's
/// crop/rotation (or, for a motion clip, the keyframe lerped to the current
/// playhead position within it), and composites any active overlays on top
/// (exact result is the ffmpeg-side compiler math at export). The audio track
/// stays the single voiceover clip (untouched by editing) and the caption
/// track is display-only, re-derived from the base track by source scene id
/// after every structural edit (see `model/timeline_ops.dart`, which
/// distinguishes the base visual track from overlay tracks by zIndex
/// throughout). Exports through the backend's structured-Timeline `/render`
/// path. Mirrors the interaction model of the web frontend's
/// `TimelineEditor`, scoped to what applies here — no video/music tracks,
/// overlay trim, or transitions yet.
class TimelineScreen extends StatefulWidget {
  final ProjectRepository projects;
  final GalleryRepository gallery;
  final SceneRepository scenes;
  final TimelineRepository timelines;
  final TimelineAssetRepository timelineAssets;
  final ApiClient apiClient;
  final AudioPlayer player;

  const TimelineScreen({
    super.key,
    required this.projects,
    required this.gallery,
    required this.scenes,
    required this.timelines,
    required this.timelineAssets,
    required this.apiClient,
    required this.player,
  });

  @override
  State<TimelineScreen> createState() => TimelineScreenState();
}

class TimelineScreenState extends State<TimelineScreen> {
  List<Project> _projects = [];
  String? _projectId;
  List<StoredScene> _sceneList = [];
  Map<String, StoredScene> _sceneById = {};
  Timeline? _timeline;
  bool _loading = true;
  Map<String, Uint8List> _thumbnails = {};
  bool _busy = false;
  bool _exporting = false;

  // Voiceover playback (shared AudioPlayer) + editor interaction state.
  String? _voiceoverPath;
  bool _playing = false;
  double _playhead = 0; // seconds; authoritative only while not [_playing]
  String? _selectedClipId;
  _TrimDrag? _trim;
  _TransformDrag? _transformDrag;
  _OverlayDrag? _overlayDrag;
  _MotionDrag? _motionDrag;

  // Overlay image bytes keyed by asset id (== clip.sourceId), loaded from
  // TimelineAssetRepository for existing overlays and cached in memory for
  // freshly added ones.
  Map<String, Uint8List> _overlayImages = {};

  // Chains outgoing timeline saves so a fast run of edits (e.g. a
  // drag-reorder immediately followed by a delete) can't overlap two
  // read-modify-write calls into TimelineRepository — an interleaved pair
  // could silently drop one edit on disk even though the UI shows both.
  Future<void> _saveChain = Future.value();

  @override
  void initState() {
    super.initState();
    widget.player.playing.addListener(_onPlayingChanged);
    _loadProjects();
  }

  @override
  void dispose() {
    widget.player.playing.removeListener(_onPlayingChanged);
    super.dispose();
  }

  /// The shared player moved on to a different track (this one finished, or
  /// something else started playing elsewhere) — stop ticking our playhead.
  void _onPlayingChanged() {
    if (_playing && widget.player.playing.value != _voiceoverPath) {
      if (mounted) setState(() => _playing = false);
    }
  }

  Future<void> _loadProjects() async {
    final projects = await widget.projects.load();
    if (!mounted) return;
    setState(() {
      _projects = projects;
      if (_projectId == null || !projects.any((p) => p.id == _projectId)) {
        _projectId = projects.isNotEmpty ? projects.first.id : null;
      }
    });
    await _loadForProject();
  }

  /// Refreshes the project list (e.g. after a project is created, renamed, or
  /// deleted elsewhere).
  Future<void> refreshProjects() => _loadProjects();

  /// Pauses voiceover playback in place — called when the user navigates
  /// away from this tab so audio doesn't keep running silently in the
  /// background.
  void pausePlayback() {
    if (!_playing) return;
    setState(() {
      _playhead = _effectivePlayhead(_timeline?.totalDuration ?? 0);
      _playing = false;
    });
    widget.player.pause();
  }

  void _pausePlaybackIfPlaying() {
    if (!_playing) return;
    _playhead = _effectivePlayhead(_timeline?.totalDuration ?? 0);
    _playing = false;
    widget.player.pause();
  }

  Future<void> _selectProject(String id) async {
    _pausePlaybackIfPlaying();
    setState(() => _projectId = id);
    await _loadForProject();
  }

  Future<void> _loadForProject() async {
    final projectId = _projectId;
    if (projectId == null) {
      setState(() {
        _sceneList = [];
        _sceneById = {};
        _timeline = null;
        _voiceoverPath = null;
        _selectedClipId = null;
        _playhead = 0;
        _trim = null;
        _transformDrag = null;
        _overlayDrag = null;
        _motionDrag = null;
        _overlayImages = {};
        _loading = false;
      });
      return;
    }
    setState(() => _loading = true);
    final scenes = await widget.scenes.listForProject(projectId);
    final thumbnails = <String, Uint8List>{};
    for (final s in scenes) {
      if (!s.hasImage) continue;
      final bytes = await widget.scenes.getSceneImage(s.id);
      if (bytes != null) thumbnails[s.id] = bytes;
    }
    var timeline = await widget.timelines.get(projectId);
    if (timeline == null && scenes.isNotEmpty) {
      timeline = seedTimelineFromScenes(projectId, scenes, 0);
      await widget.timelines.save(timeline);
    }
    String? voiceoverPath;
    if (scenes.isNotEmpty) {
      final galleryItems = await widget.gallery.load();
      GalleryItem? voiceClip;
      for (final c in galleryItems) {
        if (c.id == scenes.first.clipId) {
          voiceClip = c;
          break;
        }
      }
      if (voiceClip != null) voiceoverPath = await widget.gallery.filePath(voiceClip);
    }
    final overlayImages = <String, Uint8List>{};
    if (timeline != null) {
      for (final t in timeline.tracks) {
        if (!isOverlayTrack(timeline, t.id)) continue;
        for (final clip in t.clips) {
          final bytes = await widget.timelineAssets.get(clip.sourceId);
          if (bytes != null) overlayImages[clip.sourceId] = bytes;
        }
      }
    }
    if (!mounted || _projectId != projectId) return;
    setState(() {
      _sceneList = scenes;
      _sceneById = {for (final s in scenes) s.id: s};
      _thumbnails = thumbnails;
      _timeline = timeline;
      _voiceoverPath = voiceoverPath;
      _selectedClipId = null;
      _playhead = 0;
      _trim = null;
      _transformDrag = null;
      _overlayDrag = null;
      _motionDrag = null;
      _overlayImages = overlayImages;
      _loading = false;
    });
  }

  Future<void> _rebuildFromStoryboard() async {
    final projectId = _projectId;
    if (projectId == null || _sceneList.isEmpty || _busy) return;
    if (_timeline != null) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Rebuild the timeline from the storyboard?'),
          content: const Text(
            'The current timeline will be replaced — including any reframing, trims, and '
            'added overlays.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Rebuild')),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    _pausePlaybackIfPlaying();
    setState(() => _busy = true);
    try {
      final timeline = seedTimelineFromScenes(projectId, _sceneList, 0);
      final save = _saveChain.then((_) => widget.timelines.save(timeline));
      _saveChain = save;
      await save;
      if (mounted) {
        setState(() {
          _timeline = timeline;
          _selectedClipId = null;
          _playhead = 0;
          _trim = null;
          _transformDrag = null;
          _overlayDrag = null;
          _motionDrag = null;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export() async {
    final timeline = _timeline;
    final projectId = _projectId;
    if (timeline == null || projectId == null || _exporting) return;
    final voiceClipId = _sceneList.isNotEmpty ? _sceneList.first.clipId : null;
    if (voiceClipId == null) return;
    final galleryItems = await widget.gallery.load();
    GalleryItem? voiceClip;
    for (final c in galleryItems) {
      if (c.id == voiceClipId) {
        voiceClip = c;
        break;
      }
    }
    if (voiceClip == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('The voiceover clip for this storyboard is missing.')),
        );
      }
      return;
    }
    setState(() => _exporting = true);
    try {
      final assets = <String, Uint8List>{};
      assets[voiceoverAssetId] = await File(await widget.gallery.filePath(voiceClip)).readAsBytes();

      final photoTrack = baseVisualTrack(timeline);
      for (final clip in photoTrack?.clips ?? const []) {
        final scene = _sceneById[clip.sourceId];
        if (scene == null) continue;
        final image = scene.hasImage
            ? (_thumbnails[scene.id] ?? await widget.scenes.getSceneImage(scene.id))
            : null;
        assets[clip.sourceId] =
            await compositeFrame(image: image, narration: scene.narration, captions: false);
      }

      for (final t in timeline.tracks) {
        if (!isOverlayTrack(timeline, t.id)) continue;
        for (final clip in t.clips) {
          final bytes = _overlayImages[clip.sourceId] ?? await widget.timelineAssets.get(clip.sourceId);
          if (bytes != null) assets[clip.sourceId] = bytes;
        }
      }

      final captions = <String, Uint8List>{};
      final captionTrack = timeline.trackOfType(TrackType.caption);
      for (final clip in captionTrack?.clips ?? const []) {
        final text = clip.text?.trim();
        if (text == null || text.isEmpty) continue;
        captions[clip.id] = await renderCaptionOverlay(
          text,
          w: timeline.outputWidth.toDouble(),
          h: timeline.outputHeight.toDouble(),
        );
      }

      final mp4 = await widget.apiClient.renderTimeline(
        timeline: timeline,
        assets: assets,
        captions: captions,
      );
      final downloads = await getDownloadsDirectory();
      if (downloads == null) throw Exception('Downloads directory unavailable');
      var projectName = 'video';
      for (final p in _projects) {
        if (p.id == projectId) projectName = p.name;
      }
      final dest = File('${downloads.path}/${_slugify(projectName)}.mp4');
      await dest.writeAsBytes(mp4);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Exported to ${dest.path}')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e'), backgroundColor: context.brand.danger),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  // --- Playback -------------------------------------------------------

  /// The playhead position to render: live engine position while this
  /// track is actively playing, otherwise the last scrubbed/paused value.
  double _effectivePlayhead(double total) {
    final maxT = total > 0 ? total : 0.0;
    double v;
    if (_playing && _voiceoverPath != null && widget.player.playing.value == _voiceoverPath) {
      v = widget.player.position.value.inMilliseconds / 1000.0;
    } else {
      v = _playhead;
    }
    if (v < 0) return 0;
    if (v > maxT) return maxT;
    return v;
  }

  void _scrubTo(double seconds) {
    final total = _timeline?.totalDuration ?? 0;
    final maxT = total > 0 ? total : 0.0;
    final clamped = seconds < 0 ? 0.0 : (seconds > maxT ? maxT : seconds);
    setState(() => _playhead = clamped);
    if (_playing && _voiceoverPath != null) {
      widget.player.seek(Duration(milliseconds: (clamped * 1000).round()));
    }
  }

  Future<void> _togglePlay() async {
    final path = _voiceoverPath;
    final timeline = _timeline;
    if (path == null || timeline == null) return;
    if (_playing) {
      _playhead = _effectivePlayhead(timeline.totalDuration);
      await widget.player.pause();
      if (mounted) setState(() => _playing = false);
      return;
    }
    final total = timeline.totalDuration;
    final startAt = _playhead >= total ? 0.0 : _playhead;
    if (widget.player.playing.value == path) {
      await widget.player.resume();
    } else {
      await widget.player.play(path);
    }
    if (startAt > 0) {
      try {
        await widget.player.seek(Duration(milliseconds: (startAt * 1000).round()));
      } catch (_) {
        // Some platforms need the source ready before a seek lands — harmless to skip.
      }
    }
    if (mounted) {
      setState(() {
        _playing = true;
        _playhead = startAt;
      });
    }
  }

  // --- Editing ----------------------------------------------------------

  void _selectClip(String id, {bool forceSelect = false}) {
    setState(() {
      _selectedClipId = (!forceSelect && _selectedClipId == id) ? null : id;
      _transformDrag = null;
      _overlayDrag = null;
      _motionDrag = null;
    });
  }

  /// The currently selected clip, wherever it lives (base visual track or an
  /// overlay track), or null.
  TimelineClip? _selectedClip(Timeline timeline) {
    final id = _selectedClipId;
    if (id == null) return null;
    for (final t in timeline.tracks) {
      for (final c in t.clips) {
        if (c.id == id) return c;
      }
    }
    return null;
  }

  /// The track owning the currently selected clip, or null.
  Track? _selectedTrack(Timeline timeline) {
    final id = _selectedClipId;
    if (id == null) return null;
    for (final t in timeline.tracks) {
      if (t.clips.any((c) => c.id == id)) return t;
    }
    return null;
  }

  bool _selectedIsOverlay(Timeline timeline) {
    final track = _selectedTrack(timeline);
    return track != null && isOverlayTrack(timeline, track.id);
  }

  double _liveDuration(TimelineClip clip) {
    final trim = _trim;
    if (trim == null || trim.clipId != clip.id) return clip.duration;
    final deltaSeconds = trim.deltaPx / _pxPerSecond;
    final raw = trim.isStart ? trim.startDuration - deltaSeconds : trim.startDuration + deltaSeconds;
    return raw < minClipDuration ? minClipDuration : raw;
  }

  Future<void> _applyEdit(Timeline Function(Timeline) op) async {
    final current = _timeline;
    if (current == null) return;
    final next = op(current);
    if (!mounted) return;
    setState(() => _timeline = next);
    final save = _saveChain.then((_) => widget.timelines.save(next));
    _saveChain = save;
    await save;
  }

  Future<void> _onMoveClip(String draggedId, String targetId) async {
    _pausePlaybackIfPlaying();
    await _applyEdit((t) => moveClip(t, draggedId, targetId));
  }

  void _onTrimStart(TimelineClip clip, bool isStart) {
    _pausePlaybackIfPlaying();
    setState(() {
      _selectedClipId = clip.id;
      _trim = _TrimDrag(clipId: clip.id, isStart: isStart, startDuration: clip.duration);
      _transformDrag = null;
      _overlayDrag = null;
      _motionDrag = null;
    });
  }

  void _onTrimUpdate(String clipId, double deltaDx) {
    final trim = _trim;
    if (trim == null || trim.clipId != clipId) return;
    setState(() => trim.deltaPx += deltaDx);
  }

  Future<void> _onTrimEnd() async {
    final trim = _trim;
    if (trim == null) return;
    setState(() => _trim = null);
    final deltaSeconds = trim.deltaPx / _pxPerSecond;
    final raw = trim.isStart ? trim.startDuration - deltaSeconds : trim.startDuration + deltaSeconds;
    await _applyEdit((t) => trimClip(t, trim.clipId, raw));
  }

  Future<void> _split() async {
    final timeline = _timeline;
    final id = _selectedClipId;
    if (timeline == null || id == null) return;
    final clip = _selectedClip(timeline);
    if (clip == null) return;
    final local = _effectivePlayhead(timeline.totalDuration) - clip.startTime;
    if (local <= minClipDuration || local >= clip.duration - minClipDuration) return;
    _pausePlaybackIfPlaying();
    await _applyEdit((t) => splitClip(t, id, local));
    if (mounted) {
      setState(() {
        _selectedClipId = null;
        _transformDrag = null;
        _overlayDrag = null;
        _motionDrag = null;
      });
    }
  }

  Future<void> _delete() async {
    final timeline = _timeline;
    final id = _selectedClipId;
    if (timeline == null || id == null) return;
    final track = baseVisualTrack(timeline);
    if (track == null || track.clips.length <= 1) return;
    _pausePlaybackIfPlaying();
    await _applyEdit((t) => deleteClip(t, id));
    if (mounted) {
      setState(() {
        _selectedClipId = null;
        _transformDrag = null;
        _overlayDrag = null;
        _motionDrag = null;
      });
    }
  }

  Future<void> _removeOverlay(String trackId) async {
    await _applyEdit((t) => removeTrack(t, trackId));
    if (mounted) {
      setState(() {
        _selectedClipId = null;
        _transformDrag = null;
        _overlayDrag = null;
        _motionDrag = null;
      });
    }
  }

  // --- Reframe (crop/pan/zoom + tilt) ------------------------------------

  /// The zoom/pan/rotation to render for [clip] right now: the in-progress
  /// drag shadow if this clip is being adjusted, otherwise derived from its
  /// committed `crop`/`rotation`. The derived branch is defensively clamped
  /// (unlike the drag branch, which only ever holds values a `Slider` itself
  /// produced within its own min/max) since a `Slider.value` outside
  /// `[min,max]` throws.
  ({double zoom, double panX, double panY, double rotation}) _effectiveTransform(TimelineClip clip) {
    final drag = _transformDrag;
    if (drag != null && drag.clipId == clip.id) {
      return (zoom: drag.zoom, panX: drag.panX, panY: drag.panY, rotation: drag.rotation);
    }
    final zp = zoomPanFromCrop(clip.crop);
    return (
      zoom: _clampD(zp.zoom, 1, maxZoom),
      panX: _clampD(zp.panX, 0, 1),
      panY: _clampD(zp.panY, 0, 1),
      rotation: _clampD(clip.rotation ?? 0, -maxRotation, maxRotation),
    );
  }

  /// Starts (or continues) a reframe drag for [clip], seeding all four axes
  /// from its current committed transform the first time any slider moves.
  _TransformDrag _ensureDrag(TimelineClip clip) {
    var drag = _transformDrag;
    if (drag == null || drag.clipId != clip.id) {
      final zp = zoomPanFromCrop(clip.crop);
      drag = _TransformDrag(
        clipId: clip.id,
        zoom: _clampD(zp.zoom, 1, maxZoom),
        panX: _clampD(zp.panX, 0, 1),
        panY: _clampD(zp.panY, 0, 1),
        rotation: _clampD(clip.rotation ?? 0, -maxRotation, maxRotation),
      );
      _transformDrag = drag;
    }
    return drag;
  }

  void _onZoomChanged(TimelineClip clip, double v) => setState(() => _ensureDrag(clip).zoom = v);
  void _onPanXChanged(TimelineClip clip, double v) => setState(() => _ensureDrag(clip).panX = v);
  void _onPanYChanged(TimelineClip clip, double v) => setState(() => _ensureDrag(clip).panY = v);
  void _onRotationChanged(TimelineClip clip, double v) => setState(() => _ensureDrag(clip).rotation = v);

  /// Commits the in-progress drag shadow (if any) for [clip] to the
  /// timeline — zoom back to 1 clears the crop entirely, matching
  /// [setCrop]'s own full-frame-clears-to-null behavior. Crop/rotation edits
  /// never touch clip timing, so unlike the structural edits above this
  /// doesn't pause playback.
  Future<void> _commitTransform(TimelineClip clip) async {
    final drag = _transformDrag;
    if (drag == null || drag.clipId != clip.id) return;
    final crop = drag.zoom <= 1.001 ? null : cropFromZoomPan(drag.zoom, drag.panX, drag.panY);
    final rotation = drag.rotation;
    await _applyEdit((t) => setRotation(setCrop(t, clip.id, crop), clip.id, rotation));
    if (mounted) setState(() => _transformDrag = null);
  }

  Future<void> _resetFraming(TimelineClip clip) async {
    await _applyEdit((t) => setRotation(setCrop(t, clip.id, null), clip.id, null));
    if (mounted) setState(() => _transformDrag = null);
  }

  // --- Motion (Ken Burns pan/zoom) ----------------------------------------

  /// The Start/End keyframe values to render for [clip] right now: the
  /// in-progress drag shadow if this clip is being adjusted, otherwise
  /// derived from its committed `motion` (falling back to [defaultMotion] so
  /// the sliders have something sane to show the instant "Add motion" is
  /// tapped, before the first commit). Defensively clamped like
  /// [_effectiveTransform].
  ({double fromZoom, double fromPanX, double fromPanY, double toZoom, double toPanX, double toPanY})
      _effectiveMotion(TimelineClip clip) {
    final drag = _motionDrag;
    if (drag != null && drag.clipId == clip.id) {
      return (
        fromZoom: drag.fromZoom,
        fromPanX: drag.fromPanX,
        fromPanY: drag.fromPanY,
        toZoom: drag.toZoom,
        toPanX: drag.toPanX,
        toPanY: drag.toPanY,
      );
    }
    final m = clip.motion ?? defaultMotion;
    return (
      fromZoom: _clampD(m.from.zoom, 1, maxZoom),
      fromPanX: _clampD(m.from.panX, 0, 1),
      fromPanY: _clampD(m.from.panY, 0, 1),
      toZoom: _clampD(m.to.zoom, 1, maxZoom),
      toPanX: _clampD(m.to.panX, 0, 1),
      toPanY: _clampD(m.to.panY, 0, 1),
    );
  }

  /// Starts (or continues) a motion drag for [clip], seeding all six axes
  /// from its current committed (or default) motion the first time any
  /// slider moves.
  _MotionDrag _ensureMotionDrag(TimelineClip clip) {
    var drag = _motionDrag;
    if (drag == null || drag.clipId != clip.id) {
      final m = clip.motion ?? defaultMotion;
      drag = _MotionDrag(
        clipId: clip.id,
        fromZoom: _clampD(m.from.zoom, 1, maxZoom),
        fromPanX: _clampD(m.from.panX, 0, 1),
        fromPanY: _clampD(m.from.panY, 0, 1),
        toZoom: _clampD(m.to.zoom, 1, maxZoom),
        toPanX: _clampD(m.to.panX, 0, 1),
        toPanY: _clampD(m.to.panY, 0, 1),
      );
      _motionDrag = drag;
    }
    return drag;
  }

  void _onMotionFromZoomChanged(TimelineClip clip, double v) => setState(() => _ensureMotionDrag(clip).fromZoom = v);
  void _onMotionFromPanXChanged(TimelineClip clip, double v) => setState(() => _ensureMotionDrag(clip).fromPanX = v);
  void _onMotionFromPanYChanged(TimelineClip clip, double v) => setState(() => _ensureMotionDrag(clip).fromPanY = v);
  void _onMotionToZoomChanged(TimelineClip clip, double v) => setState(() => _ensureMotionDrag(clip).toZoom = v);
  void _onMotionToPanXChanged(TimelineClip clip, double v) => setState(() => _ensureMotionDrag(clip).toPanX = v);
  void _onMotionToPanYChanged(TimelineClip clip, double v) => setState(() => _ensureMotionDrag(clip).toPanY = v);

  /// Commits the in-progress motion drag shadow (if any) for [clip]. Doesn't
  /// pause playback — like crop/rotation, motion edits never touch clip
  /// timing.
  Future<void> _commitMotion(TimelineClip clip) async {
    final drag = _motionDrag;
    if (drag == null || drag.clipId != clip.id) return;
    final motion = Motion(
      from: KenBurnsKeyframe(zoom: drag.fromZoom, panX: drag.fromPanX, panY: drag.fromPanY),
      to: KenBurnsKeyframe(zoom: drag.toZoom, panX: drag.toPanX, panY: drag.toPanY),
    );
    await _applyEdit((t) => setMotion(t, clip.id, motion));
    if (mounted) setState(() => _motionDrag = null);
  }

  /// Enables motion on [clip] with [defaultMotion] — mirrors the web
  /// editor's "Add motion" chip.
  Future<void> _addMotion(TimelineClip clip) async {
    await _applyEdit((t) => setMotion(t, clip.id, defaultMotion));
    if (mounted) setState(() => _motionDrag = null);
  }

  Future<void> _removeMotion(TimelineClip clip) async {
    await _applyEdit((t) => setMotion(t, clip.id, null));
    if (mounted) setState(() => _motionDrag = null);
  }

  // --- Overlay (PiP/logo) layering ---------------------------------------

  /// The position/size to render for overlay [clip] right now — same
  /// drag-shadow-with-defensive-fallback-clamp shape as [_effectiveTransform].
  ({double x, double y, double scale}) _effectiveOverlay(TimelineClip clip) {
    final drag = _overlayDrag;
    if (drag != null && drag.clipId == clip.id) {
      return (x: drag.x, y: drag.y, scale: drag.scale);
    }
    return (
      x: _clampD(clip.position?.x ?? 0.62, 0, 1),
      y: _clampD(clip.position?.y ?? 0.04, 0, 1),
      scale: _clampD(clip.scale ?? 0.3, 0.1, 0.9),
    );
  }

  _OverlayDrag _ensureOverlayDrag(TimelineClip clip) {
    var drag = _overlayDrag;
    if (drag == null || drag.clipId != clip.id) {
      drag = _OverlayDrag(
        clipId: clip.id,
        x: _clampD(clip.position?.x ?? 0.62, 0, 1),
        y: _clampD(clip.position?.y ?? 0.04, 0, 1),
        scale: _clampD(clip.scale ?? 0.3, 0.1, 0.9),
      );
      _overlayDrag = drag;
    }
    return drag;
  }

  void _onOverlayXChanged(TimelineClip clip, double v) => setState(() => _ensureOverlayDrag(clip).x = v);
  void _onOverlayYChanged(TimelineClip clip, double v) => setState(() => _ensureOverlayDrag(clip).y = v);
  void _onOverlayScaleChanged(TimelineClip clip, double v) => setState(() => _ensureOverlayDrag(clip).scale = v);

  Future<void> _commitOverlay(TimelineClip clip) async {
    final drag = _overlayDrag;
    if (drag == null || drag.clipId != clip.id) return;
    await _applyEdit(
      (t) => setOverlayTransform(t, clip.id, position: NormalizedPoint(x: drag.x, y: drag.y), scale: drag.scale),
    );
    if (mounted) setState(() => _overlayDrag = null);
  }

  /// Picks an image file, registers it as a timeline asset, and adds it as a
  /// new overlay track spanning the current timeline length.
  Future<void> _addOverlay() async {
    if (_timeline == null) return;
    final result = await FilePicker.pickFiles(type: FileType.image);
    final path = result?.files.first.path;
    if (path == null) return;
    final bytes = await File(path).readAsBytes();
    final assetId = 'overlay-asset-${DateTime.now().millisecondsSinceEpoch}';
    await widget.timelineAssets.set(assetId, bytes);
    if (!mounted) return;
    setState(() => _overlayImages = {..._overlayImages, assetId: bytes});
    await _applyEdit((t) => addOverlayImage(t, assetId));
    if (mounted) {
      setState(() {
        _selectedClipId = 'overlay-$assetId';
        _transformDrag = null;
        _overlayDrag = null;
        _motionDrag = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.brand;
    if (_projects.isEmpty) {
      return _emptyState(
        icon: Icons.view_timeline_outlined,
        title: 'No projects yet',
        message: 'Create a project and build its storyboard first — the timeline is seeded from it.',
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final pad = constraints.maxWidth >= 780 ? 32.0 : 20.0;
        return Padding(
          padding: EdgeInsets.all(pad),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Timeline',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                  color: c.text,
                ),
              ),
              const SizedBox(height: 16),
              _topBar(),
              const SizedBox(height: 16),
              Expanded(child: _body()),
            ],
          ),
        );
      },
    );
  }

  Widget _topBar() {
    final c = context.brand;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final p in _projects)
              ChoiceChip(
                avatar: Icon(Icons.folder_outlined,
                    size: 15, color: _projectId == p.id ? c.blueDeep : c.text3),
                label: Text(p.name),
                selected: _projectId == p.id,
                showCheckmark: false,
                onSelected: (_) => _selectProject(p.id),
                backgroundColor: c.surface,
                selectedColor: c.blueDeep.withValues(alpha: 0.28),
                side: BorderSide(color: _projectId == p.id ? c.blueDeep : c.outline),
                labelStyle: TextStyle(
                  color: c.text,
                  fontWeight: _projectId == p.id ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
          ],
        ),
        if (_timeline != null) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : _rebuildFromStoryboard,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: Text(_busy ? 'Working…' : 'Rebuild from storyboard'),
              ),
              OutlinedButton.icon(
                onPressed: _addOverlay,
                icon: const Icon(Icons.image_outlined, size: 16),
                label: const Text('Add overlay'),
              ),
              FilledButton.icon(
                onPressed: _exporting ? null : _export,
                icon: const Icon(Icons.download_rounded, size: 16),
                label: Text(_exporting ? 'Rendering…' : 'Export mp4'),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final timeline = _timeline;
    if (timeline == null) {
      return _emptyState(
        icon: Icons.headphones_outlined,
        title: 'No storyboard yet',
        message: 'Build this project’s storyboard first (Storyboard tab) — the timeline seeds from it.',
      );
    }

    final photoTrack = baseVisualTrack(timeline);
    final audioTrack = timeline.trackOfType(TrackType.audio);
    final captionTrack = timeline.trackOfType(TrackType.caption);
    final overlayTracks = timeline.tracks.where((t) => isOverlayTrack(timeline, t.id)).toList();
    final total = timeline.totalDuration;
    final double totalWidth = (total * _pxPerSecond).clamp(200.0, double.infinity);
    final lanes = _buildLanes(photoTrack, overlayTracks, audioTrack, captionTrack, totalWidth);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${photoTrack?.clips.length ?? 0} scenes · ${_fmtTime(total)} total',
          style: AppFonts.monoStyle(size: 11.5, color: context.brand.text3),
        ),
        const SizedBox(height: 10),
        ValueListenableBuilder<Duration>(
          valueListenable: widget.player.position,
          builder: (context, _, _) {
            final playhead = _effectivePlayhead(total);
            final selected = _selectedClip(timeline);
            final selectedIsOverlay = _selectedIsOverlay(timeline);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _controlsRow(timeline, playhead),
                if (selected != null && !selectedIsOverlay) _transformInspector(selected),
                if (selected != null && selectedIsOverlay) _overlayInspector(selected),
              ],
            );
          },
        ),
        const SizedBox(height: 6),
        Text(
          'Tap a scene/overlay to select · drag a scene to reorder · drag its edges to trim · tap the ruler to scrub',
          style: AppFonts.monoStyle(size: 10.5, color: context.brand.text3),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: SingleChildScrollView(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _trackLabelGutter(lanes),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: ValueListenableBuilder<Duration>(
                      valueListenable: widget.player.position,
                      builder: (context, _, _) {
                        final playhead = _effectivePlayhead(total);
                        return _tracksContent(lanes, totalWidth, total, playhead);
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _controlsRow(Timeline timeline, double playhead) {
    final c = context.brand;
    final selected = _selectedClip(timeline);
    final selectedIsOverlay = _selectedIsOverlay(timeline);
    final selectedTrack = _selectedTrack(timeline);
    final photoTrack = baseVisualTrack(timeline);
    final localOffset = selected == null ? 0.0 : playhead - selected.startTime;
    final canSplit = selected != null &&
        !selectedIsOverlay &&
        localOffset > minClipDuration &&
        localOffset < selected.duration - minClipDuration;
    final canDeleteBase = selected != null && !selectedIsOverlay && (photoTrack?.clips.length ?? 0) > 1;
    final canRemoveOverlay = selected != null && selectedIsOverlay;
    final hasAudio = _voiceoverPath != null;

    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 10,
      runSpacing: 8,
      children: [
        _previewThumb(timeline, playhead),
        Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: hasAudio ? _togglePlay : null,
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                gradient: hasAudio ? c.sliderGradient : null,
                color: hasAudio ? null : c.outline,
                shape: BoxShape.circle,
              ),
              child: Icon(
                _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: Colors.white,
                size: 20,
              ),
            ),
          ),
        ),
        Text(
          '${_fmtTime(playhead)} / ${_fmtTime(timeline.totalDuration)}',
          style: AppFonts.monoStyle(size: 11.5, color: c.text3),
        ),
        OutlinedButton.icon(
          onPressed: canSplit ? _split : null,
          icon: const Icon(Icons.content_cut_rounded, size: 16),
          label: const Text('Split'),
        ),
        OutlinedButton.icon(
          onPressed: canRemoveOverlay ? () => _removeOverlay(selectedTrack!.id) : (canDeleteBase ? _delete : null),
          icon: const Icon(Icons.delete_outline_rounded, size: 16),
          label: Text(canRemoveOverlay ? 'Remove overlay' : 'Delete'),
        ),
        if (selected != null)
          Text(
            'Selected: ${_fmtTime(selected.duration)}',
            style: AppFonts.monoStyle(size: 11, color: c.text3),
          ),
      ],
    );
  }

  Widget _previewThumb(Timeline timeline, double playhead) {
    final c = context.brand;
    final clips = baseVisualTrack(timeline)?.clips ?? const <TimelineClip>[];
    TimelineClip? active;
    for (final clip in clips) {
      if (playhead >= clip.startTime && playhead < clip.startTime + clip.duration) {
        active = clip;
        break;
      }
    }
    active ??= clips.isNotEmpty ? clips.last : null;

    // While paused with a *base* photo clip selected, lock the preview to
    // that clip (not whatever's under the playhead) so reframe edits are
    // WYSIWYG — mirrors the web editor's stage. An overlay selection never
    // changes the background — it composites on top regardless of selection.
    final selected = _selectedClip(timeline);
    final selectedIsOverlay = _selectedIsOverlay(timeline);
    final previewClip = (!_playing && selected != null && !selectedIsOverlay) ? selected : active;

    final scene = previewClip == null ? null : _sceneById[previewClip.sourceId];
    final bytes = scene == null ? null : _thumbnails[scene.id];

    String? caption;
    for (final clip in timeline.trackOfType(TrackType.caption)?.clips ?? const <TimelineClip>[]) {
      if (playhead >= clip.startTime && playhead < clip.startTime + clip.duration) {
        caption = clip.text;
        break;
      }
    }

    Widget image = bytes != null
        ? Image.memory(bytes, fit: BoxFit.cover)
        : Center(child: Icon(Icons.image_outlined, size: 20, color: c.text3));
    if (bytes != null && previewClip != null) {
      if (previewClip.motion != null) {
        // Lerp the Ken Burns keyframe by the *actual* playhead position within
        // the clip (not just while selected+paused) so scrubbing shows the
        // animation — mirrors the web editor's stage.
        final m = _effectiveMotion(previewClip);
        final localT = previewClip.duration > 0
            ? _clampD((playhead - previewClip.startTime) / previewClip.duration, 0, 1)
            : 0.0;
        final zoom = m.fromZoom + (m.toZoom - m.fromZoom) * localT;
        final panX = m.fromPanX + (m.toPanX - m.fromPanX) * localT;
        final panY = m.fromPanY + (m.toPanY - m.fromPanY) * localT;
        if (zoom > 1.001) {
          image = Transform.scale(scale: zoom, alignment: FractionalOffset(panX, panY), child: image);
        }
      } else {
        final t = _effectiveTransform(previewClip);
        if (t.zoom > 1.001 || t.rotation.abs() > 0.01) {
          final origin = FractionalOffset(t.panX, t.panY);
          image = Transform.rotate(
            angle: t.rotation * math.pi / 180,
            alignment: origin,
            child: Transform.scale(scale: t.zoom, alignment: origin, child: image),
          );
        }
      }
    }

    // Every overlay clip active at the playhead, composited on top of the
    // background in track order — mirrors the compiler's zIndex ordering.
    final overlayWidgets = <Widget>[];
    for (final t in timeline.tracks) {
      if (!isOverlayTrack(timeline, t.id)) continue;
      for (final oc in t.clips) {
        if (playhead < oc.startTime || playhead >= oc.startTime + oc.duration) continue;
        final overlayBytes = _overlayImages[oc.sourceId];
        if (overlayBytes == null) continue;
        final ot = _effectiveOverlay(oc);
        overlayWidgets.add(
          Positioned(
            left: ot.x * _previewWidth,
            top: ot.y * _previewHeight,
            width: ot.scale * _previewWidth,
            child: Image.memory(overlayBytes, fit: BoxFit.contain),
          ),
        );
      }
    }

    return SizedBox(
      width: _previewWidth,
      height: _previewHeight,
      child: Container(
        decoration: BoxDecoration(
          color: c.surfaceMuted,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: c.outline),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            image,
            ...overlayWidgets,
            if (caption != null && caption.trim().isNotEmpty)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  color: Colors.black.withValues(alpha: 0.55),
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Text(
                    caption,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 9),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _transformInspector(TimelineClip clip) {
    final c = context.brand;
    final hasMotion = clip.motion != null;
    final hasFraming = clip.crop != null || clip.rotation != null;

    Widget row(String label, Widget slider, {String? value}) => Row(
          children: [
            SizedBox(
              width: 44,
              child: Text(label, style: TextStyle(fontSize: 11.5, color: c.text3)),
            ),
            Expanded(child: slider),
            if (value != null)
              SizedBox(
                width: 38,
                child: Text(
                  value,
                  textAlign: TextAlign.right,
                  style: AppFonts.monoStyle(size: 10.5, color: c.text3),
                ),
              ),
          ],
        );

    Widget keyframeBlock({
      required String label,
      required double zoom,
      required double panX,
      required double panY,
      required ValueChanged<double> onZoom,
      required ValueChanged<double> onPanX,
      required ValueChanged<double> onPanY,
    }) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(label, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: c.text3)),
              row(
                'Zoom',
                Slider(
                  min: 1,
                  max: maxZoom,
                  value: zoom,
                  onChanged: onZoom,
                  onChangeEnd: (_) => _commitMotion(clip),
                ),
                value: '${zoom.toStringAsFixed(2)}×',
              ),
              row(
                'Pan X',
                Slider(min: 0, max: 1, value: panX, onChanged: onPanX, onChangeEnd: (_) => _commitMotion(clip)),
              ),
              row(
                'Pan Y',
                Slider(min: 0, max: 1, value: panY, onChanged: onPanY, onChangeEnd: (_) => _commitMotion(clip)),
              ),
            ],
          ),
        );

    late final Widget body;
    if (hasMotion) {
      final m = _effectiveMotion(clip);
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          keyframeBlock(
            label: 'Start',
            zoom: m.fromZoom,
            panX: m.fromPanX,
            panY: m.fromPanY,
            onZoom: (v) => _onMotionFromZoomChanged(clip, v),
            onPanX: (v) => _onMotionFromPanXChanged(clip, v),
            onPanY: (v) => _onMotionFromPanYChanged(clip, v),
          ),
          keyframeBlock(
            label: 'End',
            zoom: m.toZoom,
            panX: m.toPanX,
            panY: m.toPanY,
            onZoom: (v) => _onMotionToZoomChanged(clip, v),
            onPanX: (v) => _onMotionToPanXChanged(clip, v),
            onPanY: (v) => _onMotionToPanYChanged(clip, v),
          ),
        ],
      );
    } else {
      final t = _effectiveTransform(clip);
      final panEnabled = t.zoom > 1.001;
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          row(
            'Zoom',
            Slider(
              min: 1,
              max: maxZoom,
              value: t.zoom,
              onChanged: (v) => _onZoomChanged(clip, v),
              onChangeEnd: (_) => _commitTransform(clip),
            ),
            value: '${t.zoom.toStringAsFixed(2)}×',
          ),
          row(
            'Pan X',
            Slider(
              min: 0,
              max: 1,
              value: t.panX,
              onChanged: panEnabled ? (v) => _onPanXChanged(clip, v) : null,
              onChangeEnd: panEnabled ? (_) => _commitTransform(clip) : null,
            ),
          ),
          row(
            'Pan Y',
            Slider(
              min: 0,
              max: 1,
              value: t.panY,
              onChanged: panEnabled ? (v) => _onPanYChanged(clip, v) : null,
              onChangeEnd: panEnabled ? (_) => _commitTransform(clip) : null,
            ),
          ),
          row(
            'Tilt',
            Slider(
              min: -maxRotation,
              max: maxRotation,
              value: t.rotation,
              onChanged: (v) => _onRotationChanged(clip, v),
              onChangeEnd: (_) => _commitTransform(clip),
            ),
            value: '${t.rotation.toStringAsFixed(0)}°',
          ),
        ],
      );
    }

    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      decoration: BoxDecoration(
        color: c.surfaceMuted,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                hasMotion ? 'Motion' : 'Reframe',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: c.text),
              ),
              const Spacer(),
              TextButton(
                onPressed: hasMotion ? () => _removeMotion(clip) : (hasFraming ? () => _resetFraming(clip) : null),
                child: Text(hasMotion ? 'Remove motion' : 'Reset framing'),
              ),
            ],
          ),
          body,
          if (!hasMotion)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _addMotion(clip),
                icon: const Icon(Icons.videocam_outlined, size: 16),
                label: const Text('Add motion'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _overlayInspector(TimelineClip clip) {
    final c = context.brand;
    final o = _effectiveOverlay(clip);

    Widget row(String label, Widget slider) => Row(
          children: [
            SizedBox(
              width: 44,
              child: Text(label, style: TextStyle(fontSize: 11.5, color: c.text3)),
            ),
            Expanded(child: slider),
          ],
        );

    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      decoration: BoxDecoration(
        color: c.surfaceMuted,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Overlay', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: c.text)),
          row(
            'Pos X',
            Slider(
              min: 0,
              max: 1,
              value: o.x,
              onChanged: (v) => _onOverlayXChanged(clip, v),
              onChangeEnd: (_) => _commitOverlay(clip),
            ),
          ),
          row(
            'Pos Y',
            Slider(
              min: 0,
              max: 1,
              value: o.y,
              onChanged: (v) => _onOverlayYChanged(clip, v),
              onChangeEnd: (_) => _commitOverlay(clip),
            ),
          ),
          row(
            'Size',
            Slider(
              min: 0.1,
              max: 0.9,
              value: o.scale,
              onChanged: (v) => _onOverlayScaleChanged(clip, v),
              onChangeEnd: (_) => _commitOverlay(clip),
            ),
          ),
        ],
      ),
    );
  }

  /// One lane row (label + fixed height + content builder). The gutter and
  /// the scrolling tracks column both iterate the same list so a label can
  /// never drift out of sync with its lane.
  Widget _trackLabelGutter(List<_Lane> lanes) {
    final c = context.brand;
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: SizedBox(
        width: 62,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: _rulerHeight + 6),
            for (var i = 0; i < lanes.length; i++) ...[
              SizedBox(
                height: lanes[i].height,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    lanes[i].label,
                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: c.text3),
                  ),
                ),
              ),
              if (i < lanes.length - 1) const SizedBox(height: _laneGap),
            ],
          ],
        ),
      ),
    );
  }

  Widget _tracksContent(List<_Lane> lanes, double totalWidth, double total, double playhead) {
    return SizedBox(
      width: totalWidth,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ruler(total, totalWidth),
              const SizedBox(height: 6),
              for (var i = 0; i < lanes.length; i++) ...[
                lanes[i].build(),
                if (i < lanes.length - 1) const SizedBox(height: _laneGap),
              ],
            ],
          ),
          if (total > 0)
            Positioned(
              left: (playhead * _pxPerSecond) - 0.75,
              top: 0,
              bottom: 0,
              child: IgnorePointer(
                child: Container(width: 1.5, color: context.brand.blueDeep),
              ),
            ),
        ],
      ),
    );
  }

  /// Photo lane, one lane per overlay track (in track-list order), Audio
  /// lane, Caption lane — built once per [_body] call and shared by
  /// [_trackLabelGutter] and [_tracksContent].
  List<_Lane> _buildLanes(
    Track? photoTrack,
    List<Track> overlayTracks,
    Track? audioTrack,
    Track? captionTrack,
    double laneWidth,
  ) {
    return [
      _Lane(label: 'Photo', height: 96, build: () => _photoLane(photoTrack, laneWidth)),
      for (final t in overlayTracks)
        _Lane(label: 'Overlay', height: 44, build: () => _overlayLane(t, laneWidth)),
      _Lane(
        label: 'Audio',
        height: 44,
        build: () => _trackStack(clips: audioTrack?.clips ?? const [], height: 44, builder: _audioClipBox),
      ),
      _Lane(
        label: 'Text',
        height: 34,
        build: () => _trackStack(clips: captionTrack?.clips ?? const [], height: 34, builder: _captionClipBox),
      ),
    ];
  }

  Widget _ruler(double total, double width) {
    final c = context.brand;
    final step = _tickStep(total);
    final ticks = <double>[];
    for (var t = 0.0; t <= total + 0.001; t += step) {
      ticks.add(t);
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) => _scrubTo(d.localPosition.dx / _pxPerSecond),
      onHorizontalDragUpdate: (d) => _scrubTo(d.localPosition.dx / _pxPerSecond),
      child: SizedBox(
        width: width,
        height: _rulerHeight,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            for (final t in ticks)
              Positioned(
                left: t * _pxPerSecond,
                top: 2,
                child: Text(_fmtTime(t), style: AppFonts.monoStyle(size: 9, color: c.text3)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _photoLane(Track? track, double laneWidth) {
    final clips = track?.clips ?? const <TimelineClip>[];
    return SizedBox(
      height: 96,
      width: laneWidth,
      child: Stack(
        clipBehavior: Clip.none,
        children: [for (final clip in clips) _photoClipBox(clip)],
      ),
    );
  }

  /// An overlay track's single clip — tap-to-select only; no drag-to-reorder
  /// or trim in this phase (see the plan's scope notes).
  Widget _overlayLane(Track track, double laneWidth) {
    final c = context.brand;
    if (track.clips.isEmpty) return SizedBox(height: 44, width: laneWidth);
    final clip = track.clips.first;
    final selected = _selectedClipId == clip.id;
    return SizedBox(
      height: 44,
      width: laneWidth,
      child: Stack(
        children: [
          Positioned(
            left: clip.startTime * _pxPerSecond,
            width: clip.duration * _pxPerSecond,
            top: 0,
            bottom: 0,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: GestureDetector(
                onTap: () => _selectClip(clip.id),
                child: Container(
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: c.pink.withValues(alpha: selected ? 0.32 : 0.18),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: selected ? c.blueDeep : c.pink.withValues(alpha: 0.5),
                      width: selected ? 2 : 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.image_outlined, size: 14, color: c.text2),
                      const SizedBox(width: 6),
                      const Flexible(
                        child: Text('Overlay', overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _photoClipBox(TimelineClip clip) {
    final c = context.brand;
    final selected = _selectedClipId == clip.id;
    final liveDuration = _liveDuration(clip);
    final left = clip.startTime * _pxPerSecond;
    final width = liveDuration * _pxPerSecond;
    final scene = _sceneById[clip.sourceId];
    final bytes = scene == null ? null : _thumbnails[scene.id];

    Widget box = Container(
      decoration: BoxDecoration(
        color: c.surfaceMuted,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: selected ? c.blueDeep : c.outline, width: selected ? 2 : 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (bytes != null)
            Image.memory(bytes, fit: BoxFit.cover)
          else
            Center(child: Icon(Icons.image_outlined, size: 18, color: c.text3)),
          Positioned(
            left: 4,
            bottom: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                _fmtTime(liveDuration),
                style: AppFonts.monoStyle(size: 9.5, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );

    box = GestureDetector(onTap: () => _selectClip(clip.id), child: box);

    box = DragTarget<String>(
      onWillAcceptWithDetails: (details) => details.data != clip.id,
      onAcceptWithDetails: (details) => _onMoveClip(details.data, clip.id),
      builder: (context, candidateData, rejectedData) {
        final isDropTarget = candidateData.isNotEmpty;
        return Container(
          decoration: isDropTarget
              ? BoxDecoration(border: Border.all(color: c.pink, width: 2), borderRadius: BorderRadius.circular(8))
              : null,
          child: box,
        );
      },
    );

    box = LongPressDraggable<String>(
      data: clip.id,
      axis: Axis.horizontal,
      feedback: Material(
        color: Colors.transparent,
        child: Opacity(opacity: 0.75, child: SizedBox(width: width, height: 96, child: box)),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: box),
      onDragStarted: () => _selectClip(clip.id, forceSelect: true),
      child: box,
    );

    return Positioned(
      key: ValueKey(clip.id),
      left: left,
      top: 0,
      bottom: 0,
      width: width,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(child: box),
            if (selected) _trimHandle(clip, isStart: true),
            if (selected) _trimHandle(clip, isStart: false),
          ],
        ),
      ),
    );
  }

  Widget _trimHandle(TimelineClip clip, {required bool isStart}) {
    final c = context.brand;
    return Positioned(
      left: isStart ? 0 : null,
      right: isStart ? null : 0,
      top: 0,
      bottom: 0,
      width: 12,
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeLeftRight,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (_) => _onTrimStart(clip, isStart),
          onHorizontalDragUpdate: (d) => _onTrimUpdate(clip.id, d.delta.dx),
          onHorizontalDragEnd: (_) => _onTrimEnd(),
          child: Center(
            child: Container(
              width: 3,
              height: 28,
              decoration: BoxDecoration(color: c.blueDeep, borderRadius: BorderRadius.circular(2)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _trackStack({
    required List<TimelineClip> clips,
    required double height,
    required Widget Function(TimelineClip) builder,
  }) {
    return SizedBox(
      height: height,
      child: Stack(
        children: [
          for (final clip in clips)
            Positioned(
              left: clip.startTime * _pxPerSecond,
              width: clip.duration * _pxPerSecond,
              top: 0,
              bottom: 0,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: builder(clip),
              ),
            ),
        ],
      ),
    );
  }

  Widget _audioClipBox(TimelineClip clip) {
    final c = context.brand;
    return Container(
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: c.blueDeep.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.blueDeep.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.graphic_eq_rounded, size: 15, color: c.blueDeep),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              'Voiceover · ${_fmtTime(clip.duration)}',
              overflow: TextOverflow.ellipsis,
              style: AppFonts.monoStyle(size: 11, color: c.blueDeep),
            ),
          ),
        ],
      ),
    );
  }

  Widget _captionClipBox(TimelineClip clip) {
    final c = context.brand;
    final text = clip.text?.trim();
    if (text == null || text.isEmpty) return const SizedBox.shrink();
    return Container(
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: c.pink.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: c.text2),
      ),
    );
  }

  Widget _emptyState({required IconData icon, required String title, required String message}) {
    final c = context.brand;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 52, color: c.blueDeep),
            const SizedBox(height: 16),
            Text(
              title,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: c.text),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: c.text3),
            ),
          ],
        ),
      ),
    );
  }
}
