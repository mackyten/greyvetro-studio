import { useCallback, useEffect, useRef, useState } from 'react';
import { Icon } from '../../core/Icon';
import { VOICEOVER_ASSET_ID } from './model/seed';
import {
  cropFromZoomPan,
  DEFAULT_MOTION,
  deleteClip,
  isFirstBaseClip,
  isLastBaseClip,
  isOverlayTrack,
  MAX_ROTATION,
  MAX_ZOOM,
  maxTransitionDuration,
  MIN_CLIP,
  MIN_TRANSITION,
  moveClip,
  removeTrack,
  setClipFade,
  setClipTransition,
  setCrop,
  setFadeToBlack,
  setMotion,
  setOverlayTransform,
  setRotation,
  setTrackAudio,
  setVideoAudio,
  splitClip,
  trimClip,
  zoomPanFromCrop,
} from './model/timelineOps';
import type { Clip, KenBurns, Timeline, Track, TrackType, TransitionStyle } from './model/types';
import { timelineDuration } from './model/types';

/** Lane display order (top → bottom) and labels. */
const LANE_ORDER: TrackType[] = ['video', 'photo', 'caption', 'audio'];
const LANE_LABEL: Record<TrackType, string> = {
  video: 'Video',
  photo: 'Photo',
  caption: 'Captions',
  audio: 'Audio',
};

/** Zoom bounds (pixels per timeline second) and the pointer-drag snap threshold in screen px. */
const MIN_PPS = 20;
const MAX_PPS = 400;
const DEFAULT_PPS = 70;
const SNAP_PX = 8;

/** Widest fade-in-from-black / fade-out-to-black the edge-fade sliders allow, in seconds. */
const MAX_EDGE_FADE = 5;

function fmt(seconds: number): string {
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60);
  return `${m}:${s.toString().padStart(2, '0')}`;
}

function tickStep(total: number): number {
  if (total <= 15) return 2;
  if (total <= 40) return 5;
  if (total <= 90) return 10;
  return 15;
}

const isVisualType = (t: TrackType) => t === 'photo' || t === 'video';

/** Transient trim gesture state (committed on pointer-up). */
interface TrimDrag {
  clipId: string;
  edge: 'start' | 'end';
  startX: number;
  laneWidth: number;
  clipStart: number;
  startDuration: number;
  startInPoint: number;
  duration: number;
  inPoint: number;
}

/**
 * Interactive timeline (Greyvetro Studio Phase 5/6). Each track is a lane, each clip a bar. Base
 * visual clips can be selected, dragged to reorder, trimmed at either edge (snapping to nearby
 * clip edges/the playhead), split at the playhead, reframed (zoom/pan/tilt/motion), given a
 * crossfade from the clip before them, and deleted; the model stays contiguous (the base track is
 * a `concat`, or an `xfade` fold where transitions are set). A zoom control scales the ruler/lanes
 * (pixels-per-second) with independent horizontal scroll, labels pinned. Overlay (PiP/logo) tracks
 * — a photo/video track above the base zIndex, Phase 3c — float freely: one clip, end-trim only,
 * positioned/scaled via its own inspector, like music. Edits are pure (see model/timelineOps.ts)
 * and flow up via onChange for persistence + render; onUndo/onRedo drive the caller's history stack.
 */
