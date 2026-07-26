using Greyvetro.Domain.Entities;
using Greyvetro.Infrastructure.Ffmpeg;

namespace Greyvetro.Tests;

public class FilterGraphCompilerTests
{
    private readonly FilterGraphCompiler _compiler = new();

    /// <summary>Line-ending-agnostic comparison (AppendLine emits Environment.NewLine).</summary>
    private static string Norm(string s) => s.Replace("\r\n", "\n");

    /// <summary>
    /// A photo track + audio track, seeded exactly as the legacy scene renderer laid out its
    /// segments (first pulled to 0, last padded 1.5s), plus resolved asset paths.
    /// </summary>
    private static (Timeline timeline, Dictionary<string, string> paths) LegacyLikeCase()
    {
        var timeline = new Timeline
        {
            Id = "t1",
            OutputWidth = 1080,
            OutputHeight = 1920,
            Fps = 30,
            Tracks =
            [
                new Track
                {
                    Id = "photo", Type = TrackType.Photo, ZIndex = 0,
                    Clips =
                    [
                        new Clip { Id = "c0", SourceId = "img-0", StartTime = 0,   Duration = 2.5 },
                        new Clip { Id = "c1", SourceId = "img-1", StartTime = 2.5, Duration = 3.5 },
                        new Clip { Id = "c2", SourceId = "img-2", StartTime = 6.0, Duration = 4.5 },
                    ],
                },
                new Track
                {
                    Id = "audio", Type = TrackType.Audio, ZIndex = 0,
                    Clips = [new Clip { Id = "a0", SourceId = "voice", StartTime = 0, Duration = 9.0 }],
                },
            ],
        };
        var paths = new Dictionary<string, string>
        {
            ["img-0"] = "/tmp/a.jpg",
            ["img-1"] = "/tmp/b.jpg",
            ["img-2"] = "/tmp/c.jpg",
            ["voice"] = "/tmp/voice.mp3",
        };
        return (timeline, paths);
    }

    // Regression gate (docs/timeline-editor-plan.md §6, build step 1): for a single visual
    // track + single audio track, the compiler must emit the SAME filter graph the legacy
    // FfmpegVideoRenderer produced — the proof that the model faithfully represents today.
    [Fact]
    public void Compile_SingleVisualAndAudio_ReproducesLegacyFilterGraph()
    {
        var (timeline, paths) = LegacyLikeCase();

        var plan = _compiler.Compile(timeline, paths);

        const string expectedFilter =
            "[0:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1,fps=30[v0];\n" +
            "[1:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1,fps=30[v1];\n" +
            "[2:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1,fps=30[v2];\n" +
            "[v0][v1][v2]concat=n=3:v=1:a=0[vout]";
        Assert.Equal(expectedFilter, Norm(plan.FilterComplex));
    }

    [Fact]
    public void Compile_SingleVisualAndAudio_ReproducesLegacyInputArgs()
    {
        var (timeline, paths) = LegacyLikeCase();

        var plan = _compiler.Compile(timeline, paths);

        Assert.Equal(
            new[]
            {
                "-y",
                "-loop", "1", "-t", "2.5", "-i", "/tmp/a.jpg",
                "-loop", "1", "-t", "3.5", "-i", "/tmp/b.jpg",
                "-loop", "1", "-t", "4.5", "-i", "/tmp/c.jpg",
                "-i", "/tmp/voice.mp3",
            },
            plan.InputArgs);
    }

    [Fact]
    public void Compile_SingleVisualAndAudio_ReproducesLegacyOutputArgs()
    {
        var (timeline, paths) = LegacyLikeCase();

        var plan = _compiler.Compile(timeline, paths);

        // Audio input index == the visual-clip count (3), as in the legacy renderer.
        Assert.Equal(
            new[]
            {
                "-map", "[vout]", "-map", "3:a",
                "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p",
                "-c:a", "aac", "-b:a", "192k",
                "-shortest", "-movflags", "+faststart",
            },
            plan.OutputArgs);
    }

    [Fact]
    public void Compile_MissingVisualSource_EmitsPlaceholderColorInput()
    {
        var (timeline, paths) = LegacyLikeCase();
        paths.Remove("img-1"); // second clip has no supplied image

        var plan = _compiler.Compile(timeline, paths);

        Assert.Contains("-f", plan.InputArgs);
        Assert.Contains("lavfi", plan.InputArgs);
        Assert.Contains("color=c=0x1A1F26:s=1080x1920:r=30", plan.InputArgs);
    }

    [Fact]
    public void Compile_HonorsCustomOutputResolutionAndFps()
    {
        var timeline = new Timeline
        {
            OutputWidth = 1080,
            OutputHeight = 1080,
            Fps = 24,
            Tracks =
            [
                new Track { Type = TrackType.Photo, Clips = [new Clip { SourceId = "img", Duration = 3 }] },
                new Track { Type = TrackType.Audio, Clips = [new Clip { SourceId = "aud", Duration = 3 }] },
            ],
        };
        var paths = new Dictionary<string, string> { ["img"] = "/tmp/i.png", ["aud"] = "/tmp/a.mp3" };

        var plan = _compiler.Compile(timeline, paths);

        Assert.Contains("scale=1080:1080:force_original_aspect_ratio=increase,crop=1080:1080,setsar=1,fps=24",
            Norm(plan.FilterComplex));
    }

    [Fact]
    public void Compile_OrdersVisualClipsByStartTime()
    {
        var timeline = new Timeline
        {
            Tracks =
            [
                new Track
                {
                    Type = TrackType.Photo,
                    Clips =
                    [
                        new Clip { SourceId = "late", StartTime = 5, Duration = 2 },
                        new Clip { SourceId = "early", StartTime = 0, Duration = 5 },
                    ],
                },
                new Track { Type = TrackType.Audio, Clips = [new Clip { SourceId = "aud", Duration = 7 }] },
            ],
        };
        var paths = new Dictionary<string, string>
        {
            ["early"] = "/tmp/early.jpg",
            ["late"] = "/tmp/late.jpg",
            ["aud"] = "/tmp/a.mp3",
        };

        var plan = _compiler.Compile(timeline, paths);

        var earlyIdx = plan.InputArgs.ToList().IndexOf("/tmp/early.jpg");
        var lateIdx = plan.InputArgs.ToList().IndexOf("/tmp/late.jpg");
        Assert.True(earlyIdx < lateIdx, "clips must be laid out in start-time order");
    }

    [Fact]
    public void Compile_NoVisualTrack_Throws()
    {
        var timeline = new Timeline
        {
            Tracks = [new Track { Type = TrackType.Audio, Clips = [new Clip { SourceId = "aud", Duration = 3 }] }],
        };
        var paths = new Dictionary<string, string> { ["aud"] = "/tmp/a.mp3" };

        Assert.Throws<ArgumentException>(() => _compiler.Compile(timeline, paths));
    }

