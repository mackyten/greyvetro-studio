import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/api_client.dart';
import '../../core/theme.dart';
import '../script/scene_prompt.dart';
import 'transcript_model.dart';

enum _View { text, timings, scenes }

String _fmtTime(double seconds) {
  final m = seconds ~/ 60;
  final s = seconds - m * 60;
  return '$m:${s.toStringAsFixed(2).padLeft(5, '0')}';
}

/// Shows a clip's word-timestamped Scribe transcript, plus AI-proposed scene
/// prompts generated on demand. Mirrors the web frontend's `TranscriptModal`.
Future<void> showTranscriptModal(
  BuildContext context, {
  required String title,
  required Transcript transcript,
  required ApiClient apiClient,
}) {
  return showDialog(
    context: context,
    builder: (ctx) => Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 640),
        child: _TranscriptModalBody(
          title: title,
          transcript: transcript,
          apiClient: apiClient,
        ),
      ),
    ),
  );
}

class _TranscriptModalBody extends StatefulWidget {
  final String title;
  final Transcript transcript;
  final ApiClient apiClient;

  const _TranscriptModalBody({
    required this.title,
    required this.transcript,
    required this.apiClient,
  });

  @override
  State<_TranscriptModalBody> createState() => _TranscriptModalBodyState();
}

class _TranscriptModalBodyState extends State<_TranscriptModalBody> {
  _View _view = _View.text;
  List<ScenePrompt>? _scenes;
  bool _generating = false;

  List<TranscriptWord> get _words =>
      widget.transcript.words.where((w) => w.type == 'word').toList();

  double get _duration =>
      widget.transcript.words.isEmpty ? 0 : widget.transcript.words.last.end;

  Future<void> _copy(String text, String message) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _showScenes() async {
    if (_scenes != null) {
      setState(() => _view = _View.scenes);
      return;
    }
    if (_generating) return;
    setState(() => _generating = true);
    try {
      final scenes = await widget.apiClient.generateScenes(transcript: widget.transcript);
      if (!mounted) return;
      setState(() {
        _scenes = scenes;
        _view = _View.scenes;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Scene generation failed: $e'),
            backgroundColor: context.brand.danger,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.brand;
    final words = _words;
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(AppRadii.card),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Transcript — ${widget.title}',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: c.text,
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.close_rounded, color: c.text3),
                  tooltip: 'Close',
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: c.outline),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Text(
              [
                if (widget.transcript.languageCode.isNotEmpty)
                  widget.transcript.languageCode.toUpperCase(),
                '${words.length} words',
                _fmtTime(_duration),
                if (_scenes != null) '${_scenes!.length} scenes',
              ].join(' · '),
              style: AppFonts.monoStyle(size: 11.5, color: c.text3),
            ),
          ),
          Flexible(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              child: switch (_view) {
                _View.text => SingleChildScrollView(
                    child: Text(
                      widget.transcript.text,
                      style: TextStyle(color: c.text2, height: 1.6, fontSize: 14),
                    ),
                  ),
                _View.timings => ListView.builder(
                    itemCount: words.length,
                    itemBuilder: (ctx, i) {
                      final w = words[i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: RichText(
                          text: TextSpan(
                            children: [
                              TextSpan(
                                text: '${_fmtTime(w.start)}–${_fmtTime(w.end)}  ',
                                style: AppFonts.monoStyle(size: 12, color: c.blueDeep),
                              ),
                              TextSpan(
                                text: w.text,
                                style: TextStyle(color: c.text2, fontSize: 13.5),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                _View.scenes => _scenes == null
                    ? const SizedBox.shrink()
                    : ListView.separated(
                        itemCount: _scenes!.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 12),
                        itemBuilder: (ctx, i) {
                          final s = _scenes![i];
                          return Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: c.surfaceMuted,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: c.outline),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        '${i + 1} · ${_fmtTime(s.start)}–${_fmtTime(s.end)}',
                                        style: AppFonts.monoStyle(size: 11.5, color: c.text3),
                                      ),
                                    ),
                                    TextButton.icon(
                                      onPressed: () => _copy(
                                        s.imagePrompt,
                                        'Scene ${i + 1} prompt copied.',
                                      ),
                                      icon: const Icon(Icons.content_copy_rounded, size: 15),
                                      label: const Text('Copy prompt'),
                                      style: TextButton.styleFrom(
                                        foregroundColor: c.blueDeep,
                                        padding: const EdgeInsets.symmetric(horizontal: 8),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  '“${s.narration}”',
                                  style: TextStyle(
                                    color: c.text,
                                    fontStyle: FontStyle.italic,
                                    fontSize: 13,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  s.imagePrompt,
                                  style: TextStyle(color: c.text2, fontSize: 12.5, height: 1.4),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              },
            ),
          ),
          Divider(height: 1, color: c.outline),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                if (_view != _View.text)
                  OutlinedButton(
                    onPressed: () => setState(() => _view = _View.text),
                    child: const Text('Show text'),
                  ),
                if (_view == _View.text) ...[
                  OutlinedButton.icon(
                    onPressed: () => _copy(widget.transcript.text, 'Transcript copied.'),
                    icon: const Icon(Icons.content_copy_rounded, size: 16),
                    label: const Text('Copy text'),
                  ),
                  OutlinedButton(
                    onPressed: () => setState(() => _view = _View.timings),
                    child: const Text('Show word timings'),
                  ),
                ],
                FilledButton.icon(
                  onPressed: _generating ? null : _showScenes,
                  icon: _generating
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.movie_outlined, size: 17),
                  label: Text(_generating ? 'Generating scenes…' : 'Scene prompts'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