export function TimelineEditor({
  timeline,
  imageUrls,
  videoUrls,
  audioUrl,
  onChange,
  onChangeLive,
  onCommitDrag,
  canUndo,
  canRedo,
  onUndo,
  onRedo,
}: {
  timeline: Timeline;
  imageUrls: Record<string, string>;
  /** Raw video blob URLs (keyed by MediaAsset id) — separate from `imageUrls`' poster frames,
   * lets the preview show real frame-accurate video instead of a static thumbnail. */
  videoUrls: Record<string, string>;
  audioUrl: string | null;
  onChange: (next: Timeline) => void;
  /** One tick of a continuous slider drag: live preview update only, no history entry (see
   * useTimelineHistory's setLive) — paired with onCommitDrag on pointerup. */
  onChangeLive: (next: Timeline) => void;
  /** Ends a slider drag gesture, coalescing every onChangeLive tick since it started into a single
   * undo step and persisting the result. */
  onCommitDrag: () => void;
  canUndo: boolean;
  canRedo: boolean;
  onUndo: () => void;
  onRedo: () => void;
}) {
  const total = Math.max(timelineDuration(timeline), 0.001);
  const [selected, setSelected] = useState<string | null>(null);
  const [selectedTransition, setSelectedTransition] = useState<string | null>(null);
  const [playhead, setPlayhead] = useState(0);
  const [dropTarget, setDropTarget] = useState<string | null>(null);
  const [trim, setTrim] = useState<TrimDrag | null>(null);
  const [snapGuide, setSnapGuide] = useState<number | null>(null);
  const [playing, setPlaying] = useState(false);
  const [pxPerSecond, setPxPerSecond] = useState(DEFAULT_PPS);
  const dragId = useRef<string | null>(null);
  const audioElRef = useRef<HTMLAudioElement | null>(null);
  const scrollRef = useRef<HTMLDivElement | null>(null);
  const rafRef = useRef<number | null>(null);
  const clockRef = useRef<{ t0: number; p0: number } | null>(null);

  const ph = Math.min(playhead, total);
  const pxWidth = Math.max(320, total * pxPerSecond);

  const zoomBy = (factor: number) =>
    setPxPerSecond((p) => Math.min(MAX_PPS, Math.max(MIN_PPS, p * factor)));
  const zoomToFit = () => {
    const width = scrollRef.current?.clientWidth ?? 800;
    setPxPerSecond(Math.min(MAX_PPS, Math.max(MIN_PPS, width / total)));
  };

  // Playback: a rAF clock advances the playhead (master), the voiceover follows, and the frame
  // preview swaps stills as `ph` moves. Video clips render as real <video> (see VideoFrame below),
  // seeked/played in sync with the playhead — frame-accurate when paused/scrubbing, loosely
  // resynced during playback rather than reseeked every tick (avoids seek-induced stutter). Motion
  // (Ken Burns) stays an export-only concern for stills. Manual scrubs/edits stop playback.
  const stop = useCallback(() => {
    setPlaying(false);
    if (rafRef.current != null) cancelAnimationFrame(rafRef.current);
    rafRef.current = null;
    clockRef.current = null;
    audioElRef.current?.pause();
  }, []);

  useEffect(() => stop, [stop]);

  const togglePlay = () => {
    if (playing) {
      stop();
      return;
    }
    const startAt = ph >= total ? 0 : ph;
    setPlayhead(startAt);
    const audio = audioElRef.current;
    if (audio) {
      try {
        audio.currentTime = startAt;
      } catch {
        /* metadata not ready yet — play() will start from 0 */
      }
      void audio.play().catch(() => {});
    }
    clockRef.current = { t0: performance.now(), p0: startAt };
    setPlaying(true);
    const tick = () => {
      const c = clockRef.current;
      if (!c) return;
      const np = c.p0 + (performance.now() - c.t0) / 1000;
      if (np >= total) {
        setPlayhead(total);
        stop();
        return;
      }
      setPlayhead(np);
      rafRef.current = requestAnimationFrame(tick);
    };
    rafRef.current = requestAnimationFrame(tick);
  };

  const scrubTo = (t: number) => {
    stop();
    setPlayhead(t);
  };

  const tracks = [...timeline.tracks].sort(
    (a, b) => LANE_ORDER.indexOf(a.type) - LANE_ORDER.indexOf(b.type),
  );
  const overlay = (trackId: string) => isOverlayTrack(timeline, trackId);

  // Flattened BASE visual clips in play order (drives the background preview + the "keep at least
  // one" guard). Overlay (PiP/logo) clips are excluded — they composite on top, not as the frame.
  const visualClips = timeline.tracks
    .filter((t) => isVisualType(t.type) && !overlay(t.id))
    .flatMap((t) => t.clips)
    .sort((a, b) => a.startTime - b.startTime);
  const visualCount = visualClips.length;

  const selectedClip = selected
    ? timeline.tracks.flatMap((t) => t.clips).find((c) => c.id === selected) ?? null
    : null;
  const selTrack = selected
    ? timeline.tracks.find((t) => t.clips.some((c) => c.id === selected)) ?? null
    : null;
  const selectedIsVisual = !!selectedClip && !!selTrack && isVisualType(selTrack.type) && !overlay(selTrack.id);
  const selectedIsVideo = selectedIsVisual && selTrack?.type === 'video';
  const localPlayhead = selectedClip ? ph - selectedClip.startTime : 0;

  // A selected music clip (an audio clip that isn't the seeded voiceover) opens the audio inspector.
  const selMusic =
    selTrack && selectedClip && selTrack.type === 'audio' && selectedClip.sourceId !== VOICEOVER_ASSET_ID
      ? { track: selTrack, clip: selectedClip }
      : null;
  // A selected overlay (PiP/logo) clip opens the position/scale inspector.
  const selOverlay =
    selTrack && selectedClip && isVisualType(selTrack.type) && overlay(selTrack.id)
      ? { track: selTrack, clip: selectedClip }
      : null;

  // A selected transition boundary (Phase 6) opens the transition inspector.
  const transitionClip = selectedTransition
    ? timeline.tracks.flatMap((t) => t.clips).find((c) => c.id === selectedTransition) ?? null
    : null;
  const transitionMax = selectedTransition ? maxTransitionDuration(timeline, selectedTransition) : 0;

  const canSplit =
    selectedIsVisual && localPlayhead > MIN_CLIP && localPlayhead < (selectedClip?.duration ?? 0) - MIN_CLIP;
  const canDelete = (selectedIsVisual && visualCount > 1) || !!selMusic || !!selOverlay;

  const onDelete = () => {
    if (!selected) return;
    if (selMusic) {
      stop();
      onChange(removeTrack(timeline, selMusic.track.id));
      setSelected(null);
    } else if (selOverlay) {
      stop();
      onChange(removeTrack(timeline, selOverlay.track.id));
      setSelected(null);
    } else if (selectedIsVisual && visualCount > 1) {
      stop();
      onChange(deleteClip(timeline, selected));
      setSelected(null);
    }
  };
  // Keep the key handler calling the latest onDelete without re-subscribing on every render.
  const onDeleteRef = useRef(onDelete);
  onDeleteRef.current = onDelete;

  // Selecting a clip doesn't otherwise move the playhead, but Split is gated on the playhead
  // sitting inside the *selected* clip's own range (see canSplit below) — so without this, Split
  // silently stays disabled for any clip the playhead isn't already parked in. That's easy to miss
  // for the first (base) clip, which starts at t=0 and so often already contains a resting/leftover
  // playhead position, but not for anything selected further down the timeline (e.g. a video clip
  // appended after it) — reproduced live: selecting such a clip and hitting Split (button or `S`)
  // was a silent no-op. Snap the playhead into the clip whenever it isn't already validly inside.
  const selectClip = (id: string) => {
    setSelectedTransition(null);
    setSelected(id);
    const clip = timeline.tracks.flatMap((t) => t.clips).find((c) => c.id === id);
    if (!clip) return;
    const lo = clip.startTime + MIN_CLIP;
    const hi = clip.startTime + clip.duration - MIN_CLIP;
    if (lo < hi && (ph <= lo || ph >= hi)) {
      stop();
      setPlayhead(clip.startTime + clip.duration / 2);
    }
  };
  const selectTransition = (id: string) => {
    setSelected(null);
    setSelectedTransition(id);
  };

  // Frame shown in the preview: the base visual clip under the playhead, plus any active caption.
  // While paused with a base clip selected, the preview locks to that clip so reframe edits are
  // WYSIWYG. Overlay (PiP/logo) clips active at the playhead composite on top, positioned/scaled.
  const activeVisual = visualClips.find((c) => ph >= c.startTime && ph < c.startTime + c.duration)
    ?? visualClips[visualClips.length - 1];
  const previewClip = !playing && selectedIsVisual && selectedClip ? selectedClip : activeVisual;
  const previewIsVideo = !!previewClip && timeline.assets.find((a) => a.id === previewClip.sourceId)?.type === 'video';
  const previewVideoUrl = previewClip && previewIsVideo ? videoUrls[previewClip.sourceId] : undefined;
  const activeCaption = timeline.tracks
    .find((t) => t.type === 'caption')
    ?.clips.find((c) => ph >= c.startTime && ph < c.startTime + c.duration)?.text;
  const activeOverlays = timeline.tracks
    .filter((t) => isVisualType(t.type) && overlay(t.id))
    .flatMap((t) => t.clips)
    .filter((c) => ph >= c.startTime && ph < c.startTime + c.duration);

  // Reflect a clip's crop/reframe + tilt (or, for a motion clip, the Ken Burns keyframe lerped to
  // the current playhead position within it) in the preview via CSS — approximate, the exact
  // source-crop cover-fit + auto-zoomed rotation/zoompan happens at export; §4 preview is for
  // feedback, not pixel parity. Motion takes precedence, mirroring the compiler (ZoompanChain
  // ignores static Crop/Rotation on an animated clip).
  const previewTransform: string[] = [];
  let transformOriginPct = { x: 50, y: 50 };
  if (previewClip?.motion) {
    const localT =
      previewClip.duration > 0
        ? Math.min(Math.max((ph - previewClip.startTime) / previewClip.duration, 0), 1)
        : 0;
    const { from, to } = previewClip.motion;
    const zoom = from.zoom + (to.zoom - from.zoom) * localT;
    const panX = from.panX + (to.panX - from.panX) * localT;
    const panY = from.panY + (to.panY - from.panY) * localT;
    if (zoom > 1.001) previewTransform.push(`scale(${zoom.toFixed(4)})`);
    transformOriginPct = { x: panX * 100, y: panY * 100 };
  } else {
    if (previewClip?.crop) previewTransform.push(`scale(${(1 / previewClip.crop.width).toFixed(4)})`);
    if (previewClip?.rotation) previewTransform.push(`rotate(${previewClip.rotation}deg)`);
    if (previewClip?.crop)
      transformOriginPct = {
        x: (previewClip.crop.x + previewClip.crop.width / 2) * 100,
        y: (previewClip.crop.y + previewClip.crop.height / 2) * 100,
      };
  }
  const cropStyle = previewTransform.length
    ? {
        transform: previewTransform.join(' '),
        transformOrigin: `${transformOriginPct.x.toFixed(2)}% ${transformOriginPct.y.toFixed(2)}%`,
      }
    : undefined;

  // Reframe inspector state for a selected visual clip (zoom + pan-center <-> the stored crop rect).
  const zoomPan = selectedIsVisual && selectedClip ? zoomPanFromCrop(selectedClip.crop) : null;
  // Discrete edits commit immediately; a continuous slider drag passes live=true to update the
  // preview only (paired with onCommitDrag on pointerup) — see useTimelineHistory's setLive.
  const applyEdit = (next: Timeline, live?: boolean) => {
    if (live) onChangeLive(next);
    else onChange(next);
  };
  const applyCrop = (zoom: number, panX: number, panY: number, live?: boolean) => {
    if (!selectedClip) return;
    // Zoom back to 1 clears the crop (full frame); otherwise store the derived rect.
    applyEdit(setCrop(timeline, selectedClip.id, zoom <= 1.001 ? null : cropFromZoomPan(zoom, panX, panY)), live);
  };
  const applyRotation = (degrees: number, live?: boolean) => {
    if (!selectedClip) return;
    applyEdit(setRotation(timeline, selectedClip.id, degrees), live);
  };
  const applyMotion = (patch: { from?: Partial<KenBurns>; to?: Partial<KenBurns> }, live?: boolean) => {
    if (!selectedClip?.motion) return;
    applyEdit(
      setMotion(timeline, selectedClip.id, {
        from: { ...selectedClip.motion.from, ...patch.from },
        to: { ...selectedClip.motion.to, ...patch.to },
      }),
      live,
    );
  };
  const applyOverlayTransform = (
    patch: { position?: { x: number; y: number }; scale?: number },
    live?: boolean,
  ) => {
    if (!selOverlay) return;
    applyEdit(setOverlayTransform(timeline, selOverlay.clip.id, patch), live);
  };
  const applyVideoAudio = (
    patch: { includeAudio?: boolean; volume?: number; fadeIn?: number; fadeOut?: number },
    live?: boolean,
  ) => {
    if (!selectedClip) return;
    applyEdit(setVideoAudio(timeline, selectedClip.id, patch), live);
  };
  const applyTransition = (style: TransitionStyle, duration: number, live?: boolean) => {
    if (!transitionClip) return;
    applyEdit(setClipTransition(timeline, transitionClip.id, { style, duration }), live);
  };
  const applyFadeToBlack = (patch: { fadeInFromBlack?: number; fadeOutToBlack?: number }, live?: boolean) => {
    if (!selectedClip) return;
    applyEdit(setFadeToBlack(timeline, selectedClip.id, patch), live);
  };

  // Split / delete / undo-redo keyboard shortcuts.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.target as HTMLElement)?.tagName?.match(/INPUT|TEXTAREA/)) return;
      if (e.key === 'Escape') {
        setSelected(null);
        setSelectedTransition(null);
      } else if ((e.key === 'Delete' || e.key === 'Backspace') && canDelete) {
        e.preventDefault();
        onDeleteRef.current();
      } else if ((e.key === 's' || e.key === 'S') && canSplit && selected) {
        e.preventDefault();
        stop();
        onChange(splitClip(timeline, selected, localPlayhead));
      } else if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'z') {
        e.preventDefault();
        stop();
        if (e.shiftKey) {
          if (canRedo) onRedo();
        } else if (canUndo) onUndo();
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [timeline, selected, canDelete, canSplit, localPlayhead, onChange, stop, canUndo, canRedo, onUndo, onRedo]);

  const timeFromEvent = (e: { clientX: number }, el: HTMLElement): number => {
    const rect = el.getBoundingClientRect();
    return Math.min(Math.max(((e.clientX - rect.left) / rect.width) * total, 0), total);
  };

  // Snap candidates for a trim drag: timeline bounds, the playhead, and every OTHER clip's start/
  // end across all tracks. Returns the nearest candidate within the pixel threshold, else null.
  const snapCandidate = (t: number, excludeClipId: string): number | null => {
    const thresholdSec = SNAP_PX / pxPerSecond;
    const candidates = [0, total, ph];
    for (const track of timeline.tracks)
      for (const c of track.clips) {
        if (c.id === excludeClipId) continue;
        candidates.push(c.startTime, c.startTime + c.duration);
      }
    let best: number | null = null;
    let bestDist = thresholdSec;
    for (const c of candidates) {
      const d = Math.abs(c - t);
      if (d <= bestDist) {
        best = c;
        bestDist = d;
      }
    }
    return best;
  };

  const onTrimPointerMove = (e: React.PointerEvent) => {
    if (!trim) return;
    const dt = ((e.clientX - trim.startX) / trim.laneWidth) * total;
    const rawEdge = trim.edge === 'end' ? trim.clipStart + trim.startDuration + dt : trim.clipStart + dt;
    const snapped = snapCandidate(rawEdge, trim.clipId);
    setSnapGuide(snapped);
    const edge = snapped ?? rawEdge;

    if (trim.edge === 'end') {
      setTrim({ ...trim, duration: Math.max(MIN_CLIP, edge - trim.clipStart) });
    } else {
      // Left edge: keep the right edge fixed — shrink/grow duration, move the source window.
      const snappedDt = edge - trim.clipStart;
      setTrim({
        ...trim,
        duration: Math.max(MIN_CLIP, trim.startDuration - snappedDt),
        inPoint: Math.max(0, trim.startInPoint + snappedDt),
      });
    }
  };

  const onTrimPointerUp = () => {
    if (trim) onChange(trimClip(timeline, trim.clipId, { inPoint: trim.inPoint, duration: trim.duration }));
    setTrim(null);
    setSnapGuide(null);
  };

  const step = tickStep(total);
  const ticks: number[] = [];
  for (let t = 0; t <= total + 0.001; t += step) ticks.push(t);

  return (
    <div className="tl card" onPointerMove={onTrimPointerMove} onPointerUp={onTrimPointerUp}>
      <audio ref={audioElRef} src={audioUrl ?? undefined} preload="auto" />

      <div className="tl-topbar">
        <div className="tl-tools-row">
          <button className="chip" disabled={!canUndo} onClick={() => { stop(); onUndo(); }}>
            <Icon name="undo" /> Undo
          </button>
          <button className="chip" disabled={!canRedo} onClick={() => { stop(); onRedo(); }}>
            <Icon name="redo" /> Redo
          </button>
        </div>
        <div className="tl-topbar-sep" />
        <div className="tl-tools-row">
          <button className="chip" onClick={() => zoomBy(1 / 1.4)}>
            <Icon name="zoom_out" />
          </button>
          <span className="mono tl-zoom-label">{Math.round(pxPerSecond)}px/s</span>
          <button className="chip" onClick={() => zoomBy(1.4)}>
            <Icon name="zoom_in" />
          </button>
          <button className="chip" onClick={zoomToFit}>
            Fit
          </button>
        </div>
      </div>

      <div className="tl-main">
        <div className="tl-stage">
          <div className="tl-preview" aria-hidden>
            {previewClip && previewIsVideo && previewVideoUrl ? (
              <VideoFrame clip={previewClip} src={previewVideoUrl} ph={ph} playing={playing} style={cropStyle} />
            ) : previewClip && imageUrls[previewClip.sourceId] ? (
              <img src={imageUrls[previewClip.sourceId]} alt="" style={cropStyle} />
            ) : (
              <div className="tl-preview-empty">
                <Icon name="movie" />
              </div>
            )}
            {activeOverlays.map((c) => {
              const overlayIsVideo = timeline.assets.find((a) => a.id === c.sourceId)?.type === 'video';
              const overlaySrc = overlayIsVideo ? videoUrls[c.sourceId] : imageUrls[c.sourceId];
              if (!overlaySrc) return null;
              const overlayStyle = {
                left: `${(c.position?.x ?? 0) * 100}%`,
                top: `${(c.position?.y ?? 0) * 100}%`,
                width: `${(c.scale ?? 0.3) * 100}%`,
              };
              return overlayIsVideo ? (
                <VideoFrame
                  key={c.id}
                  clip={c}
                  src={overlaySrc}
                  ph={ph}
                  playing={playing}
                  className="tl-preview-overlay"
                  style={overlayStyle}
                />
              ) : (
                <img key={c.id} className="tl-preview-overlay" src={overlaySrc} alt="" style={overlayStyle} />
              );
            })}
            {activeCaption && <div className="tl-preview-caption">{activeCaption}</div>}
          </div>

          <div className="tl-stage-controls">
            <button className="chip" onClick={togglePlay}>
              <Icon name={playing ? 'pause' : 'play_arrow'} /> {playing ? 'Pause' : 'Play'}
            </button>
            <div className="tl-tools-meta mono">
              {ph.toFixed(1)}s / {total.toFixed(1)}s
              {selectedClip && (selectedIsVisual || selMusic || selOverlay) && (
                <> · selected {selectedClip.duration.toFixed(1)}s</>
              )}
            </div>
          </div>
        </div>

        <div className="tl-inspector">
          {selMusic ? (
            <div className="tl-audio-inspector">
              <label>
                Vol
                <input
                  type="range"
                  min={0}
                  max={1}
                  step={0.05}
                  value={selMusic.track.volume ?? 1}
                  onChange={(e) =>
                    onChangeLive(setTrackAudio(timeline, selMusic.track.id, { volume: Number(e.target.value) }))
                  }
                  onPointerUp={onCommitDrag}
                />
                <span className="mono">{Math.round((selMusic.track.volume ?? 1) * 100)}%</span>
              </label>
              <label className="tl-check">
                <input
                  type="checkbox"
                  checked={!!selMusic.track.muted}
                  onChange={(e) =>
                    onChange(setTrackAudio(timeline, selMusic.track.id, { muted: e.target.checked }))
                  }
                />
                Mute
              </label>
              <label>
                Fade in
                <input
                  type="number"
                  min={0}
                  step={0.5}
                  value={selMusic.clip.fadeIn ?? 0}
                  onChange={(e) =>
                    onChange(setClipFade(timeline, selMusic.clip.id, { fadeIn: Math.max(0, Number(e.target.value)) }))
                  }
                />
              </label>
              <label>
                Fade out
                <input
                  type="number"
                  min={0}
                  step={0.5}
                  value={selMusic.clip.fadeOut ?? 0}
                  onChange={(e) =>
                    onChange(setClipFade(timeline, selMusic.clip.id, { fadeOut: Math.max(0, Number(e.target.value)) }))
                  }
                />
              </label>
            </div>
          ) : zoomPan && selectedClip?.motion ? (
            <div className="tl-transform-inspector">
              <div className="tl-motion-keyframe">
                <span className="tl-motion-label">Start</span>
                <label>
                  Zoom
                  <input
                    type="range"
                    min={1}
                    max={MAX_ZOOM}
                    step={0.05}
                    value={selectedClip.motion.from.zoom}
                    onChange={(e) => applyMotion({ from: { zoom: Number(e.target.value) } }, true)}
                    onPointerUp={onCommitDrag}
                  />
                  <span className="mono">{selectedClip.motion.from.zoom.toFixed(2)}×</span>
                </label>
                <label>
                  Pan X
                  <input
                    type="range"
                    min={0}
                    max={1}
                    step={0.02}
                    value={selectedClip.motion.from.panX}
                    onChange={(e) => applyMotion({ from: { panX: Number(e.target.value) } }, true)}
                    onPointerUp={onCommitDrag}
                  />
                </label>
                <label>
                  Pan Y
                  <input
                    type="range"
                    min={0}
                    max={1}
                    step={0.02}
                    value={selectedClip.motion.from.panY}
                    onChange={(e) => applyMotion({ from: { panY: Number(e.target.value) } }, true)}
                    onPointerUp={onCommitDrag}
                  />
                </label>
              </div>
              <div className="tl-motion-keyframe">
                <span className="tl-motion-label">End</span>
                <label>
                  Zoom
                  <input
                    type="range"
                    min={1}
                    max={MAX_ZOOM}
                    step={0.05}
                    value={selectedClip.motion.to.zoom}
                    onChange={(e) => applyMotion({ to: { zoom: Number(e.target.value) } }, true)}
                    onPointerUp={onCommitDrag}
                  />
                  <span className="mono">{selectedClip.motion.to.zoom.toFixed(2)}×</span>
                </label>
                <label>
                  Pan X
                  <input
                    type="range"
                    min={0}
                    max={1}
                    step={0.02}
                    value={selectedClip.motion.to.panX}
                    onChange={(e) => applyMotion({ to: { panX: Number(e.target.value) } }, true)}
                    onPointerUp={onCommitDrag}
                  />
                </label>
                <label>
                  Pan Y
                  <input
                    type="range"
                    min={0}
                    max={1}
                    step={0.02}
                    value={selectedClip.motion.to.panY}
                    onChange={(e) => applyMotion({ to: { panY: Number(e.target.value) } }, true)}
                    onPointerUp={onCommitDrag}
                  />
                </label>
              </div>
              <button className="chip" onClick={() => onChange(setMotion(timeline, selectedClip.id, null))}>
                Remove motion
              </button>
            </div>
          ) : zoomPan && selectedClip ? (
            <div className="tl-transform-inspector">
              <label>
                Zoom
                <input
                  type="range"
                  min={1}
                  max={MAX_ZOOM}
                  step={0.05}
                  value={zoomPan.zoom}
                  onChange={(e) => applyCrop(Number(e.target.value), zoomPan.panX, zoomPan.panY, true)}
                  onPointerUp={onCommitDrag}
                />
                <span className="mono">{zoomPan.zoom.toFixed(2)}×</span>
              </label>
              <label>
                Pan X
                <input
                  type="range"
                  min={0}
                  max={1}
                  step={0.02}
                  value={zoomPan.panX}
                  disabled={zoomPan.zoom <= 1.001}
                  onChange={(e) => applyCrop(zoomPan.zoom, Number(e.target.value), zoomPan.panY, true)}
                  onPointerUp={onCommitDrag}
                />
              </label>
              <label>
                Pan Y
                <input
                  type="range"
                  min={0}
                  max={1}
                  step={0.02}
                  value={zoomPan.panY}
                  disabled={zoomPan.zoom <= 1.001}
                  onChange={(e) => applyCrop(zoomPan.zoom, zoomPan.panX, Number(e.target.value), true)}
                  onPointerUp={onCommitDrag}
                />
              </label>
              <label>
                Tilt
                <input
                  type="range"
                  min={-MAX_ROTATION}
                  max={MAX_ROTATION}
                  step={1}
                  value={selectedClip.rotation ?? 0}
                  onChange={(e) => applyRotation(Number(e.target.value), true)}
                  onPointerUp={onCommitDrag}
                />
                <span className="mono">{(selectedClip.rotation ?? 0).toFixed(0)}°</span>
              </label>
              <button
                className="chip"
                disabled={!selectedClip.crop && !selectedClip.rotation}
                onClick={() => {
                  onChange(setCrop(timeline, selectedClip.id, null));
                  applyRotation(0);
                }}
              >
                Reset framing
              </button>
              <button className="chip" onClick={() => onChange(setMotion(timeline, selectedClip.id, DEFAULT_MOTION))}>
                <Icon name="videocam" /> Add motion
              </button>
              {isFirstBaseClip(timeline, selectedClip.id) && (
                <label>
                  Fade in from black
                  <input
                    type="range"
                    min={0}
                    max={MAX_EDGE_FADE}
                    step={0.1}
                    value={selectedClip.fadeInFromBlack ?? 0}
                    onChange={(e) => applyFadeToBlack({ fadeInFromBlack: Number(e.target.value) }, true)}
                    onPointerUp={onCommitDrag}
                  />
                  <span className="mono">{(selectedClip.fadeInFromBlack ?? 0).toFixed(1)}s</span>
                </label>
              )}
              {isLastBaseClip(timeline, selectedClip.id) && (
                <label>
                  Fade out to black
                  <input
                    type="range"
                    min={0}
                    max={MAX_EDGE_FADE}
                    step={0.1}
                    value={selectedClip.fadeOutToBlack ?? 0}
                    onChange={(e) => applyFadeToBlack({ fadeOutToBlack: Number(e.target.value) }, true)}
                    onPointerUp={onCommitDrag}
                  />
                  <span className="mono">{(selectedClip.fadeOutToBlack ?? 0).toFixed(1)}s</span>
                </label>
              )}
              {selectedIsVideo && (
                <>
                  <label className="tl-check">
                    <input
                      type="checkbox"
                      checked={!!selectedClip.includeAudio}
                      onChange={(e) => applyVideoAudio({ includeAudio: e.target.checked })}
                    />
                    Include this clip's audio
                  </label>
                  {selectedClip.includeAudio && (
                    <>
                      <label>
                        Vol
                        <input
                          type="range"
                          min={0}
                          max={1}
                          step={0.05}
                          value={selectedClip.volume ?? 1}
                          onChange={(e) => applyVideoAudio({ volume: Number(e.target.value) }, true)}
                          onPointerUp={onCommitDrag}
                        />
                        <span className="mono">{Math.round((selectedClip.volume ?? 1) * 100)}%</span>
                      </label>
                      <label>
                        Fade in
                        <input
                          type="number"
                          min={0}
                          step={0.5}
                          value={selectedClip.fadeIn ?? 0}
                          onChange={(e) => applyVideoAudio({ fadeIn: Math.max(0, Number(e.target.value)) })}
                        />
                      </label>
                      <label>
                        Fade out
                        <input
                          type="number"
                          min={0}
                          step={0.5}
                          value={selectedClip.fadeOut ?? 0}
                          onChange={(e) => applyVideoAudio({ fadeOut: Math.max(0, Number(e.target.value)) })}
                        />
                      </label>
                    </>
                  )}
                </>
              )}
            </div>
          ) : selOverlay ? (
            <div className="tl-transform-inspector">
              <label>
                Pos X
                <input
                  type="range"
                  min={0}
                  max={1}
                  step={0.02}
                  value={selOverlay.clip.position?.x ?? 0}
                  onChange={(e) =>
                    applyOverlayTransform(
                      { position: { x: Number(e.target.value), y: selOverlay.clip.position?.y ?? 0 } },
                      true,
                    )
                  }
                  onPointerUp={onCommitDrag}
                />
              </label>
              <label>
                Pos Y
                <input
                  type="range"
                  min={0}
                  max={1}
                  step={0.02}
                  value={selOverlay.clip.position?.y ?? 0}
                  onChange={(e) =>
                    applyOverlayTransform(
                      { position: { x: selOverlay.clip.position?.x ?? 0, y: Number(e.target.value) } },
                      true,
                    )
                  }
                  onPointerUp={onCommitDrag}
                />
              </label>
              <label>
                Size
                <input
                  type="range"
                  min={0.1}
                  max={0.9}
                  step={0.02}
                  value={selOverlay.clip.scale ?? 0.3}
                  onChange={(e) => applyOverlayTransform({ scale: Number(e.target.value) }, true)}
                  onPointerUp={onCommitDrag}
                />
                <span className="mono">{Math.round((selOverlay.clip.scale ?? 0.3) * 100)}%</span>
              </label>
            </div>
          ) : transitionClip ? (
            <div className="tl-transition-inspector">
              {transitionMax < MIN_TRANSITION ? (
                <span className="tl-tools-hint">These clips are too short to fit a transition.</span>
              ) : (
                <>
                  <div className="tl-transition-styles">
                    <button
                      className={`chip${(transitionClip.transitionIn?.style ?? 'dissolve') === 'dissolve' && transitionClip.transitionIn ? ' active' : ''}`}
                      onClick={() =>
                        applyTransition('dissolve', transitionClip.transitionIn?.duration ?? Math.min(0.5, transitionMax))
                      }
                    >
                      Dissolve
                    </button>
                    <button
                      className={`chip${transitionClip.transitionIn?.style === 'fadeToBlack' ? ' active' : ''}`}
                      onClick={() =>
                        applyTransition('fadeToBlack', transitionClip.transitionIn?.duration ?? Math.min(0.5, transitionMax))
                      }
                    >
                      Fade to black
                    </button>
                  </div>
                  <label>
                    Duration
                    <input
                      type="range"
                      min={MIN_TRANSITION}
                      max={transitionMax}
                      step={0.05}
                      value={Math.min(transitionClip.transitionIn?.duration ?? Math.min(0.5, transitionMax), transitionMax)}
                      onChange={(e) =>
                        applyTransition(transitionClip.transitionIn?.style ?? 'dissolve', Number(e.target.value), true)
                      }
                      onPointerUp={onCommitDrag}
                    />
                    <span className="mono">
                      {Math.min(transitionClip.transitionIn?.duration ?? Math.min(0.5, transitionMax), transitionMax).toFixed(2)}s
                    </span>
                  </label>
                  <button
                    className="chip"
                    disabled={!transitionClip.transitionIn}
                    onClick={() => onChange(setClipTransition(timeline, transitionClip.id, null))}
                  >
                    Remove transition
                  </button>
                </>
              )}
            </div>
          ) : (
            <div className="tl-tools-hint">
              Click a clip to select · drag to reorder · drag an edge to trim (snaps to nearby
              edges/playhead) · click the ruler to move the playhead, then Split (S) or Delete ·
              Cmd/Ctrl+Z to undo. Select a scene to reframe (zoom/pan/tilt) or add Ken Burns motion;
              click the boundary between two clips for a transition; add music or an overlay, select
              it to adjust.
            </div>
          )}
        </div>
      </div>

      <div className="tl-tracks-panel">
        <div className="tl-tools-row tl-tracks-header">
          <button
            className="chip"
            disabled={!canSplit}
            onClick={() => {
              if (selected) {
                stop();
                onChange(splitClip(timeline, selected, localPlayhead));
              }
            }}
          >
            <Icon name="content_cut" /> Split
          </button>
          <button className="chip" disabled={!canDelete} onClick={onDelete}>
            <Icon name="delete" /> {selMusic ? 'Remove music' : selOverlay ? 'Remove overlay' : 'Delete'}
          </button>
        </div>

        <div className="tl-body">
        <div className="tl-labels">
          <div className="tl-ruler-spacer" />
          {tracks.map((track) => (
            <div key={track.id} className="tl-lane-label">
              {overlay(track.id) ? (
                <>
                  <Icon name="image" /> Overlay
                </>
              ) : (
                LANE_LABEL[track.type]
              )}
            </div>
          ))}
        </div>

        <div className="tl-scroll" ref={scrollRef}>
          <div
            className="tl-ruler"
            style={{ width: pxWidth }}
            onPointerDown={(e) => scrubTo(timeFromEvent(e, e.currentTarget))}
          >
            {ticks.map((t) => (
              <span key={t} className="tl-tick mono" style={{ left: `${(t / total) * 100}%` }}>
                {fmt(t)}
              </span>
            ))}
            <div className="tl-playhead" style={{ left: `${(ph / total) * 100}%` }} />
          </div>

          {tracks.map((track) => {
            const base = isVisualType(track.type) && !overlay(track.id);
            const sortedClips = [...track.clips].sort((a, b) => a.startTime - b.startTime);
            return (
              <div
                key={track.id}
                className="tl-lane-track"
                style={{ width: pxWidth }}
                onPointerDown={(e) => {
                  // Only bare-track clicks (not on a clip/badge) move the playhead.
                  if (e.target === e.currentTarget) scrubTo(timeFromEvent(e, e.currentTarget));
                }}
              >
                <div className="tl-playhead" style={{ left: `${(ph / total) * 100}%` }} />
                {snapGuide != null && trim?.clipId && sortedClips.some((c) => c.id === trim.clipId) && (
                  <div className="tl-snap-guide" style={{ left: `${(snapGuide / total) * 100}%` }} />
                )}
                {sortedClips.map((clip, i) => (
                  <ClipBar
                    key={clip.id}
                    clip={clip}
                    index={i}
                    track={track}
                    overlay={overlay(track.id)}
                    total={total}
                    thumb={imageUrls[clip.sourceId]}
                    selected={selected === clip.id}
                    dropTarget={dropTarget === clip.id}
                    trim={trim?.clipId === clip.id ? trim : null}
                    onSelect={() => selectClip(clip.id)}
                    onDragStart={() => {
                      if (isVisualType(track.type) && !overlay(track.id)) dragId.current = clip.id;
                    }}
                    onDragOver={() => {
                      if (dragId.current && dragId.current !== clip.id) setDropTarget(clip.id);
                    }}
                    onDrop={() => {
                      if (dragId.current && dragId.current !== clip.id) {
                        stop();
                        onChange(moveClip(timeline, dragId.current, clip.id));
                      }
                      dragId.current = null;
                      setDropTarget(null);
                    }}
                    onTrimStart={(edge, e) => {
                      e.stopPropagation();
                      e.preventDefault();
                      stop();
                      selectClip(clip.id);
                      const lane = (e.currentTarget as HTMLElement).closest('.tl-lane-track');
                      setTrim({
                        clipId: clip.id,
                        edge,
                        startX: e.clientX,
                        laneWidth: lane?.getBoundingClientRect().width ?? 1,
                        clipStart: clip.startTime,
                        startDuration: clip.duration,
                        startInPoint: clip.inPoint,
                        duration: clip.duration,
                        inPoint: clip.inPoint,
                      });
                    }}
                  />
                ))}
                {base &&
                  sortedClips.slice(1).map((clip) => {
                    const max = maxTransitionDuration(timeline, clip.id);
                    if (max < MIN_TRANSITION) return null;
                    return (
                      <button
                        key={`xf-${clip.id}`}
                        type="button"
                        className={`tl-transition-badge${clip.transitionIn ? ' active' : ''}${selectedTransition === clip.id ? ' selected' : ''}`}
                        style={{ left: `${(clip.startTime / total) * 100}%` }}
                        title={
                          clip.transitionIn
                            ? `${clip.transitionIn.style === 'fadeToBlack' ? 'Fade to black' : 'Dissolve'} · ${clip.transitionIn.duration.toFixed(2)}s`
                            : 'Add a transition'
                        }
                        onClick={(e) => {
                          e.stopPropagation();
                          selectTransition(clip.id);
                        }}
                      >
                        <Icon name="swap_horiz" />
                      </button>
                    );
                  })}
              </div>
            );
          })}
        </div>
      </div>
      </div>
    </div>
  );
}