    [Fact]
    public void Compile_NoAudioTrack_Throws()
    {
        var timeline = new Timeline
        {
            Tracks = [new Track { Type = TrackType.Photo, Clips = [new Clip { SourceId = "img", Duration = 3 }] }],
        };
        var paths = new Dictionary<string, string> { ["img"] = "/tmp/i.jpg" };

        Assert.Throws<ArgumentException>(() => _compiler.Compile(timeline, paths));
    }

    // --- Video-clip ingestion (minimal slice) ---

    /// <summary>A still photo followed by a real video clip on the base layer, + a voiceover.</summary>
    private static (Timeline, Dictionary<string, string>) PhotoPlusVideoCase()
    {
        var timeline = new Timeline
        {
            OutputWidth = 1080,
            OutputHeight = 1920,
            Fps = 30,
            Tracks =
            [
                new Track
                {
                    Id = "photo", Type = TrackType.Photo, ZIndex = 0,
                    Clips = [new Clip { Id = "p0", SourceId = "img", StartTime = 0, Duration = 3 }],
                },
                new Track
                {
                    Id = "video", Type = TrackType.Video, ZIndex = 0,
                    Clips =
                    [
                        new Clip { Id = "vc", SourceId = "vid", StartTime = 3, Duration = 4, InPoint = 0.5, OutPoint = 4.5 },
                    ],
                },
                new Track
                {
                    Id = "audio", Type = TrackType.Audio, ZIndex = 0,
                    Clips = [new Clip { Id = "a0", SourceId = "aud", StartTime = 0, Duration = 9 }],
                },
            ],
            Assets =
            [
                new MediaAsset { Id = "img", Type = MediaType.Image },
                new MediaAsset { Id = "vid", Type = MediaType.Video },
                new MediaAsset { Id = "aud", Type = MediaType.Audio },
            ],
        };
        var paths = new Dictionary<string, string>
        {
            ["img"] = "/tmp/i.jpg",
            ["vid"] = "/tmp/v.mp4",
            ["aud"] = "/tmp/a.mp3",
        };
        return (timeline, paths);
    }

    [Fact]
    public void Compile_VideoClip_UsesInputSeekAndTrim_NotLoopedStill()
    {
        var (timeline, paths) = PhotoPlusVideoCase();

        var plan = _compiler.Compile(timeline, paths);

        // Photo stays a looped still; the video is input-seeked to its in-point and read for its
        // duration (real motion), and merged after the photo in start-time order.
        Assert.Equal(
            new[]
            {
                "-y",
                "-loop", "1", "-t", "3", "-i", "/tmp/i.jpg",
                "-ss", "0.5", "-t", "4", "-i", "/tmp/v.mp4",
                "-i", "/tmp/a.mp3",
            },
            plan.InputArgs);
    }

    [Fact]
    public void Compile_VideoPresent_ConcatsBothAndPadsAudio()
    {
        var (timeline, paths) = PhotoPlusVideoCase();

        var plan = _compiler.Compile(timeline, paths);

        const string expectedFilter =
            "[0:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1,fps=30[v0];\n" +
            "[1:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1,fps=30[v1];\n" +
            "[v0][v1]concat=n=2:v=1:a=0[vout];[2:a]apad[aout]";
        Assert.Equal(expectedFilter, Norm(plan.FilterComplex));
    }

    [Fact]
    public void Compile_VideoPresent_MapsPaddedAudio()
    {
        var (timeline, paths) = PhotoPlusVideoCase();

        var plan = _compiler.Compile(timeline, paths);

        // The padded voiceover ([aout]) is mapped instead of a raw stream, and -shortest is kept
        // so the visual concat (with the appended video) becomes the master length.
        Assert.Equal(
            new[]
            {
                "-map", "[vout]", "-map", "[aout]",
                "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p",
                "-c:a", "aac", "-b:a", "192k",
                "-shortest", "-movflags", "+faststart",
            },
            plan.OutputArgs);
    }

    [Fact]
    public void Compile_VideoClipWithIncludeAudio_MixesOwnAudioWithVoiceover()
    {
        var (timeline, paths) = PhotoPlusVideoCase();
        timeline = timeline with
        {
            Tracks = timeline.Tracks.Select(t => t.Type != TrackType.Video ? t : t with
            {
                Clips = [t.Clips[0] with { IncludeAudio = true }],
            }).ToList(),
        };

        var plan = _compiler.Compile(timeline, paths);

        // Video's own audio ([1:a], the same input as its visual stream — already trimmed by that
        // input's own -ss/-t) is mixed in alongside the voiceover ([2:a]), each with its own adelay
        // placement, instead of the legacy single-voiceover direct-map path.
        const string expectedFilter =
            "[0:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1,fps=30[v0];\n" +
            "[1:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1,fps=30[v1];\n" +
            "[v0][v1]concat=n=2:v=1:a=0[vout];" +
            "[2:a]anull[a0];" +
            "[1:a]adelay=3000:all=1[a1];" +
            "[a0][a1]amix=inputs=2:normalize=0:dropout_transition=0[amixed];[amixed]apad[aout]";
        Assert.Equal(expectedFilter, Norm(plan.FilterComplex));
        Assert.Contains("[aout]", plan.OutputArgs);
    }

    [Fact]
    public void Compile_VideoClipIncludeAudioWithMutedVoiceoverTrack_SingleMemberApadPath()
    {
        var (timeline, paths) = PhotoPlusVideoCase();
        timeline = timeline with
        {
            Tracks = timeline.Tracks.Select(t => t.Type switch
            {
                TrackType.Video => t with { Clips = [t.Clips[0] with { IncludeAudio = true }] },
                TrackType.Audio => t with { Muted = true },
                _ => t,
            }).ToList(),
        };

        var plan = _compiler.Compile(timeline, paths);

        // The dedicated audio track is muted (contributes nothing), so the video's own audio is the
        // only mix member — no amix needed, same "single member" shortcut dedicated tracks get.
        Assert.DoesNotContain("amix", Norm(plan.FilterComplex));
        Assert.Contains("[1:a]adelay=3000:all=1[a0];[a0]apad[aout]", Norm(plan.FilterComplex));
    }

    // --- Editor structural edits (Phase 2) ---

