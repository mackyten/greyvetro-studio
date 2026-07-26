import 'dart:typed_data';

/// One composited scene frame + its timing, for the legacy `/render` upload.
class RenderScenePayload {
  final double start;
  final double end;

  /// A fully composited 1080x1920 frame (see `composite.dart`).
  final Uint8List image;

  const RenderScenePayload({required this.start, required this.end, required this.image});
}