/**
 * A real `<video>` preview for a video-sourced clip, seeked/played to track the shared playhead —
 * replaces the static poster the preview used to show for video clips. Muted (the preview mixes no
 * audio; that's an export-only concern handled by `includeAudio`). Paused/scrubbing seeks exactly
 * (frame-accurate); during playback it lets the video's own clock run and only resyncs past a
 * drift threshold, so scrubbing doesn't fight a reseek every rAF tick.
 */
function VideoFrame({
  clip,
  src,
  ph,
  playing,
  className,
  style,
}: {
  clip: Clip;
  src: string;
  ph: number;
  playing: boolean;
  className?: string;
  style?: React.CSSProperties;
}) {
  const ref = useRef<HTMLVideoElement | null>(null);
  useEffect(() => {
    const video = ref.current;
    if (!video) return;
    const localT = Math.min(Math.max(ph - clip.startTime, 0), Math.max(clip.duration - 0.001, 0));
    const sourceT = clip.inPoint + localT;
    if (playing) {
      if (video.paused) {
        video.currentTime = sourceT;
        void video.play().catch(() => {});
      } else if (Math.abs(video.currentTime - sourceT) > 0.3) {
        video.currentTime = sourceT;
      }
    } else {
      if (!video.paused) video.pause();
      if (Math.abs(video.currentTime - sourceT) > 0.03) video.currentTime = sourceT;
    }
  }, [clip, ph, playing]);
  return <video ref={ref} src={src} className={className} style={style} muted playsInline preload="auto" />;
}