    [Fact]
    public void Compile_TwoPhotoClipsShareOneSource_EmitsAnInputPerClip()
    {
        // Splitting a still yields two clips referencing the same asset id. The compiler must emit
        // a looped input per clip (not dedupe by source), so each half keeps its own timeline
        // length — this is what makes the editor's splitClip render correctly.
        var timeline = new Timeline
        {
            Tracks =
            [
                new Track
                {
                    Type = TrackType.Photo, ZIndex = 0,
                    Clips =
                    [
                        new Clip { Id = "a", SourceId = "img", StartTime = 0, Duration = 2 },
                        new Clip { Id = "b", SourceId = "img", StartTime = 2, Duration = 3 },
                    ],
                },
                new Track { Type = TrackType.Audio, Clips = [new Clip { SourceId = "aud", Duration = 5 }] },
            ],
        };
        var paths = new Dictionary<string, string> { ["img"] = "/tmp/i.jpg", ["aud"] = "/tmp/a.mp3" };

        var plan = _compiler.Compile(timeline, paths);

        Assert.Equal(
            new[]
            {
                "-y",
                "-loop", "1", "-t", "2", "-i", "/tmp/i.jpg",
                "-loop", "1", "-t", "3", "-i", "/tmp/i.jpg",
                "-i", "/tmp/a.mp3",
            },
            plan.InputArgs);
        Assert.Contains("concat=n=2:v=1:a=0[vout]", Norm(plan.FilterComplex));
    }

    [Fact]
    public void Compile_TwoVideoClipsShareOneSource_EmitsAnInputPerClip()
    {
        // Mirrors Compile_TwoPhotoClipsShareOneSource_EmitsAnInputPerClip: splitting a video clip
        // yields two clips referencing the same asset id but distinct inPoint/duration — the
        // compiler must emit a separately input-seeked/trimmed input per clip (not dedupe by
        // source), each keeping its own window into the source video.
        var timeline = new Timeline
        {
            OutputWidth = 1080, OutputHeight = 1920, Fps = 30,
            Tracks =
            [
                new Track
                {
                    Id = "photo", Type = TrackType.Photo, ZIndex = 0,
                    Clips = [new Clip { Id = "p0", SourceId = "img", StartTime = 0, Duration = 3 }],
                },
                new Track
                {
                    Id = "video", Type = TrackType.Video, ZIndex = 0,
                    Clips =
                    [
                        // Original clip was StartTime=3, Duration=4, InPoint=0.5, OutPoint=4.5;
                        // split at local offset 2 (absolute t=5) into two 2s halves.
                        new Clip { Id = "vc-a", SourceId = "vid", StartTime = 3, Duration = 2, InPoint = 0.5, OutPoint = 2.5 },
                        new Clip { Id = "vc-b", SourceId = "vid", StartTime = 5, Duration = 2, InPoint = 2.5, OutPoint = 4.5 },
                    ],
                },
                new Track
                {
                    Id = "audio", Type = TrackType.Audio, ZIndex = 0,
                    Clips = [new Clip { Id = "a0", SourceId = "aud", StartTime = 0, Duration = 7 }],
                },
            ],
            Assets =
            [
                new MediaAsset { Id = "img", Type = MediaType.Image },
                new MediaAsset { Id = "vid", Type = MediaType.Video },
                new MediaAsset { Id = "aud", Type = MediaType.Audio },
            ],
        };
        var paths = new Dictionary<string, string>
        {
            ["img"] = "/tmp/i.jpg",
            ["vid"] = "/tmp/v.mp4",
            ["aud"] = "/tmp/a.mp3",
        };

        var plan = _compiler.Compile(timeline, paths);

        Assert.Equal(
            new[]
            {
                "-y",
                "-loop", "1", "-t", "3", "-i", "/tmp/i.jpg",
                "-ss", "0.5", "-t", "2", "-i", "/tmp/v.mp4",
                "-ss", "2.5", "-t", "2", "-i", "/tmp/v.mp4",
                "-i", "/tmp/a.mp3",
            },
            plan.InputArgs);
        Assert.Contains("concat=n=3:v=1:a=0[vout]", Norm(plan.FilterComplex));
    }

    // --- Multi-track audio (Phase 4) ---

    /// <summary>A photo, a plain voiceover, and a music track (30% gain, 2s fade-out).</summary>
    private static (Timeline, Dictionary<string, string>) VoiceoverPlusMusicCase(
        double musicStart = 0, double? trackVolume = 0.3, double? fadeOut = 2, bool musicMuted = false)
    {
        var timeline = new Timeline
        {
            OutputWidth = 1080, OutputHeight = 1920, Fps = 30,
            Tracks =
            [
                new Track { Id = "photo", Type = TrackType.Photo, ZIndex = 0,
                    Clips = [new Clip { Id = "p0", SourceId = "img", StartTime = 0, Duration = 9 }] },
                new Track { Id = "audio", Type = TrackType.Audio, ZIndex = 0,
                    Clips = [new Clip { Id = "vo", SourceId = "voice", StartTime = 0, Duration = 9 }] },
                new Track { Id = "music", Type = TrackType.Audio, ZIndex = 1, Volume = trackVolume, Muted = musicMuted,
                    Clips = [new Clip { Id = "m0", SourceId = "music", StartTime = musicStart, Duration = 9, FadeOut = fadeOut }] },
            ],
            Assets =
            [
                new MediaAsset { Id = "img", Type = MediaType.Image },
                new MediaAsset { Id = "voice", Type = MediaType.Audio },
                new MediaAsset { Id = "music", Type = MediaType.Audio },
            ],
        };
        var paths = new Dictionary<string, string>
        {
            ["img"] = "/tmp/i.jpg", ["voice"] = "/tmp/voice.mp3", ["music"] = "/tmp/music.mp3",
        };
        return (timeline, paths);
    }

    [Fact]
    public void Compile_VoiceoverPlusMusic_MixesWithVolumeFadeAndApad()
    {
        var (timeline, paths) = VoiceoverPlusMusicCase();

        var plan = _compiler.Compile(timeline, paths);

        const string expected =
            "[0:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1,fps=30[v0];\n" +
            "[v0]concat=n=1:v=1:a=0[vout];" +
            "[1:a]anull[a0];" +
            "[2:a]volume=0.3,afade=t=out:st=7:d=2[a1];" +
            "[a0][a1]amix=inputs=2:normalize=0:dropout_transition=0[amixed];[amixed]apad[aout]";
        Assert.Equal(expected, Norm(plan.FilterComplex));

        // Each audio clip is its own input-seek-trimmed input, after the single photo input.
        Assert.Equal(
            new[]
            {
                "-y",
                "-loop", "1", "-t", "9", "-i", "/tmp/i.jpg",
                "-ss", "0", "-t", "9", "-i", "/tmp/voice.mp3",
                "-ss", "0", "-t", "9", "-i", "/tmp/music.mp3",
            },
            plan.InputArgs);
        Assert.Contains("[aout]", plan.OutputArgs);
    }

