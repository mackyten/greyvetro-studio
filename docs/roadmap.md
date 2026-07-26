# Greyvetro Studio — Roadmap (shipped history)

Full, dated ship-log for Greyvetro Studio. Linked from the main
**[CLAUDE.md](../CLAUDE.md)** to keep that file lean — read this when you
need the history behind a specific decision (why a phase was scoped the way
it was, what was deferred and why, what was verified and how).

For **current/open work**, see **[TASKS.md](../TASKS.md)** instead — this
file is a historical record of what shipped, not a backlog. Finished
`TASKS.md` items are archived in `FINISHED.TASKS.md`, not folded back into
this file.

---

## Roadmap

1. ✅ **Free voices only** — `GetVoicesAsync` returns premade (free) + cloned; picker has search + gender filter, plus manual refresh (refresh button, pull-to-refresh, and retry-on-error) to re-fetch the list, e.g. after upgrading a plan or cloning a voice (`voices_screen.dart`, `voice_model.dart` parses labels).
2. ✅ **Use my own voice** — `CreateVoiceScreen` (opened via "Create my voice" in the picker): record (package `record`) or upload (`file_picker`) samples → `POST /voices/clone` (multipart) → returned voice is selected and shows under "My Voices". Warns if `usage.canCloneVoices` is false. macOS mic + user-selected-file entitlements added; `NSMicrophoneUsageDescription` set. Requires a paid ElevenLabs plan to actually clone. Note: the upload picker uses `FileType.custom` with an explicit `allowedExtensions` list (`m4a, mp3, wav, …`) — `FileType.audio` greys out `.m4a` on macOS (the format the in-app recorder produces).
3. ✅ **Credit tracking** — backend `GET /usage` (subscription endpoint); `UsageBadge` in the **sidebar footer** (sidebar-card variant; remaining credits + gradient bar; refreshes after each generation via the composer's `onGenerated` callback).
4. ✅ **Modern brand UI** — `core/theme.dart` palette (grey / baby blue / baby pink); all screens restyled.
5. ✅ **Local gallery** — `GalleryRepository` persists audio + metadata under app documents dir; `GalleryScreen` (Gallery tab) replays, shows text, edit & regenerate, export, delete. Shared `AudioPlayer` (`core/audio_player.dart`). Navigation via `HomeShell`.
6. ✅ **Desktop UI/UX overhaul** — full redesign from a Claude Design spec, built in 6 phases. **Left sidebar** nav replaces the bottom bar (`features/home/app_sidebar.dart`; responsive labelled 212px / 64px icon rail, hosts logo + nav + credit card + theme toggle). Composer is the **"1a Studio"** editor-forward layout (big script editor + right rail: voice / collapsible settings / gradient Generate / result), reflows to one column below 880px. Gallery & Presets use a **responsive masonry grid** (3/2/1-up). Voice Picker is a shared **centered modal** (`features/voices/voice_picker.dart`, used by composer + preset editor). Create-my-voice & preset editor restyled. `AudioScrubber` has a gradient seek track. Manrope/JetBrains Mono fonts; **dark mode** throughout.

7. **Greyvetro Studio — multimedia creation tool** (in progress) — see
   [docs/multimedia-studio-plan.md](multimedia-studio-plan.md) for the full
   plan: rename → STT endpoint (ElevenLabs Scribe) → Claude script/scene
   generation → storyboard UI on top of Projects → ffmpeg render.
   - ✅ **Phase 1 — STT**: `POST /stt` (multipart audio → ElevenLabs Scribe
     `scribe_v1`, word-level timestamps; Scribe is called through a typed
     `HttpClient` in `ElevenLabsService` because the SDK has no STT endpoint).
     Web gallery cards have a "📝 Transcribe" chip; the transcript persists on
     the `GalleryItem` in IndexedDB (no version bump needed) and opens in
     `features/stt/TranscriptModal.tsx` (text / word-timings views, copy).
     The ElevenLabs API key must have the **`speech_to_text` permission**
     (scoped keys return 401 `missing_permissions` otherwise) — enabled on the
     current key 2026-07-17; verified end-to-end with word timestamps.
   - ✅ **Phase 2 — Script generation (Gemini, not Anthropic)**: the plan's
     Anthropic-API choice was superseded 2026-07-17 (user wanted a free tier).
     `POST /script` (topic → TTS-ready script) and `POST /script/scenes`
     (transcript → scene JSON via Gemini structured output) call
     `generateContent` on **`gemini-flash-latest`** (`GEMINI_MODEL` overrides;
     use the rolling alias — pinned versions like `gemini-2.5-flash` get
     retired for new API keys, returning 404)
     through a named `HttpClient` in `Greyvetro.Infrastructure/Gemini/GeminiService.cs`.
     Verified end-to-end 2026-07-17: topic → script → `/tts` voiceover →
     `/stt` transcript → 5 contiguous scenes with style-consistent prompts.
     Note: this Gemini key also has access to image models
     (`gemini-3-pro-image`, `nano-banana-pro-preview`) — relevant to Phase 5
     automated image generation.
     `GEMINI_APIKEY` env var (free at https://aistudio.google.com/apikey) is
     **optional** — endpoints return 503 with instructions until set. Web UI:
     composer "✨ Write with AI" chip (`features/script/ScriptAssistModal.tsx`)
     and a "🎬 Scene prompts" view in the TranscriptModal with per-scene
     copy-prompt buttons for Flow.
   - ✅ **Phase 3 — Storyboard**: new **Storyboard** nav tab
     (`features/storyboard/`): per-project storyboard generated from a chosen
     voiceover clip (auto-transcribes via `/stt` when the clip has no
     transcript, then `/script/scenes`). Scene cards with per-scene image
     upload/replace, copy-prompt, drag-to-reorder (durations keep, start times
     re-anchor), delete-with-gap-fill, regenerate; browser-side **preview**
     swaps images on the voiceover timeline (`StoryboardPreview.tsx`).
     IndexedDB is now **version 3** (`core/db.ts`: + `scenes` store;
     `sceneRepo.ts` stores metadata + image blobs). `deleteProject` also
     removes the project's scenes.
   - ✅ **Phase 4 — Render**: Storyboard "⬇ Export mp4" → `POST /render`
     (multipart: voiceover + scenes JSON + per-scene frame images) →
     `Infrastructure/Ffmpeg/FfmpegVideoRenderer.cs` drives ffmpeg (looped
     stills scaled/cropped to **1080×1920 30fps**, dark placeholder for
     imageless scenes, concat + AAC audio, `-shortest`, faststart) → download
     `<project>.mp4`. **Captions are burned in client-side**
     (`features/storyboard/composite.ts`: canvas cover-fit + wrapped Manrope
     caption box) — Homebrew's ffmpeg 8 has **no drawtext filter** (built
     without freetype), so never rely on drawtext server-side. ffmpeg is a
     backend runtime dependency (`brew install ffmpeg`; probed at
     `/opt/homebrew/bin` → `/usr/local/bin` → PATH, 503 with install hint if
     missing). Verified: 5-scene render → h264/aac 1080×1920@30, correct
     cover-crop + placeholder frames.
   - ✅ **Phase 5 — Timeline Editor**: replace the linear
     Storyboard→Render step with a CapCut-style multi-track non-linear editor
     (layered video/photo/audio, trim, crop, transform, transitions, Ken Burns,
     multi-track audio). Full corrected architecture plan — data model, backend
     C# `filter_complex` compiler, caption-overlay strategy, phased roadmap —
     lives in **[docs/timeline-editor-plan.md](timeline-editor-plan.md)**.
     Non-negotiables it locks in (keep these when building): the ffmpeg compiler
     is **pure C# in `Greyvetro.Infrastructure`**, driven by a structured
     `Timeline` DTO (never client-emitted ffmpeg strings); captions stay
     browser-rendered as **alpha-PNG overlay layers** (no server drawtext);
     media blobs persist in IndexedDB (never blob URLs); v1 is **stills-first**
     (video-clip ingestion deferred). ffmpeg build gate passed 2026-07-17 —
     `zoompan`/`xfade`/`acrossfade`/`overlay`/`amix`/`afade`/`adelay` all present.
     - ✅ **TL Phase 1 — Model + read-only timeline + regression**: `Timeline`/
       `Track`/`Clip`/`MediaAsset` records (`Domain/Entities/Timeline.cs`) mirrored
       by TS (`features/timeline/model/types.ts`). Pure `FilterGraphCompiler`
       (`Infrastructure/Ffmpeg/`, xUnit `Greyvetro.Tests`) emits an `FfmpegPlan`;
       `FfmpegTimelineRenderer` executes it (shared `FfmpegProcess` discovery/run
       helper, extracted from the legacy renderer). `POST /render` now branches on
       a `timeline` form field (structured `Timeline` DTO + `asset-<sourceId>`
       blobs) → `ITimelineRenderer`; the legacy `audio`+`scenes`+`image-N` path is
       untouched. New **Timeline** nav tab seeds a read-only timeline from the
       active project's storyboard + voiceover (`seedTimelineFromScenes`) and
       exports through the new path. Regression gate proven both ways: golden-string
       tests assert the compiler reproduces the legacy filter graph, and a live
       render of equivalent inputs was **byte-identical** to the legacy path
       (1080×1920 h264 / aac, `-shortest`). Captions stay fused into the photo
       frames this phase (compiler ignores caption tracks); they split into an
       alpha overlay in TL Phase 3.
     - ✅ **TL video-clip ingestion (minimal slice)** — pulled forward from the
       "later/separate scope" item. `Timeline.Assets` (`MediaAsset` list) tells the
       compiler a still (`image`, looped) from real video (`video`, trimmed): video
       clips emit `-ss <inPoint> -t <duration> -i` and merge into the base-layer
       `concat` in start-time order; when any video is present the voiceover is
       `apad`-padded so `-shortest` stops at the visual length (an appended clip
       isn't cut). Web: **🎬 Add video** on the Timeline tab (probe duration/dims +
       poster frame via `features/timeline/media.ts`, blob in IndexedDB **v5**
       `timelineAssets` store `timelineAssetRepo.ts`, appended via pure
       `timelineOps.appendVideoClip`; `mergeVideoTracks` re-attaches added videos
       when the storyboard re-seeds). The clip's own audio is muted in v1
       (voiceover stays the only audio track). Verified: photo+video render →
       6s@30 (180 frames), photo span still / video span motion (frame-diffed);
       photo-only path byte-identical. Deferred at the time: frame-accurate
       `<video>` scrub preview, per-clip trim UI, video audio mixing — all three
       have since shipped (TL Phase 2's trim handles; video audio mixing and
       frame-accurate scrub preview below).
     - ✅ **TL Phase 2 — Interactive editing** (shipped 2026-07-18): the Timeline
       tab is now an editor (`TimelineEditor.tsx`), not a read-only view. Per-clip
       **select**, **drag-to-reorder** (HTML5 DnD, within a lane), **trim** both
       edges (pointer handles — stills change `duration`; video also moves
       `inPoint`/`outPoint`, clamped to the asset length), **split at playhead**
       (`S`), **delete** (`Del`, guarded from removing the last visual clip), a
       click-to-scrub **playhead**, and **Play/Pause** playback (a rAF clock
       drives the playhead + synced voiceover; the live frame+caption **preview**
       swaps stills as it plays, video shows its poster). Pure ops
       (`reanchor`/`moveClip`/`trimClip`/`splitClip`/`deleteClip` in
       `timelineOps.ts`) keep the base `concat` contiguous and re-derive the
       display-only caption lane by source id. **The saved timeline is now the
       source of truth** (loaded as-is; storyboard only seeds it once); a **🔄
       Re-sync** action rebuilds photo/caption/audio from the current storyboard,
       keeping added videos. No backend change — the compiler already ordered by
       `startTime` and honored `duration`/`inPoint`/`outPoint`; new xUnit test
       locks that a split (two clips, one source) emits an input per clip.
       Captions still fused (overlay split is Phase 3). Verified: backend 12/12,
       `tsc -b && vite build` clean, 20/20 pure-ops assertions.
     - ✅ **TL Phase 4 — Multi-track audio** (shipped 2026-07-18, ahead of Phase 3
       per the "light editing" priority): background **music/SFX** with per-track
       **volume**/**mute** and per-clip **fade in/out**. `FilterGraphCompiler`
       grew a mix path — each unmuted audio clip is an input-seek-trimmed input
       with `volume` (clip × track gain), `afade` in/out, and `adelay` placement,
       then `amix=inputs=N:normalize=0` + `apad` so `-shortest` keeps the **visual
       length as master**. The single plain-voiceover case stays on the legacy
       direct-map path (byte-for-similar; muting the only extra track falls back
       to it). Web: **🎵 Add music** on the Timeline tab (blob in `timelineAssets`,
       clip clamped to timeline length at 0.3 gain); music clips are selectable
       with an inspector (track volume/mute, fade in/out, remove). Pure ops
       `addMusic`/`setTrackAudio`/`setClipFade`/`removeTrack` + `trimClip` extended
       to audio; `mergeVideoTracks` → `mergeAddedMedia` so music survives re-sync.
       Verified: backend 15/15, build/lint clean, 16/16 audio-ops assertions, and
       the exact `volume,afade,adelay,amix,apad` graph rendered by ffmpeg
       end-to-end (h264+aac, 9.0s master length).
     - ✅ **TL Phase 3 — Layering + transform** (sliced 3a→3b→3c, all shipped):
       - ✅ **3a — Caption alpha-overlay split** (2026-07-18): captions are no
         longer fused into the photo frames. Each caption clip rasterizes to a
         **transparent full-frame PNG** (`captions/drawCaption.ts`
         `renderCaptionOverlay`, sharing the brand `drawCaption` extracted from
         `storyboard/composite.ts`), ships as a `caption-<clipId>` multipart part,
         and the compiler composites it as a **top `overlay=0:0:enable='between(t,
         start,end)'`** layer. Caption inputs are appended **after** the audio
         inputs so audio stream indices — and every golden test — are untouched;
         with no caption PNGs the graph still maps `[vout]` unchanged. Photo frames
         now export caption-free (`compositeFrame(…, false)`). Verified end-to-end
         via a real `/render` POST: h264/aac 1080×1920 4s, caption box present at
         t=1 and absent at t=3 (frame-sampled). Backend 18/18, `tsc -b && vite
         build` clean. **This unblocks transforms** — the image can now move
         independently of the text.
       - ✅ **3b — Per-clip transform.** Reframe (zoom/pan, via `Clip.Crop`) shipped
         first — a normalized source crop before the cover-fit, a Zoom + Pan X/Y
         inspector, an approximate CSS preview. *(Landed in the same commit as the
         `@greyvetro/ui` design-system work below, under a message that only
         described the latter.)* **Rotation** (`Clip.Rotation`, degrees, shipped
         2026-07-20) closed out the phase: the compiler auto-computes the smallest
         uniform zoom that keeps a tilted frame gap-free (`k = cosθ + (H/W)·sinθ`)
         before `scale=k·w:k·h,rotate=θ*PI/180:ow=w:oh=h` crops back down — no black
         corners at any angle the ±45° Tilt slider allows. Verified: +6 golden-string
         tests, and a real `/render` POST — every corner of a 15°-tilted frame
         sampled solid background color.
       - ✅ **3c — Layering** (shipped 2026-07-20): any photo/video track above the
         base zIndex composites as a PiP/logo-style `overlay` — scaled to a
         normalized `Clip.Scale` (aspect kept via ffmpeg `-2`), placed at a
         normalized `Clip.Position`, gated to its window, ordered by zIndex, under
         the caption layer (its inputs land right after audio, captions after
         those — no existing stream-index test moved). Web: **🖼 Add overlay** on
         the Timeline tab adds an image as its own track (default: spans the whole
         timeline, a persistent watermark); selecting it opens a Position X/Y +
         Size inspector and the preview composites it live. Overlay clips edit like
         music (one clip, end-trim only, removed as a whole track) since they don't
         join the base `concat` — `timelineOps.ts` now distinguishes the base
         visual track from overlay tracks by zIndex throughout (`reanchor`/
         `moveClip`/`splitClip`/`deleteClip`/`visualEnd`/the "keep one clip" guard
         are all base-only), and `mergeAddedMedia` carries overlay tracks across a
         re-sync like video/music. Verified: backend 26/26 total, `tsc -b && vite
         build` + lint clean, and a real `/render` POST — a PiP pixel sampled
         background color outside its window and overlay color inside it.
     - ✅ **TL Phase 5 — Motion** (shipped 2026-07-20): Ken Burns pan/zoom on
       stills via keyframed `Clip.Motion.From/To` (`{ zoom, panX, panY }`),
       animated linearly across the clip's full duration by ffmpeg `zoompan`.
       The recipe was verified empirically against ffmpeg 8.1 before wiring it
       in — the pattern every other still uses (`-loop 1 -t <duration> -i`)
       makes zoompan re-run its whole `d`-frame cycle **once per demuxed input
       frame** (100 input frames × d=120 → 12,000 output frames); the fix is an
       **unbounded** `-loop 1 -i` (no input-side `-t`) plus a trailing
       `trim=end_frame=<d>,setpts=PTS-STARTPTS` **inside the filter graph** so
       the clip's stream self-terminates (it feeds a shared `concat` alongside
       other clips, not a standalone output — no external `-t`/`-frames:v` to
       lean on; without the in-graph trim the render hangs forever). Source is
       pre-cover-fit to 3× the output size (`KenBurnsHeadroom`, matches the
       reframe control's `MAX_ZOOM`) so the crop window stays native-res even
       at max zoom; `x`/`y` reference zoompan's own `zoom` variable, clamped
       in-bounds. Stills only (video-source clips ignore Motion, keep their
       `-ss`/`-t` trim); mutually exclusive with static `Crop`/`Rotation` on
       the same clip (identical From/To is a no-op, falls back to the static
       chain). Web: transform inspector's **🎥 Add motion** toggle swaps the
       static Zoom/Pan/Tilt controls for paired Start/End keyframe editors;
       live preview lerps zoom/pan by playhead position within the clip so
       scrubbing shows the animation. Verified: backend 31/31 (5 new tests),
       `tsc -b && vite build` + lint clean, and a real `/render` POST — a
       4s/120-frame clip visibly zoomed + panned between first and last frame.
     - ✅ **TL Phase 6 — Transitions + polish** (shipped 2026-07-20): video
       crossfades (`Clip.TransitionIn`, dissolve/fade-to-black, ffmpeg `xfade`
       — cut-joined clips group into segments folded pairwise, so zero
       transitions stays byte-identical to the pre-Phase-6 graph; duration
       clamped to 90% of the shorter adjacent clip both client- and
       server-side, since the overlap shrinks the base track's effective
       length and the editor's re-anchored timeline must match what renders).
       Web: a ⤭ badge on each inter-clip boundary opens a style+duration
       inspector; clip bars visually overlap once a transition is set (no
       extra rendering — `left`/`width` are still plain percentages). Timeline
       **zoom** (pixels-per-second, 20–400, with Fit) replaced the old
       percentage-of-container layout, ruler+lanes scrolling independently of
       a pinned label column; trims **snap** to nearby clip edges/the playhead
       within an 8px threshold. **Undo/redo** (`useTimelineHistory.ts`, a
       ref-based past/future stack — not `useState`, to dodge Strict Mode's
       double-invoked updaters double-pushing history) backs every edit path
       (editor edits, video/music/overlay adds, re-sync); Cmd/Ctrl+Z (+Shift
       for redo) plus toolbar buttons. Scope cuts (closed out below): no audio
       `acrossfade`, no fade-from/to-black on the first/last clip, continuous
       slider drags aren't coalesced into one undo step. Verified: backend 36/36 (5 new
       transition tests), `tsc -b && vite build` + lint clean, a real
       `/render` POST frame-sampled a genuine 50/50 blend mid-crossfade
       (pure red → blend → pure blue, total duration correctly 3+3−1=5s),
       and zoom/snap/badge/undo-redo driven live in Chrome. Full writeup:
       [docs/timeline-editor-plan.md](timeline-editor-plan.md) §11.
     - ✅ **Video-clip own-audio mixing** (shipped 2026-07-20, after Phase 6):
       closes one of the two items still deferred from the original video-
       ingestion slice. A base-track video clip can opt in (`Clip.IncludeAudio`)
       to mix its own embedded audio into the export — previously always muted.
       The compiler reuses that clip's *own* visual input's `[i:a]` (already
       `-ss`/`-t` trimmed to its window) as an extra `amix` member instead of
       adding a new `-i`, so no downstream input indices shift; reuses the
       clip's existing `Volume`/`FadeIn`/`FadeOut` fields for its own gain/fades
       (no new numeric fields). Web: selected video clip's reframe inspector
       gained an "Include this clip's audio" checkbox + Vol/Fade controls.
       Verified: backend 38/38 (2 new tests), build/lint clean, and a real
       `/render` POST — silent voiceover + a video clip with an embedded 440Hz
       tone: exported audio at the noise floor (-39.7dB) during the photo-only
       window, a clear tone (-23.8dB) exactly during the video's window.
     - ✅ **Frame-accurate `<video>` scrub preview** (shipped 2026-07-20): the
       last deferred item from the original video-ingestion slice. Video-sourced
       clips in the preview (`VideoFrame` component, `TimelineEditor.tsx`) render
       as a real `<video>` seeked to `inPoint + clamp(ph − startTime, 0,
       duration)` — frame-accurate when paused/scrubbing; during playback the
       video's own clock runs and only resyncs past a 0.3s drift threshold
       (avoids reseek-induced stutter). Covers both the base-track preview clip
       and video-type overlay clips (no UI adds one yet, but the compositing path
       is shared). `TimelineScreen.tsx` now also tracks a `videoUrls` (raw blob)
       map alongside the existing poster-frame `imageUrls`. Frontend-only, no
       compiler change. Verified: build/lint clean, backend suite untouched
       (38/38). Live browser scrub verification hit an unrelated environment
       limit (this session's automated Chrome never progresses any `<video>`
       past `readyState 0`, which also blocks the pre-existing `capturePoster`
       poster capture the same way) — not a regression from this change.
     - ✅ **Phase 6 scope-cut follow-up** (shipped 2026-07-20): closes all three
       items noted above. **Video own-audio auto-crossfade**: a base-track video
       clip with `IncludeAudio` now auto-fades its own audio in/out to match the
       (clamped) duration of any adjacent `TransitionIn`, feeding into the same
       `BuildAudioChain` `afade` machinery dedicated audio clips already used —
       the larger of the transition-derived fade and any manual `FadeIn`/
       `FadeOut` wins, so a manual fade is never shortened. **Fade from/to
       black**: `Clip.FadeInFromBlack`/`FadeOutToBlack` add a plain `fade=…
       :color=black` filter (not `xfade`, which needs a second stream); the
       compiler only honors `FadeInFromBlack` on visual-clip index 0 and
       `FadeOutToBlack` on the last index regardless of what's stored elsewhere
       (self-restricting like `TransitionIn`'s `i>0` check), and clamps each
       duration to the clip's own length. Web: a "Fade in from black"/"Fade out
       to black" slider appears on the reframe inspector only when the selected
       clip `isFirstBaseClip`/`isLastBaseClip` (`timelineOps.ts`); `splitClip`
       drops the field from whichever half is no longer first/last. **Coalesced
       slider undo**: `useTimelineHistory.ts` gained `setLive`/`commitLive` —
       `setLive` (every `input` tick) updates the document without touching the
       undo stack, capturing the pre-drag snapshot once; `commitLive`
       (`pointerup`) pushes that single snapshot as one history entry; `undo`/
       `redo`/`set` all flush a pending live edit first so a keyboard-only nudge
       (no `pointerup`) or an undo mid-drag can't skip past it. All 18
       `type="range"` inputs in `TimelineEditor.tsx` now go through a shared
       `applyEdit` helper with `live: true` + `onPointerUp={onCommitDrag}` —
       trim dragging already worked this way (local state, one commit on
       pointer-up) and needed no change. Verified: backend 44/44 (6 new tests:
       auto-crossfade across both transition edges, manual fade winning over
       the auto floor, fade-in/out on first/last clip, ignored on a middle
       clip, clamped to clip duration), `tsc -b && vite build` + lint clean
       (zero new warnings), and a real `/render` POST for both ffmpeg-facing
       features — frame-sampled pure black at t=0 fading to full color, near-
       black approaching the end fade; audio at the noise floor outside the
       video's audio window, full tone mid-clip, audibly ramped levels exactly
       across both transition-overlap edges. The undo-coalescing UI wasn't
       driven live in Chrome this round — the only project with a saved
       timeline in this environment hits the `<video>` `readyState 0` Chrome-
       automation limit noted above before the editor even mounts, not a
       regression from this change; the mechanism mirrors the pre-existing,
       already-verified trim-drag gesture rather than introducing a new pattern.
   - ✅ **Phase 0 — repo rename** (shipped 2026-07-21): `greyvetro-stt` →
     `greyvetro-studio` on GitHub (`gh repo rename`, remote auto-updated) and
     locally (`~/development/GREYVETRO/greyvetro-studio`); this file, README.md,
     `frontend/README.md`, and `frontend-web/README.md` updated to match. No
     code churn to the Flutter package itself — `greyvetro_tts` (pubspec name,
     Xcode/CMake product name) stays as-is, same call as the already-generic
     `.NET` namespaces. The web app's IndexedDB **was** renamed (`greyvetro-tts`
     → `greyvetro-studio` in `frontend-web/src/core/db.ts`), since unlike the
     Flutter package name it's invisible plumbing with no external identity to
     preserve — `migrateFromOldDb()` runs once (gated by a localStorage flag)
     to copy any existing gallery/project/scene/timeline/timelineAsset rows
     from the old browser database into the new one first, so it doesn't
     orphan a browser that already had data. The sibling `greyvetro-auth-hub`
     repo's Keycloak realm config also had an undocumented `greyvetro-tts`
     OIDC client (uncommitted at the time — added to git history for the
     first time under the new name rather than literally renamed); it's now
     `greyvetro-studio` with matching `studio-user`/`studio-admin` roles and a
     `studio-tester` test user. Later/optional: Gemini image
     generation (the key already has `gemini-3-pro-image` / nano-banana
     access), clip transitions, Flutter parity.
   - ✅ **Automated scene images (Gemini image generation)** — closes the first
     item on the "later/optional" list above. Storyboard scenes generate their
     own image from `imagePrompt` instead of the manual Flow copy-paste-import
     workflow: a per-scene **✨** icon button (`StoryboardScreen.tsx`)
     (re)generates just that scene, and a header **Generate images** chip fills
     every scene missing one, sequentially with a 1.2s pause between calls
     (Gemini's free-tier rate limit is per-minute — parallel calls trip it
     immediately). Backend: `IScriptGenerationService.GenerateSceneImageAsync`
     (`GeminiService.cs`) calls `generateContent` on **Nano Banana Pro**
     (`gemini-3-pro-image`, overridable via `GEMINI_IMAGE_MODEL` — same
     rolling-alias reasoning as `GEMINI_MODEL`) with `responseModalities:
     ["IMAGE"]` + `imageConfig: {aspectRatio:"9:16", imageSize:"1K"}`, decoding
     the returned `inlineData` base64 into raw bytes; new
     `POST /script/scenes/image` (`{ prompt }` → image bytes, 503 if
     `GEMINI_APIKEY` unset) mirrors the existing `/script`/`/script/scenes`
     pattern. Also fixed while wiring this up: Gemini error responses are a
     ~2KB nested JSON blob (quota-violation lists, retry info, help links) —
     `GeminiService.ExtractErrorMessage` now pulls just `error.message` for
     this **and** the existing text/scenes calls, and the web `checkStatus`
     (`core/api.ts`) now unwraps ASP.NET's ProblemDetails `detail` field — so
     every API error toast app-wide shows one readable sentence instead of a
     raw JSON dump, not just this endpoint. **Billing gap resolved
     2026-07-21:** live-tested against the real Gemini API the same day —
     every image-output model (`gemini-3-pro-image`, `gemini-2.5-flash-image`,
     `gemini-3.1-flash-image`) initially returned `429 RESOURCE_EXHAUSTED`
     with **`limit: 0`** on the free tier, unlike text generation which has
     always worked free. AI Studio keys are project-scoped, so billing
     enabled elsewhere doesn't help — the fix was linking billing to the
     *exact* Google Cloud project backing this `GEMINI_APIKEY` (confirmed via
     aistudio.google.com/apikey). Verified end-to-end after linking: a live
     `POST /script/scenes/image` call returned a real generated JPEG (9:16,
     ~750KB). The feature is now fully functional, not just wired-and-blocked;
     the manual Flow-copy-paste path remains as a free-tier fallback for
     anyone without billing enabled. Backend 44/44, `tsc -b && vite build` +
     lint clean.

### Candidate additions
- ✅ **Voice settings** — "Voice settings" card in the composer: **Stability**, **Similarity**, **Style** sliders + a **Speaker boost** toggle (on by default — strongest lever for cloned-voice likeness). All four flow through `TtsRequest` → `VoiceSettings`, are stored per gallery item, and restored on edit/regenerate. (Flutter still hardcodes `eleven_multilingual_v2`; the **web** frontend has a Model dropdown — v2 / Eleven v3 / Turbo / Flash — carried through `/tts` `modelId`, gallery items, and presets.)
- ✅ **Voice preview** playback before selecting — a ▶/■ icon-button on each row of the **web** `VoicePickerModal` plays that voice's `previewUrl` (already returned by `GetVoicesAsync`, previously unused by the UI). One shared `Audio` instance backs all rows (`previewAudioRef`); clicking a new voice's preview stops whichever one is currently playing, clicking the same one again stops it, and it auto-resets on `ended`. The button is a `<span role="button">` rather than a nested `<button>` (the row itself is already a `<button>`, and browsers restructure nested `<button>` elements out of the DOM), with `stopPropagation` + a keydown handler so it doesn't trigger row selection and stays keyboard-accessible. Voices without a `previewUrl` (e.g. freshly cloned) simply don't get the control. Verified live in Chrome: independent play/stop toggling, only one clip plays at a time, and clicking the row itself still selects the voice normally. Flutter's `voice_picker.dart` doesn't have this yet — parity deferred with the rest of Flutter, see the Timeline Editor entry above.
- ✅ **Favorites** for voices — a star toggle on each voice row, persisted client-side (**web**: `core/favorites.ts`, a `Set<string>` of voice ids in `localStorage`; **Flutter**: `favorites_repository.dart`, a JSON array file under the app documents dir, mirroring `PresetRepository`'s pattern) — no backend involvement, matching the local-only precedent set by Presets. Both UIs get a "Favorites" filter chip (star icon, toggles to show only favorited voices) alongside the existing gender chips, and favorited voices float to the top of the list (stable sort — order otherwise unchanged) in both the **web** `VoicePickerModal` and Flutter's `VoicesScreen`/`voice_picker.dart`. Full parity shipped in the same commit — no Flutter-lag on this one.
- ✅ **Quota-exceeded / friendly ElevenLabs error handling** — the `ElevenLabs-DotNet` SDK wraps every failed call as a `HttpRequestException` whose message is `"<Method> Failed! HTTP status code: <code> | Response body: <raw JSON>"`; that raw wrapper (and, on the STT path, the raw Scribe error body) was flowing straight into `Results.Problem(...)` and out to the UI. `ElevenLabsService` (`backend/Greyvetro.Infrastructure/ElevenLabs/`) now wraps every SDK call (`GetVoicesAsync`, `GetUsageAsync`, `GenerateSpeechAsync`, `CloneVoiceAsync`) in try/catch and extracts just `detail.message` (or `detail` when it's a bare string) via a small `ExtractErrorMessage`/`CleanedError` helper pair — same pattern as `GeminiService.ExtractErrorMessage`. Also added missing try/catch around the previously-unguarded `/voices` and `/voices/clone` endpoints in `Program.cs`, which used to let SDK exceptions bubble up as bare 500s with no message. No frontend change needed — `core/api.ts`'s `checkStatus` already unwraps ProblemDetails' `detail` field. Verified live: an invalid-voice-id `/tts` call now returns a single clean sentence (`"An invalid ID has been received: '...'. Make sure to provide a correct one."`) instead of the raw SDK dump; `/voices` and a real `/tts` generation still work normally (backend 44/44, build clean).
- ✅ **Dark mode** — light/dark themes in `core/theme.dart`; sidebar toggle, persisted via `core/theme_controller.dart` (`ThemeController` + `ThemeScope`, follows system by default).
- ✅ **Cross-platform audio playback** — replaced macOS `afplay` with the `audioplayers` package (works on macOS + Windows).
- ✅ **Seek bar / scrubber** — `AudioScrubber` (`core/audio_scrubber.dart`) shows an interactive progress bar (drag/click to seek) for the active track in both the Gallery cards and the composer preview.
- ✅ **Presets** — save a named bundle of voice + settings (stability / similarity / style / speaker boost) and re-apply it. `features/presets/` (`Preset` + `PresetRepository`, JSON index in app docs dir, no audio).
  - **Create**: composer Voice-settings card "Save as preset" + "Apply preset" menu; each Gallery card's overflow menu offers "Use these settings" (loads into composer, keeps text) and "Save as preset". Applying uses `TtsScreenState.applySettings`.
  - **Presets tab** (`PresetsScreen`, 3rd nav destination): lists presets with a settings summary; **Use** applies to the composer, **Edit** opens `PresetEditorScreen` (name + voice via the voice picker + the four settings), **Delete** removes it.
  - **Duplicate guard**: saving is blocked when another preset already has identical settings (voice + the four values, name-independent) — `PresetRepository.findMatching` / `Preset.hasSameSettings`. Enforced in the composer, gallery, and editor.
  - Changes anywhere call `onPresetsChanged` → `HomeShell._refreshPresetsEverywhere` keeps the composer menu and Presets tab in sync.
