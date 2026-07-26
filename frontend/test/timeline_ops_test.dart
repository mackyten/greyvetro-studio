import 'package:flutter_test/flutter_test.dart';
import 'package:greyvetro_tts/features/timeline/model/timeline.dart';
import 'package:greyvetro_tts/features/timeline/model/timeline_ops.dart';

Timeline _seed({List<double> durations = const [2, 3, 4]}) {
  var cursor = 0.0;
  final photoClips = <TimelineClip>[];
  final captionClips = <TimelineClip>[];
  for (var i = 0; i < durations.length; i++) {
    final id = 'scene-$i';
    photoClips.add(TimelineClip(
      id: 'photo-$id',
      sourceId: id,
      startTime: cursor,
      duration: durations[i],
      inPoint: 0,
      outPoint: durations[i],
    ));
    captionClips.add(TimelineClip(
      id: 'caption-photo-$id',
      sourceId: id,
      startTime: cursor,
      duration: durations[i],
      inPoint: 0,
      outPoint: durations[i],
      text: 'Narration $i',
    ));
    cursor += durations[i];
  }
  return Timeline(
    id: 'proj',
    tracks: [
      Track(id: 'photo', type: TrackType.photo, clips: photoClips),
      Track(
        id: 'audio',
        type: TrackType.audio,
        clips: [
          TimelineClip(id: 'voiceover', sourceId: 'voiceover', startTime: 0, duration: cursor, outPoint: cursor),
        ],
      ),
      Track(id: 'caption', type: TrackType.caption, zIndex: 1, clips: captionClips),
    ],
    assets: [
      for (var i = 0; i < durations.length; i++) MediaAsset(id: 'scene-$i', type: MediaType.image),
      MediaAsset(id: 'voiceover', type: MediaType.audio, duration: cursor),
    ],
  );
}