    [Fact]
    public void Compile_AudioClipWithStartTime_UsesAdelay()
    {
        var (timeline, paths) = VoiceoverPlusMusicCase(musicStart: 3, trackVolume: null, fadeOut: null);

        var plan = _compiler.Compile(timeline, paths);

        Assert.Contains("adelay=3000:all=1", Norm(plan.FilterComplex));
        Assert.Contains("amix=inputs=2", Norm(plan.FilterComplex));
    }

    [Fact]
    public void Compile_MutedAudioTrack_IsExcludedAndFallsBackToLegacyVoiceover()
    {
        // Muting the only extra track leaves a single plain voiceover — the legacy direct map, no mix.
        var (timeline, paths) = VoiceoverPlusMusicCase(musicMuted: true);

        var plan = _compiler.Compile(timeline, paths);

        Assert.DoesNotContain("amix", Norm(plan.FilterComplex));
        Assert.DoesNotContain("[aout]", plan.OutputArgs);
        Assert.Contains("1:a", plan.OutputArgs); // voiceover mapped directly (audio input index 1)
    }

    // --- Captions as alpha-PNG overlays (Phase 3) ---

    /// <summary>The legacy photo+audio case plus a caption track mirroring the first two clips.</summary>
    private static (Timeline, Dictionary<string, string>) CaptionCase()
    {
        var (timeline, paths) = LegacyLikeCase();
        timeline = timeline with
        {
            Tracks =
            [
                .. timeline.Tracks,
                new Track
                {
                    Id = "caption", Type = TrackType.Caption, ZIndex = 1,
                    Clips =
                    [
                        new Clip { Id = "cap0", SourceId = "img-0", StartTime = 0,   Duration = 2.5, Text = "one" },
                        new Clip { Id = "cap1", SourceId = "img-1", StartTime = 2.5, Duration = 3.5, Text = "two" },
                    ],
                },
            ],
        };
        return (timeline, paths);
    }

    [Fact]
    public void Compile_WithCaptionPngs_OverlaysEachGatedToItsWindow_AndMapsVcap()
    {
        var (timeline, paths) = CaptionCase();
        var captionPaths = new Dictionary<string, string>
        {
            ["cap0"] = "/tmp/cap0.png",
            ["cap1"] = "/tmp/cap1.png",
        };

        var plan = _compiler.Compile(timeline, paths, captionPaths);

        // One image input per caption, appended AFTER the voiceover input (index 3).
        Assert.Equal(
            new[]
            {
                "-y",
                "-loop", "1", "-t", "2.5", "-i", "/tmp/a.jpg",
                "-loop", "1", "-t", "3.5", "-i", "/tmp/b.jpg",
                "-loop", "1", "-t", "4.5", "-i", "/tmp/c.jpg",
                "-i", "/tmp/voice.mp3",
                "-i", "/tmp/cap0.png",
                "-i", "/tmp/cap1.png",
            },
            plan.InputArgs);

        // Overlays chain onto the concat output, each gated to its clip's [start,end] window.
        Assert.Contains("[vout][4:v]overlay=0:0:enable='between(t,0,2.5)'[vc0]", Norm(plan.FilterComplex));
        Assert.Contains("[vc0][5:v]overlay=0:0:enable='between(t,2.5,6)'[vcap]", Norm(plan.FilterComplex));

        // The final overlay label is what gets mapped (not the raw concat output).
        var maps = plan.OutputArgs.ToList();
        Assert.Equal("[vcap]", maps[maps.IndexOf("-map") + 1]);
    }

    [Fact]
    public void Compile_CaptionInputsComeAfterMixedAudio_LeavingAudioIndicesIntact()
    {
        // With a real audio mix (voiceover + music = inputs 1,2), caption PNGs must index after
        // them (3,4) so the amix stream references above stay valid.
        var (timeline, paths) = VoiceoverPlusMusicCase();
        timeline = timeline with
        {
            Tracks =
            [
                .. timeline.Tracks,
                new Track
                {
                    Id = "caption", Type = TrackType.Caption, ZIndex = 2,
                    Clips = [new Clip { Id = "cap0", SourceId = "img", StartTime = 1, Duration = 4, Text = "hi" }],
                },
            ],
        };
        var captionPaths = new Dictionary<string, string> { ["cap0"] = "/tmp/cap0.png" };

        var plan = _compiler.Compile(timeline, paths, captionPaths);

        Assert.Contains("amix=inputs=2", Norm(plan.FilterComplex));       // audio mix intact
        Assert.Contains("[vout][3:v]overlay=0:0:enable='between(t,1,5)'[vcap]", Norm(plan.FilterComplex));
    }

    [Fact]
    public void Compile_CaptionTrackButNoPngs_IsIgnored_MapsVout()
    {
        // A display-only caption track with no supplied PNGs stays out of the graph (legacy path).
        var (timeline, paths) = CaptionCase();

        var plan = _compiler.Compile(timeline, paths); // no captionPaths

        Assert.DoesNotContain("overlay", Norm(plan.FilterComplex));
        Assert.Contains("[vout]", plan.OutputArgs);
    }

    // --- Per-clip crop / reframe (Phase 3b) ---

    [Fact]
    public void Compile_ClipWithCrop_PrependsSourceCropBeforeCoverFit()
    {
        var (timeline, paths) = LegacyLikeCase();
        var photo = timeline.Tracks[0];
        var clips = photo.Clips.ToList();
        // Centered half-size region ≈ a 2× punch-in on the first clip.
        clips[0] = clips[0] with { Crop = new CropRect { X = 0.25, Y = 0.25, Width = 0.5, Height = 0.5 } };
        timeline = timeline with { Tracks = [photo with { Clips = clips }, timeline.Tracks[1]] };

        var plan = _compiler.Compile(timeline, paths);

        // The cropped clip crops the source region first, THEN cover-fits it to the output.
        Assert.Contains(
            "[0:v]crop=iw*0.5:ih*0.5:iw*0.25:ih*0.25,scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1,fps=30[v0]",
            Norm(plan.FilterComplex));
        // Un-cropped clips stay byte-identical to the legacy chain.
        Assert.Contains(
            "[1:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1,fps=30[v1]",
            Norm(plan.FilterComplex));
    }

    [Fact]
    public void Compile_FullFrameCrop_IsANoOp()
    {
        var (timeline, paths) = LegacyLikeCase();
        var photo = timeline.Tracks[0];
        var clips = photo.Clips.ToList();
        clips[0] = clips[0] with { Crop = new CropRect { X = 0, Y = 0, Width = 1, Height = 1 } };
        timeline = timeline with { Tracks = [photo with { Clips = clips }, timeline.Tracks[1]] };

        var plan = _compiler.Compile(timeline, paths);

        // A full-frame crop must not emit a crop=iw*… prefix (keeps the un-transformed graph).
        Assert.DoesNotContain("iw*", Norm(plan.FilterComplex));
    }

