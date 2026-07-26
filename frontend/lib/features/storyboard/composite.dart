import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// Client-side frame compositing for the mp4 export: each scene becomes a
/// full 1080x1920 PNG with the image cover-fitted and (optionally) the
/// narration burned in as a caption. Done on-device (not ffmpeg drawtext) so
/// captions render in the app's Manrope font and the backend needs no
/// freetype support — mirrors the web frontend's `composite.ts`.
const _width = 1080.0;
const _height = 1920.0;

const _captionStyle = TextStyle(
  fontFamily: 'Manrope',
  fontWeight: FontWeight.w600,
  fontSize: 54,
  color: Colors.white,
  height: 1.0,
);

Future<Uint8List> compositeFrame({
  required Uint8List? image,
  required String narration,
  required bool captions,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, _width, _height));

  canvas.drawRect(
    const Rect.fromLTWH(0, 0, _width, _height),
    Paint()..color = const Color(0xFF12151A),
  );

  if (image != null) {
    final codec = await ui.instantiateImageCodec(image);
    final frame = await codec.getNextFrame();
    final decoded = frame.image;
    final scale = math.max(_width / decoded.width, _height / decoded.height);
    final dw = decoded.width * scale;
    final dh = decoded.height * scale;
    canvas.drawImageRect(
      decoded,
      Rect.fromLTWH(0, 0, decoded.width.toDouble(), decoded.height.toDouble()),
      Rect.fromLTWH((_width - dw) / 2, (_height - dh) / 2, dw, dh),
      Paint(),
    );
    decoded.dispose();
  } else {
    final icon = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(Icons.movie_rounded.codePoint),
        style: TextStyle(
          fontFamily: Icons.movie_rounded.fontFamily,
          package: Icons.movie_rounded.fontPackage,
          fontSize: 140,
          color: const Color(0xFF2E343D),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    icon.paint(canvas, Offset((_width - icon.width) / 2, (_height - icon.height) / 2));
  }

  if (captions && narration.trim().isNotEmpty) {
    _drawCaption(canvas, narration.trim(), _width, _height);
  }

  final picture = recorder.endRecording();
  final rendered = await picture.toImage(_width.toInt(), _height.toInt());
  final byteData = await rendered.toByteData(format: ui.ImageByteFormat.png);
  rendered.dispose();
  return byteData!.buffer.asUint8List();
}

/// Rasterizes a caption to a transparent full-frame PNG for the timeline
/// editor's alpha-overlay export path (the backend composites it via ffmpeg
/// `overlay`, since there's no server-side drawtext support). Mirrors the web
/// frontend's `renderCaptionOverlay`. Blank text yields a fully transparent
/// frame — callers should skip those rather than upload a no-op overlay.
Future<Uint8List> renderCaptionOverlay(String text, {double w = _width, double h = _height}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w, h));
  if (text.trim().isNotEmpty) {
    _drawCaption(canvas, text.trim(), w, h);
  }
  final picture = recorder.endRecording();
  final rendered = await picture.toImage(w.toInt(), h.toInt());
  final byteData = await rendered.toByteData(format: ui.ImageByteFormat.png);
  rendered.dispose();
  return byteData!.buffer.asUint8List();
}

double _measureWidth(String text, TextStyle style) {
  final tp = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
  )..layout();
  return tp.width;
}

void _drawCaption(Canvas canvas, String text, double w, double h) {
  final maxWidth = w - 200;
  final lines = <String>[];
  var line = '';
  for (final word in text.split(RegExp(r'\s+'))) {
    final candidate = line.isEmpty ? word : '$line $word';
    if (line.isNotEmpty && _measureWidth(candidate, _captionStyle) > maxWidth) {
      lines.add(line);
      line = word;
    } else {
      line = candidate;
    }
  }
  if (line.isNotEmpty) lines.add(line);
  if (lines.isEmpty) return;

  const lineHeight = 74.0;
  const padX = 40.0;
  const padY = 30.0;
  final blockHeight = lines.length * lineHeight;
  final bottom = h - 320;
  final top = bottom - blockHeight;
  final widest = lines.map((l) => _measureWidth(l, _captionStyle)).reduce(math.max);

  canvas.drawRRect(
    RRect.fromRectAndRadius(
      Rect.fromLTWH(w / 2 - widest / 2 - padX, top - padY, widest + padX * 2, blockHeight + padY * 2),
      const Radius.circular(20),
    ),
    Paint()..color = Colors.black.withValues(alpha: 0.45),
  );

  for (var i = 0; i < lines.length; i++) {
    final tp = TextPainter(
      text: TextSpan(text: lines[i], style: _captionStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    final slotTop = top + i * lineHeight;
    tp.paint(canvas, Offset(w / 2 - tp.width / 2, slotTop + (lineHeight - tp.height) / 2));
  }
}