function ClipBar({
  clip,
  index,
  track,
  overlay,
  total,
  thumb,
  selected,
  dropTarget,
  trim,
  onSelect,
  onDragStart,
  onDragOver,
  onDrop,
  onTrimStart,
}: {
  clip: Clip;
  index: number;
  track: Track;
  /** True when this clip's track is an overlay (PiP/logo) layer, not the base concat. */
  overlay: boolean;
  total: number;
  thumb?: string;
  selected: boolean;
  dropTarget: boolean;
  trim: TrimDrag | null;
  onSelect: () => void;
  onDragStart: () => void;
  onDragOver: () => void;
  onDrop: () => void;
  onTrimStart: (edge: 'start' | 'end', e: React.PointerEvent) => void;
}) {
  // Part of the contiguous base concat (reorderable, trims both edges) — as opposed to an
  // overlay clip, which floats freely and only trims its end (like music).
  const base = isVisualType(track.type) && !overlay;
  const music = track.type === 'audio' && clip.sourceId !== VOICEOVER_ASSET_ID;
  const editable = base || overlay || music;
  const duration = trim ? trim.duration : clip.duration;
  const left = (clip.startTime / total) * 100;
  const width = (duration / total) * 100;
  const label = overlay
    ? 'Overlay'
    : track.type === 'caption'
      ? clip.text ?? ''
      : track.type === 'audio'
        ? music
          ? 'Music'
          : 'Voiceover'
        : track.type === 'video'
          ? `Video ${index + 1}`
          : `Scene ${index + 1}`;
  const labelIcon = overlay
    ? 'image'
    : track.type === 'audio'
      ? music
        ? 'music_note'
        : null
      : track.type === 'video'
        ? 'movie'
        : null;

  return (
    <div
      className={`tl-clip tl-clip-${track.type}${music ? ' tl-clip-music' : ''}${overlay ? ' tl-clip-overlay' : ''}${selected ? ' selected' : ''}${dropTarget ? ' drop-target' : ''}${editable ? ' editable' : ''}`}
      style={{ left: `${left}%`, width: `${width}%` }}
      title={`${label} · ${fmt(clip.startTime)}–${fmt(clip.startTime + duration)}`}
      draggable={base}
      onClick={() => editable && onSelect()}
      onDragStart={onDragStart}
      onDragOver={(e) => {
        if (base) {
          e.preventDefault();
          onDragOver();
        }
      }}
      onDrop={(e) => {
        if (base) {
          e.preventDefault();
          onDrop();
        }
      }}
    >
      {(base || overlay) && thumb && <img src={thumb} alt="" />}
      <span className="tl-clip-label">
        {labelIcon && <Icon name={labelIcon} />} {label}
      </span>
      {/* Stills/video trim at both edges; music/overlay only at the end (anchored at t=0). */}
      {base && selected && (
        <span className="tl-trim tl-trim-start" onPointerDown={(e) => onTrimStart('start', e)} />
      )}
      {editable && selected && (
        <span className="tl-trim tl-trim-end" onPointerDown={(e) => onTrimStart('end', e)} />
      )}
    </div>
  );
}