    // --- Per-clip rotation (Phase 3b) ---

    [Fact]
    public void Compile_ClipWithRotation_InsertsAutoZoomAndRotateAfterCoverFit()
    {
        var (timeline, paths) = LegacyLikeCase();
        var photo = timeline.Tracks[0];
        var clips = photo.Clips.ToList();
        clips[0] = clips[0] with { Rotation = 20 };
        timeline = timeline with { Tracks = [photo with { Clips = clips }, timeline.Tracks[1]] };

        var plan = _compiler.Compile(timeline, paths);

        // Auto-zoom (k ≈ 1.5477 for 20° on a 1080x1920 canvas) keeps the rotated frame gap-free,
        // then rotate crops back down to the canvas size.
        Assert.Contains(
            "[0:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920," +
            "scale=1672:2972,rotate=20*PI/180:ow=1080:oh=1920:c=black,setsar=1,fps=30[v0]",
            Norm(plan.FilterComplex));
        // Un-rotated clips stay byte-identical.
        Assert.Contains(
            "[1:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1,fps=30[v1]",
            Norm(plan.FilterComplex));
    }

    [Fact]
    public void Compile_ClipWithNegativeRotation_ZoomsBySameMagnitude_ButSignsTheAngle()
    {
        var (timeline, paths) = LegacyLikeCase();
        var photo = timeline.Tracks[0];
        var clips = photo.Clips.ToList();
        clips[0] = clips[0] with { Rotation = -15 };
        timeline = timeline with { Tracks = [photo with { Clips = clips }, timeline.Tracks[1]] };

        var plan = _compiler.Compile(timeline, paths);

        Assert.Contains(
            "crop=1080:1920,scale=1541:2739,rotate=-15*PI/180:ow=1080:oh=1920:c=black,setsar=1",
            Norm(plan.FilterComplex));
    }

    [Fact]
    public void Compile_ClipWithZeroRotation_IsANoOp()
    {
        var (timeline, paths) = LegacyLikeCase();
        var photo = timeline.Tracks[0];
        var clips = photo.Clips.ToList();
        clips[0] = clips[0] with { Rotation = 0 };
        timeline = timeline with { Tracks = [photo with { Clips = clips }, timeline.Tracks[1]] };

        var plan = _compiler.Compile(timeline, paths);

        Assert.DoesNotContain("rotate=", Norm(plan.FilterComplex));
    }

    // --- Overlay visual layers / z-index layering (Phase 3c) ---

    private static (Timeline, Dictionary<string, string>) OverlayCase()
    {
        var (timeline, paths) = LegacyLikeCase();
        timeline = timeline with
        {
            Tracks =
            [
                .. timeline.Tracks,
                new Track
                {
                    Id = "logo", Type = TrackType.Photo, ZIndex = 1,
                    Clips =
                    [
                        new Clip
                        {
                            Id = "ov0", SourceId = "logo-img", StartTime = 1, Duration = 3,
                            Position = new NormalizedPoint { X = 0.65, Y = 0.05 }, Scale = 0.3,
                        },
                    ],
                },
            ],
        };
        paths = new Dictionary<string, string>(paths) { ["logo-img"] = "/tmp/logo.png" };
        return (timeline, paths);
    }

    [Fact]
    public void Compile_OverlayVisualTrack_CompositesAbovetheBaseConcat_AndMapsVov()
    {
        var (timeline, paths) = OverlayCase();

        var plan = _compiler.Compile(timeline, paths);

        // Overlay input is appended after the (single) audio input.
        Assert.Equal(
            new[]
            {
                "-y",
                "-loop", "1", "-t", "2.5", "-i", "/tmp/a.jpg",
                "-loop", "1", "-t", "3.5", "-i", "/tmp/b.jpg",
                "-loop", "1", "-t", "4.5", "-i", "/tmp/c.jpg",
                "-i", "/tmp/voice.mp3",
                "-i", "/tmp/logo.png",
            },
            plan.InputArgs);

        // Scaled to 30% of the 1080-wide canvas (324px), placed at its normalized position
        // (0.65*1080=702, 0.05*1920=96), gated to [1, 1+3].
        Assert.Contains("[4:v]scale=324:-2,setsar=1[ovl0]", Norm(plan.FilterComplex));
        Assert.Contains("[vout][ovl0]overlay=702:96:enable='between(t,1,4)'[vov]", Norm(plan.FilterComplex));

        var maps = plan.OutputArgs.ToList();
        Assert.Equal("[vov]", maps[maps.IndexOf("-map") + 1]);
    }

    [Fact]
    public void Compile_OverlayAndCaptions_CaptionsCompositeOnTopOfTheOverlay()
    {
        var (timeline, paths) = OverlayCase();
        timeline = timeline with
        {
            Tracks =
            [
                .. timeline.Tracks,
                new Track
                {
                    Id = "caption", Type = TrackType.Caption, ZIndex = 2,
                    Clips = [new Clip { Id = "cap0", SourceId = "img-0", StartTime = 0, Duration = 2.5, Text = "hi" }],
                },
            ],
        };
        var captionPaths = new Dictionary<string, string> { ["cap0"] = "/tmp/cap0.png" };

        var plan = _compiler.Compile(timeline, paths, captionPaths);

        // Input order: base visuals, audio, overlay logo, THEN the caption PNG (index 5).
        Assert.Equal(
            new[]
            {
                "-y",
                "-loop", "1", "-t", "2.5", "-i", "/tmp/a.jpg",
                "-loop", "1", "-t", "3.5", "-i", "/tmp/b.jpg",
                "-loop", "1", "-t", "4.5", "-i", "/tmp/c.jpg",
                "-i", "/tmp/voice.mp3",
                "-i", "/tmp/logo.png",
                "-i", "/tmp/cap0.png",
            },
            plan.InputArgs);

        // Overlay composites onto the base concat first...
        Assert.Contains("[vout][ovl0]overlay=702:96:enable='between(t,1,4)'[vov]", Norm(plan.FilterComplex));
        // ...then the caption composites on top of THAT result, not the raw base.
        Assert.Contains("[vov][5:v]overlay=0:0:enable='between(t,0,2.5)'[vcap]", Norm(plan.FilterComplex));

        var maps = plan.OutputArgs.ToList();
        Assert.Equal("[vcap]", maps[maps.IndexOf("-map") + 1]);
    }