void main() {
  group('reanchor', () {
    test('lays photo clips out contiguously from 0 in array order', () {
      final t = _seed();
      final photo = t.trackOfType(TrackType.photo)!;
      final shuffled = [photo.clips[2], photo.clips[0], photo.clips[1]];
      final withShuffledOrder = t.copyWith(
        tracks: [for (final tr in t.tracks) tr.id == photo.id ? tr.copyWith(clips: shuffled) : tr],
      );

      final result = reanchor(withShuffledOrder);
      final clips = result.trackOfType(TrackType.photo)!.clips;
      expect(clips[0].startTime, 0);
      expect(clips[1].startTime, clips[0].duration);
      expect(clips[2].startTime, clips[0].duration + clips[1].duration);
    });

    test('rebuilds captions to mirror the photo track by source id', () {
      final t = _seed();
      final result = reanchor(t);
      final photo = result.trackOfType(TrackType.photo)!.clips;
      final captions = result.trackOfType(TrackType.caption)!.clips;
      expect(captions.length, photo.length);
      for (var i = 0; i < photo.length; i++) {
        expect(captions[i].sourceId, photo[i].sourceId);
        expect(captions[i].startTime, photo[i].startTime);
        expect(captions[i].duration, photo[i].duration);
        expect(captions[i].text, 'Narration $i');
      }
    });

    test('leaves the audio track untouched', () {
      final t = _seed();
      final before = t.trackOfType(TrackType.audio)!.clips.single;
      final after = reanchor(t).trackOfType(TrackType.audio)!.clips.single;
      expect(after.startTime, before.startTime);
      expect(after.duration, before.duration);
    });
  });

  group('moveClip', () {
    test('reorders a clip in front of the target and re-anchors', () {
      final t = _seed(); // scene-0 (2s), scene-1 (3s), scene-2 (4s)
      final photo = t.trackOfType(TrackType.photo)!.clips;
      final result = moveClip(t, photo[2].id, photo[0].id); // move scene-2 to the front
      final clips = result.trackOfType(TrackType.photo)!.clips;
      expect(clips.map((c) => c.sourceId), ['scene-2', 'scene-0', 'scene-1']);
      expect(clips[0].startTime, 0);
      expect(clips[1].startTime, 4); // scene-2's duration
      expect(clips[2].startTime, 4 + 2);
    });

    test('is a no-op for an unknown clip id', () {
      final t = _seed();
      final result = moveClip(t, 'nope', t.trackOfType(TrackType.photo)!.clips.first.id);
      expect(result, same(t));
    });
  });

  group('trimClip', () {
    test('changes duration and re-anchors downstream clips', () {
      final t = _seed(); // 2, 3, 4
      final photo = t.trackOfType(TrackType.photo)!.clips;
      final result = trimClip(t, photo[0].id, 5); // grow first clip 2 -> 5
      final clips = result.trackOfType(TrackType.photo)!.clips;
      expect(clips[0].duration, 5);
      expect(clips[0].inPoint, 0);
      expect(clips[0].outPoint, 5);
      expect(clips[1].startTime, 5);
      expect(clips[2].startTime, 5 + 3);
    });

    test('clamps below the minimum clip length', () {
      final t = _seed();
      final photo = t.trackOfType(TrackType.photo)!.clips;
      final result = trimClip(t, photo[0].id, 0.01);
      expect(result.trackOfType(TrackType.photo)!.clips[0].duration, minClipDuration);
    });
  });

  group('splitClip', () {
    test('splits into two clips over the same source, re-anchored', () {
      final t = _seed(); // scene-1 is 3s long, starts at 2
      final photo = t.trackOfType(TrackType.photo)!.clips;
      final result = splitClip(t, photo[1].id, 1.2);
      final clips = result.trackOfType(TrackType.photo)!.clips;
      expect(clips.length, 4);
      expect(clips[1].sourceId, 'scene-1');
      expect(clips[2].sourceId, 'scene-1');
      expect(clips[1].duration, closeTo(1.2, 1e-9));
      expect(clips[2].duration, closeTo(1.8, 1e-9));
      // Contiguous overall.
      expect(clips[3].startTime, closeTo(clips[0].duration + clips[1].duration + clips[2].duration, 1e-9));
      // Both halves carry the scene's caption text.
      final captions = result.trackOfType(TrackType.caption)!.clips;
      expect(captions[1].text, 'Narration 1');
      expect(captions[2].text, 'Narration 1');
    });

    test('is a no-op when the offset is too close to either edge', () {
      final t = _seed();
      final photo = t.trackOfType(TrackType.photo)!.clips;
      final clip = photo[0]; // 2s long
      expect(splitClip(t, clip.id, 0.1), same(t));
      expect(splitClip(t, clip.id, 1.95), same(t));
    });
  });

  group('deleteClip', () {
    test('removes a clip and closes the gap', () {
      final t = _seed();
      final photo = t.trackOfType(TrackType.photo)!.clips;
      final result = deleteClip(t, photo[1].id);
      final clips = result.trackOfType(TrackType.photo)!.clips;
      expect(clips.map((c) => c.sourceId), ['scene-0', 'scene-2']);
      expect(clips[1].startTime, clips[0].duration);
    });

    test('refuses to remove the last remaining clip', () {
      final t = _seed(durations: [2]);
      final photo = t.trackOfType(TrackType.photo)!.clips;
      final result = deleteClip(t, photo.single.id);
      expect(result, same(t));
      expect(result.trackOfType(TrackType.photo)!.clips, hasLength(1));
    });
  });

  group('cropFromZoomPan / zoomPanFromCrop', () {
    test('round-trips zoom + pan-center through a crop rect', () {
      for (final z in [1.0, 1.5, 2.0, maxZoom]) {
        final crop = cropFromZoomPan(z, 0.5, 0.5);
        final back = zoomPanFromCrop(crop);
        expect(back.zoom, closeTo(z, 1e-9));
        expect(back.panX, closeTo(0.5, 1e-9));
        expect(back.panY, closeTo(0.5, 1e-9));
      }
    });

    test('clamps the pan-center so the crop box stays in-bounds', () {
      final crop = cropFromZoomPan(2, 0, 0); // top-left corner, half-size box
      expect(crop.x, greaterThanOrEqualTo(0));
      expect(crop.y, greaterThanOrEqualTo(0));
      expect(crop.x + crop.width, lessThanOrEqualTo(1.0001));
      expect(crop.y + crop.height, lessThanOrEqualTo(1.0001));
    });

    test('clamps zoom above maxZoom and below 1', () {
      expect(cropFromZoomPan(maxZoom + 5, 0.5, 0.5).width, closeTo(1 / maxZoom, 1e-9));
      expect(cropFromZoomPan(0, 0.5, 0.5).width, closeTo(1, 1e-9));
    });

    test('zoomPanFromCrop defaults to (1, 0.5, 0.5) for null/degenerate crop', () {
      expect(zoomPanFromCrop(null), (zoom: 1.0, panX: 0.5, panY: 0.5));
      expect(zoomPanFromCrop(const CropRect(width: 0)), (zoom: 1.0, panX: 0.5, panY: 0.5));
    });
  });

  group('setCrop', () {
    test('sets a non-full crop on the target clip only', () {
      final t = _seed();
      final photo = t.trackOfType(TrackType.photo)!.clips;
      final crop = cropFromZoomPan(2, 0.5, 0.5);
      final result = setCrop(t, photo[1].id, crop);
      final clips = result.trackOfType(TrackType.photo)!.clips;
      expect(clips[1].crop, crop);
      expect(clips[0].crop, isNull);
      expect(clips[2].crop, isNull);
    });

    test('clears back to null on a full-frame rect', () {
      final t = _seed();
      final photo = t.trackOfType(TrackType.photo)!.clips;
      final withCrop = setCrop(t, photo[0].id, cropFromZoomPan(2, 0.5, 0.5));
      final result = setCrop(withCrop, photo[0].id, const CropRect());
      expect(result.trackOfType(TrackType.photo)!.clips[0].crop, isNull);
    });

    test('does not reanchor — sibling placement is untouched', () {
      final t = _seed();
      final photo = t.trackOfType(TrackType.photo)!.clips;
      final before = photo.map((c) => (c.startTime, c.duration)).toList();
      final result = setCrop(t, photo[1].id, cropFromZoomPan(1.5, 0.3, 0.3));
      final after = result.trackOfType(TrackType.photo)!.clips.map((c) => (c.startTime, c.duration)).toList();
      expect(after, before);
    });

    test('is a no-op for an unknown clip id', () {
      final t = _seed();
      final result = setCrop(t, 'nope', cropFromZoomPan(2, 0.5, 0.5));
      expect(result, same(t));
    });
  });

  group('setRotation', () {
    test('sets a tilt on the target clip only', () {
      final t = _seed();
      final photo = t.trackOfType(TrackType.photo)!.clips;
      final result = setRotation(t, photo[2].id, 12.5);
      final clips = result.trackOfType(TrackType.photo)!.clips;
      expect(clips[2].rotation, 12.5);
      expect(clips[0].rotation, isNull);
      expect(clips[1].rotation, isNull);
    });

    test('collapses a near-zero value back to null', () {
      final t = _seed();
      final photo = t.trackOfType(TrackType.photo)!.clips;
      final withTilt = setRotation(t, photo[0].id, 10);
      final result = setRotation(withTilt, photo[0].id, 0.005);
      expect(result.trackOfType(TrackType.photo)!.clips[0].rotation, isNull);
    });

    test('does not reanchor — sibling placement is untouched', () {
      final t = _seed();
      final photo = t.trackOfType(TrackType.photo)!.clips;
      final before = photo.map((c) => (c.startTime, c.duration)).toList();
      final result = setRotation(t, photo[1].id, -20);
      final after = result.trackOfType(TrackType.photo)!.clips.map((c) => (c.startTime, c.duration)).toList();
      expect(after, before);
    });
  });

  group('addOverlayImage', () {
    test('adds a track+clip above the base zIndex with defaults registered', () {
      final t = _seed(); // durations [2, 3, 4] -> totalDuration 9
      final result = addOverlayImage(t, 'logo-1');
      final overlayTrack = result.tracks.firstWhere((tr) => tr.id == 'overlay-logo-1');
      expect(overlayTrack.type, TrackType.photo);
      expect(overlayTrack.zIndex, greaterThan(0)); // base photo/audio/caption tracks are all zIndex 0/1 already
      expect(overlayTrack.clips, hasLength(1));

      final clip = overlayTrack.clips.single;
      expect(clip.id, 'overlay-logo-1');
      expect(clip.sourceId, 'logo-1');
      expect(clip.startTime, 0);
      expect(clip.duration, closeTo(9, 1e-9));
      expect(clip.position, const NormalizedPoint(x: 0.62, y: 0.04));
      expect(clip.scale, 0.3);

      final asset = result.assets.firstWhere((a) => a.id == 'logo-1');
      expect(asset.type, MediaType.image);
    });

    test('does not disturb the base photo track', () {
      final t = _seed();
      final before = t.trackOfType(TrackType.photo)!.clips;
      final result = addOverlayImage(t, 'logo-1');
      final after = result.trackOfType(TrackType.photo)!.clips;
      expect(after.map((c) => (c.id, c.startTime, c.duration)), before.map((c) => (c.id, c.startTime, c.duration)));
    });

    test('a second overlay stacks above the first', () {
      final t = _seed();
      final withOne = addOverlayImage(t, 'logo-1');
      final withTwo = addOverlayImage(withOne, 'logo-2');
      final z1 = withTwo.tracks.firstWhere((tr) => tr.id == 'overlay-logo-1').zIndex;
      final z2 = withTwo.tracks.firstWhere((tr) => tr.id == 'overlay-logo-2').zIndex;
      expect(z2, greaterThan(z1));
    });
  });

  group('setOverlayTransform', () {
    test('updates only the target overlay clip', () {
      final t = addOverlayImage(_seed(), 'logo-1');
      final result = setOverlayTransform(t, 'overlay-logo-1', position: const NormalizedPoint(x: 0.1, y: 0.2), scale: 0.5);
      final clip = result.tracks.firstWhere((tr) => tr.id == 'overlay-logo-1').clips.single;
      expect(clip.position, const NormalizedPoint(x: 0.1, y: 0.2));
      expect(clip.scale, 0.5);
      // Base track untouched.
      expect(result.trackOfType(TrackType.photo)!.clips, t.trackOfType(TrackType.photo)!.clips);
    });

    test('leaves unspecified fields as they were', () {
      final t = addOverlayImage(_seed(), 'logo-1');
      final result = setOverlayTransform(t, 'overlay-logo-1', scale: 0.6);
      final clip = result.tracks.firstWhere((tr) => tr.id == 'overlay-logo-1').clips.single;
      expect(clip.position, const NormalizedPoint(x: 0.62, y: 0.04));
      expect(clip.scale, 0.6);
    });
  });

  group('removeTrack', () {
    test('drops the track but leaves the asset in place', () {
      final t = addOverlayImage(_seed(), 'logo-1');
      final result = removeTrack(t, 'overlay-logo-1');
      expect(result.tracks.any((tr) => tr.id == 'overlay-logo-1'), isFalse);
      expect(result.assets.any((a) => a.id == 'logo-1'), isTrue);
    });
  });

  group('baseVisualTrack / isOverlayTrack (regression: trackOfType(photo) is not enough once an overlay exists)', () {
    test('baseVisualTrack still finds the original base track, not the overlay', () {
      final t = addOverlayImage(_seed(), 'logo-1');
      final base = baseVisualTrack(t);
      expect(base, isNotNull);
      expect(base!.id, t.trackOfType(TrackType.photo)!.id);
      expect(base.zIndex, 0);
    });

    test('isOverlayTrack correctly distinguishes base vs. overlay', () {
      final t = addOverlayImage(_seed(), 'logo-1');
      final baseId = t.trackOfType(TrackType.photo)!.id;
      expect(isOverlayTrack(t, baseId), isFalse);
      expect(isOverlayTrack(t, 'overlay-logo-1'), isTrue);
    });

    test('moveClip/trimClip/splitClip/deleteClip/setCrop/setRotation stay scoped to the base track once an overlay exists', () {
      final withOverlay = addOverlayImage(_seed(), 'logo-1');
      final overlayBefore = withOverlay.tracks.firstWhere((tr) => tr.id == 'overlay-logo-1').clips.single;
      final basePhoto = withOverlay.trackOfType(TrackType.photo)!.clips;

      final moved = moveClip(withOverlay, basePhoto[2].id, basePhoto[0].id);
      expect(moved.trackOfType(TrackType.photo)!.clips.map((c) => c.sourceId), ['scene-2', 'scene-0', 'scene-1']);
      expect(moved.tracks.firstWhere((tr) => tr.id == 'overlay-logo-1').clips.single, overlayBefore);

      final trimmed = trimClip(withOverlay, basePhoto[0].id, 5);
      expect(trimmed.trackOfType(TrackType.photo)!.clips[0].duration, 5);
      expect(trimmed.tracks.firstWhere((tr) => tr.id == 'overlay-logo-1').clips.single, overlayBefore);

      final split = splitClip(withOverlay, basePhoto[1].id, 1.2);
      expect(split.trackOfType(TrackType.photo)!.clips, hasLength(4));
      expect(split.tracks.firstWhere((tr) => tr.id == 'overlay-logo-1').clips.single, overlayBefore);

      final deleted = deleteClip(withOverlay, basePhoto[1].id);
      expect(deleted.trackOfType(TrackType.photo)!.clips.map((c) => c.sourceId), ['scene-0', 'scene-2']);
      expect(deleted.tracks.firstWhere((tr) => tr.id == 'overlay-logo-1').clips.single, overlayBefore);

      final cropped = setCrop(withOverlay, basePhoto[0].id, cropFromZoomPan(2, 0.5, 0.5));
      expect(cropped.trackOfType(TrackType.photo)!.clips[0].crop, isNotNull);
      expect(cropped.tracks.firstWhere((tr) => tr.id == 'overlay-logo-1').clips.single, overlayBefore);

      final rotated = setRotation(withOverlay, basePhoto[0].id, 15);
      expect(rotated.trackOfType(TrackType.photo)!.clips[0].rotation, 15);
      expect(rotated.tracks.firstWhere((tr) => tr.id == 'overlay-logo-1').clips.single, overlayBefore);

      // And an id that only exists on the overlay track is correctly rejected by every base-only op.
      expect(moveClip(withOverlay, 'overlay-logo-1', basePhoto[0].id), same(withOverlay));
      expect(trimClip(withOverlay, 'overlay-logo-1', 5), same(withOverlay));
      expect(deleteClip(withOverlay, 'overlay-logo-1'), same(withOverlay));
      expect(setCrop(withOverlay, 'overlay-logo-1', cropFromZoomPan(2, 0.5, 0.5)), same(withOverlay));
      expect(setRotation(withOverlay, 'overlay-logo-1', 15), same(withOverlay));
    });
  });
}