    [Fact]
    public void Compile_NoOverlayTrack_IsANoOp_MapsVout()
    {
        var (timeline, paths) = LegacyLikeCase();

        var plan = _compiler.Compile(timeline, paths);

        Assert.DoesNotContain("[ovl", Norm(plan.FilterComplex));
        var maps = plan.OutputArgs.ToList();
        Assert.Equal("[vout]", maps[maps.IndexOf("-map") + 1]);
    }

    // --- Ken Burns motion (Phase 5) ---

    private static (Timeline, Dictionary<string, string>) MotionCase(Motion? motion)
    {
        var timeline = new Timeline
        {
            OutputWidth = 1080, OutputHeight = 1920, Fps = 30,
            Tracks =
            [
                new Track
                {
                    Type = TrackType.Photo, ZIndex = 0,
                    Clips = [new Clip { Id = "c0", SourceId = "img", StartTime = 0, Duration = 4, Motion = motion }],
                },
                new Track { Type = TrackType.Audio, Clips = [new Clip { SourceId = "aud", Duration = 4 }] },
            ],
            Assets = [new MediaAsset { Id = "img", Type = MediaType.Image }],
        };
        var paths = new Dictionary<string, string> { ["img"] = "/tmp/i.jpg", ["aud"] = "/tmp/a.mp3" };
        return (timeline, paths);
    }

    [Fact]
    public void Compile_ClipWithMotion_UsesUnboundedLoopInput_NoInputSideTrim()
    {
        var motion = new Motion
        {
            From = new KenBurnsKeyframe { Zoom = 1, PanX = 0.5, PanY = 0.5 },
            To = new KenBurnsKeyframe { Zoom = 1.5, PanX = 0.5, PanY = 0.3 },
        };
        var (timeline, paths) = MotionCase(motion);

        var plan = _compiler.Compile(timeline, paths);

        // No -t alongside -loop 1: zoompan's own d + a trailing trim= bound the frame count instead
        // (see ZoompanChain) — combining -loop 1 with an input-side -t re-runs the whole zoompan
        // cycle once per demuxed frame, verified empirically against real ffmpeg.
        Assert.Equal(
            new[] { "-y", "-loop", "1", "-i", "/tmp/i.jpg", "-i", "/tmp/a.mp3" },
            plan.InputArgs);
    }

    [Fact]
    public void Compile_ClipWithMotion_EmitsZoompanWithLerpedKeyframesAndTrim()
    {
        var motion = new Motion
        {
            From = new KenBurnsKeyframe { Zoom = 1, PanX = 0.5, PanY = 0.5 },
            To = new KenBurnsKeyframe { Zoom = 1.5, PanX = 0.5, PanY = 0.3 },
        };
        var (timeline, paths) = MotionCase(motion);

        var plan = _compiler.Compile(timeline, paths);

        // 4s @ 30fps = 120 frames, denom = 119. Pre-scaled to 3x headroom (3240x5760).
        const string expected =
            "[0:v]scale=3240:5760:force_original_aspect_ratio=increase,crop=3240:5760," +
            "zoompan=z='1+0.5*on/119':" +
            "x='min(max((0.5+0*on/119)*iw-(iw/zoom/2),0),iw-iw/zoom)':" +
            "y='min(max((0.5+-0.2*on/119)*ih-(ih/zoom/2),0),ih-ih/zoom)':" +
            "d=120:s=1080x1920:fps=30," +
            "trim=end_frame=120,setpts=PTS-STARTPTS,setsar=1[v0];\n" +
            "[v0]concat=n=1:v=1:a=0[vout]";
        Assert.Equal(expected, Norm(plan.FilterComplex));
    }

    [Fact]
    public void Compile_ClipWithIdenticalFromToMotion_IsANoOp_FallsBackToStaticChain()
    {
        var motion = new Motion
        {
            From = new KenBurnsKeyframe { Zoom = 1.2, PanX = 0.4, PanY = 0.4 },
            To = new KenBurnsKeyframe { Zoom = 1.2, PanX = 0.4, PanY = 0.4 },
        };
        var (timeline, paths) = MotionCase(motion);

        var plan = _compiler.Compile(timeline, paths);

        Assert.DoesNotContain("zoompan", Norm(plan.FilterComplex));
        Assert.Contains("-loop", plan.InputArgs);
        Assert.Contains("-t", plan.InputArgs); // static path keeps the input-side trim
    }

    [Fact]
    public void Compile_ClipWithNoMotion_IsUnaffected()
    {
        var (timeline, paths) = MotionCase(null);

        var plan = _compiler.Compile(timeline, paths);

        Assert.DoesNotContain("zoompan", Norm(plan.FilterComplex));
        Assert.Contains(
            "[0:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1,fps=30[v0]",
            Norm(plan.FilterComplex));
    }

    [Fact]
    public void Compile_VideoClipWithMotion_IgnoresMotion_StaysOnVideoTrimPath()
    {
        // Motion is a stills-only Ken Burns effect; a video source keeps its normal -ss/-t trim.
        var motion = new Motion { To = new KenBurnsKeyframe { Zoom = 1.5 } };
        var timeline = new Timeline
        {
            OutputWidth = 1080, OutputHeight = 1920, Fps = 30,
            Tracks =
            [
                new Track
                {
                    Type = TrackType.Video, ZIndex = 0,
                    Clips = [new Clip { Id = "c0", SourceId = "vid", StartTime = 0, Duration = 4, Motion = motion }],
                },
                new Track { Type = TrackType.Audio, Clips = [new Clip { SourceId = "aud", Duration = 4 }] },
            ],
            Assets = [new MediaAsset { Id = "vid", Type = MediaType.Video }],
        };
        var paths = new Dictionary<string, string> { ["vid"] = "/tmp/v.mp4", ["aud"] = "/tmp/a.mp3" };

        var plan = _compiler.Compile(timeline, paths);

        Assert.DoesNotContain("zoompan", Norm(plan.FilterComplex));
        Assert.Contains("-ss", plan.InputArgs);
    }

    // --- Transitions (Phase 6) ---

    [Fact]
    public void Compile_TwoClipsWithDissolveTransition_EmitsXfadeWithComputedOffset()
    {
        var timeline = new Timeline
        {
            OutputWidth = 1080, OutputHeight = 1920, Fps = 30,
            Tracks =
            [
                new Track
                {
                    Type = TrackType.Photo, ZIndex = 0,
                    Clips =
                    [
                        new Clip { Id = "c0", SourceId = "img-0", StartTime = 0, Duration = 3.0 },
                        new Clip
                        {
                            Id = "c1", SourceId = "img-1", StartTime = 2.0, Duration = 4.0,
                            TransitionIn = new Transition { Style = TransitionStyle.Dissolve, Duration = 1.0 },
                        },
                    ],
                },
                new Track { Type = TrackType.Audio, Clips = [new Clip { SourceId = "voice", Duration = 6.0 }] },
            ],
        };
        var paths = new Dictionary<string, string>
        {
            ["img-0"] = "/tmp/a.jpg", ["img-1"] = "/tmp/b.jpg", ["voice"] = "/tmp/voice.mp3",
        };

        var plan = _compiler.Compile(timeline, paths);

        const string expected =
            "[0:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1,fps=30[v0];\n" +
            "[1:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1,fps=30[v1];\n" +
            "[v0][v1]xfade=transition=fade:duration=1:offset=2[vout]";
        Assert.Equal(expected, Norm(plan.FilterComplex));
    }

    [Fact]
    public void Compile_MixedCutAndTransitionClips_GroupsIntoSegmentsThenXfades()
    {
        // c0-c1 is a plain cut... no wait: c1 carries the transition (into c1, from c0); c1-c2 is a
        // plain cut. So c1/c2 group into one concat'd segment, which then xfades with c0.
        var timeline = new Timeline
        {
            OutputWidth = 1080, OutputHeight = 1920, Fps = 30,
            Tracks =
            [
                new Track
                {
                    Type = TrackType.Photo, ZIndex = 0,
                    Clips =
                    [
                        new Clip { Id = "c0", SourceId = "img-0", StartTime = 0, Duration = 2.0 },
                        new Clip
                        {
                            Id = "c1", SourceId = "img-1", StartTime = 1.5, Duration = 2.0,
                            TransitionIn = new Transition { Style = TransitionStyle.Dissolve, Duration = 0.5 },
                        },
                        new Clip { Id = "c2", SourceId = "img-2", StartTime = 3.5, Duration = 3.0 },
                    ],
                },
                new Track { Type = TrackType.Audio, Clips = [new Clip { SourceId = "voice", Duration = 6.5 }] },
            ],
        };
        var paths = new Dictionary<string, string>
        {
            ["img-0"] = "/tmp/a.jpg", ["img-1"] = "/tmp/b.jpg", ["img-2"] = "/tmp/c.jpg", ["voice"] = "/tmp/voice.mp3",
        };

        var plan = _compiler.Compile(timeline, paths);

        const string expected =
            "[0:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1,fps=30[v0];\n" +
            "[1:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1,fps=30[v1];\n" +
            "[2:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1,fps=30[v2];\n" +
            "[v1][v2]concat=n=2:v=1:a=0[seg1];" +
            "[v0][seg1]xfade=transition=fade:duration=0.5:offset=1.5[vout]";
        Assert.Equal(expected, Norm(plan.FilterComplex));
    }

    [Fact]
    public void Compile_FadeToBlackTransition_UsesFadeblackXfadeType()
    {
        var timeline = new Timeline
        {
            OutputWidth = 1080, OutputHeight = 1920, Fps = 30,
            Tracks =
            [
                new Track
                {
                    Type = TrackType.Photo, ZIndex = 0,
                    Clips =
                    [
                        new Clip { Id = "c0", SourceId = "img-0", StartTime = 0, Duration = 3.0 },
                        new Clip
                        {
                            Id = "c1", SourceId = "img-1", StartTime = 2.2, Duration = 3.0,
                            TransitionIn = new Transition { Style = TransitionStyle.FadeToBlack, Duration = 0.8 },
                        },
                    ],
                },
                new Track { Type = TrackType.Audio, Clips = [new Clip { SourceId = "voice", Duration = 5.2 }] },
            ],
        };
        var paths = new Dictionary<string, string>
        {
            ["img-0"] = "/tmp/a.jpg", ["img-1"] = "/tmp/b.jpg", ["voice"] = "/tmp/voice.mp3",
        };

        var plan = _compiler.Compile(timeline, paths);

        Assert.Contains("xfade=transition=fadeblack:duration=0.8:offset=2.2", Norm(plan.FilterComplex));
    }

    [Fact]
    public void Compile_TransitionLongerThanEitherClip_IsClampedTo90PercentOfShorterClip()
    {
        var timeline = new Timeline
        {
            OutputWidth = 1080, OutputHeight = 1920, Fps = 30,
            Tracks =
            [
                new Track
                {
                    Type = TrackType.Photo, ZIndex = 0,
                    Clips =
                    [
                        new Clip { Id = "c0", SourceId = "img-0", StartTime = 0, Duration = 1.0 },
                        new Clip
                        {
                            Id = "c1", SourceId = "img-1", StartTime = 0.1, Duration = 1.0,
                            TransitionIn = new Transition { Style = TransitionStyle.Dissolve, Duration = 10 },
                        },
                    ],
                },
                new Track { Type = TrackType.Audio, Clips = [new Clip { SourceId = "voice", Duration = 1.1 }] },
            ],
        };
        var paths = new Dictionary<string, string>
        {
            ["img-0"] = "/tmp/a.jpg", ["img-1"] = "/tmp/b.jpg", ["voice"] = "/tmp/voice.mp3",
        };

        var plan = _compiler.Compile(timeline, paths);

        // Clamped to 90% of the shorter (1.0s) adjacent clip, not the requested 10s.
        Assert.Contains("xfade=transition=fade:duration=0.9:offset=0.1", Norm(plan.FilterComplex));
    }

    [Fact]
    public void Compile_TransitionTooShortAfterClamping_IsDropped_FallsBackToPlainConcat()
    {
        var timeline = new Timeline
        {
            OutputWidth = 1080, OutputHeight = 1920, Fps = 30,
            Tracks =
            [
                new Track
                {
                    Type = TrackType.Photo, ZIndex = 0,
                    Clips =
                    [
                        new Clip { Id = "c0", SourceId = "img-0", StartTime = 0, Duration = 0.05 },
                        new Clip
                        {
                            Id = "c1", SourceId = "img-1", StartTime = 0.05, Duration = 0.05,
                            TransitionIn = new Transition { Style = TransitionStyle.Dissolve, Duration = 0.05 },
                        },
                    ],
                },
                new Track { Type = TrackType.Audio, Clips = [new Clip { SourceId = "voice", Duration = 0.1 }] },
            ],
        };
        var paths = new Dictionary<string, string>
        {
            ["img-0"] = "/tmp/a.jpg", ["img-1"] = "/tmp/b.jpg", ["voice"] = "/tmp/voice.mp3",
        };

        var plan = _compiler.Compile(timeline, paths);

        // 90% of the shorter (0.05s) clip is 0.045s — below MinTransitionDuration, so it's dropped.
        Assert.DoesNotContain("xfade", Norm(plan.FilterComplex));
        Assert.Contains("concat=n=2:v=1:a=0[vout]", Norm(plan.FilterComplex));
    }

    // --- Fade from/to black at the base track's own start/end (Phase 6 scope-cut follow-up) ---

    [Fact]
    public void Compile_FadeInFromBlack_OnFirstClip_EmitsFadeFilter()
    {
        var (timeline, paths) = LegacyLikeCase();
        var photo = timeline.Tracks[0];
        var clips = photo.Clips.ToList();
        clips[0] = clips[0] with { FadeInFromBlack = 1.5 };
        timeline = timeline with { Tracks = [photo with { Clips = clips }, timeline.Tracks[1]] };

        var plan = _compiler.Compile(timeline, paths);

        Assert.Contains(
            "[0:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1,fps=30," +
            "fade=t=in:st=0:d=1.5:color=black[v0]",
            Norm(plan.FilterComplex));
        // The other (unaffected) clips stay byte-identical to the legacy chain.
        Assert.Contains(
            "[1:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1,fps=30[v1]",
            Norm(plan.FilterComplex));
    }

    [Fact]
    public void Compile_FadeOutToBlack_OnLastClip_EmitsFadeFilter()
    {
        var (timeline, paths) = LegacyLikeCase();
        var photo = timeline.Tracks[0];
        var clips = photo.Clips.ToList();
        clips[2] = clips[2] with { FadeOutToBlack = 2.0 }; // c2: Duration = 4.5
        timeline = timeline with { Tracks = [photo with { Clips = clips }, timeline.Tracks[1]] };

        var plan = _compiler.Compile(timeline, paths);

        Assert.Contains(
            "[2:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1,fps=30," +
            "fade=t=out:st=2.5:d=2:color=black[v2]",
            Norm(plan.FilterComplex));
    }

    [Fact]
    public void Compile_FadeToBlack_OnAnyOtherClip_IsIgnored()
    {
        // FadeInFromBlack only honors index 0; FadeOutToBlack only honors the last index — set both
        // (wrongly) on the middle clip and confirm the compiler drops them rather than trusting
        // whatever's stored, mirroring how TransitionIn self-restricts to non-first clips.
        var (timeline, paths) = LegacyLikeCase();
        var photo = timeline.Tracks[0];
        var clips = photo.Clips.ToList();
        clips[1] = clips[1] with { FadeInFromBlack = 1.0, FadeOutToBlack = 1.0 };
        timeline = timeline with { Tracks = [photo with { Clips = clips }, timeline.Tracks[1]] };

        var plan = _compiler.Compile(timeline, paths);

        Assert.Contains(
            "[1:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1,fps=30[v1]",
            Norm(plan.FilterComplex));
    }

    [Fact]
    public void Compile_FadeInFromBlack_LongerThanClip_IsClampedToClipDuration()
    {
        var (timeline, paths) = LegacyLikeCase();
        var photo = timeline.Tracks[0];
        var clips = photo.Clips.ToList();
        clips[0] = clips[0] with { FadeInFromBlack = 10 }; // c0: Duration = 2.5
        timeline = timeline with { Tracks = [photo with { Clips = clips }, timeline.Tracks[1]] };

        var plan = _compiler.Compile(timeline, paths);

        Assert.Contains("fade=t=in:st=0:d=2.5:color=black[v0]", Norm(plan.FilterComplex));
    }

    // --- Video own-audio auto-crossfade to match a visual transition (Phase 6 scope-cut follow-up) ---

    [Fact]
    public void Compile_VideoClipIncludeAudio_AutoCrossfadesToMatchAdjacentTransitions()
    {
        // photo(c0, 3s) -[1s dissolve]-> video(c1, 4s, IncludeAudio) -[0.6s dissolve]-> photo(c2, 2s).
        // The video's own audio should fade in over the incoming transition and fade out over the
        // outgoing one, with no manual FadeIn/FadeOut set.
        var timeline = new Timeline
        {
            OutputWidth = 1080, OutputHeight = 1920, Fps = 30,
            Tracks =
            [
                new Track
                {
                    Type = TrackType.Photo, ZIndex = 0,
                    Clips =
                    [
                        new Clip { Id = "c0", SourceId = "img-0", StartTime = 0, Duration = 3 },
                        new Clip { Id = "c2", SourceId = "img-1", StartTime = 5.4, Duration = 2,
                            TransitionIn = new Transition { Style = TransitionStyle.Dissolve, Duration = 0.6 } },
                    ],
                },
                new Track
                {
                    Type = TrackType.Video, ZIndex = 0,
                    Clips =
                    [
                        new Clip
                        {
                            Id = "c1", SourceId = "vid", StartTime = 2, Duration = 4, IncludeAudio = true,
                            TransitionIn = new Transition { Style = TransitionStyle.Dissolve, Duration = 1 },
                        },
                    ],
                },
                new Track { Type = TrackType.Audio, Clips = [new Clip { SourceId = "voice", Duration = 6 }] },
            ],
            Assets = [new MediaAsset { Id = "vid", Type = MediaType.Video }],
        };
        var paths = new Dictionary<string, string>
        {
            ["img-0"] = "/tmp/a.jpg", ["img-1"] = "/tmp/b.jpg", ["vid"] = "/tmp/v.mp4", ["voice"] = "/tmp/voice.mp3",
        };

        var plan = _compiler.Compile(timeline, paths);

        // Input order is start-time order: c0 (0) -> c1 (2) -> c2 (5.4), so the video's own audio is
        // input index 1 — its afade-in (1s, matching the incoming transition) and afade-out (0.6s,
        // matching the outgoing one) both derive purely from the transitions, no manual fade set.
        Assert.Contains(
            "[1:a]afade=t=in:st=0:d=1,afade=t=out:st=3.4:d=0.6,adelay=2000:all=1",
            Norm(plan.FilterComplex));
    }

    [Fact]
    public void Compile_VideoClipIncludeAudio_ManualFadeLargerThanTransition_KeepsManualFade()
    {
        var (timeline, paths) = PhotoPlusVideoCase(); // photo c0 (3s) then video vc (4s) at t=3
        timeline = timeline with
        {
            Tracks = timeline.Tracks.Select(t => t.Type != TrackType.Video ? t : t with
            {
                Clips = [t.Clips[0] with
                {
                    IncludeAudio = true,
                    FadeIn = 2, // larger than the (clamped) 1s transition below
                    TransitionIn = new Transition { Style = TransitionStyle.Dissolve, Duration = 1 },
                }],
            }).ToList(),
        };

        var plan = _compiler.Compile(timeline, paths);

        // The manual FadeIn (2s) wins over the transition-derived auto-fade (1s) — never shortened.
        Assert.Contains("afade=t=in:st=0:d=2", Norm(plan.FilterComplex));
        Assert.DoesNotContain("afade=t=in:st=0:d=1,", Norm(plan.FilterComplex));
    }
}
