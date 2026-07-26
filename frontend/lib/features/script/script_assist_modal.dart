import 'package:flutter/material.dart';
import '../../core/api_client.dart';
import '../../core/theme.dart';

const _lengths = [30, 60, 90, 120];

/// "Write with AI": topic (+ optional instructions) → voiceover script.
/// Returns the generated script, or null if cancelled. Mirrors the web
/// frontend's `ScriptAssistModal`.
Future<String?> showScriptAssistModal(
  BuildContext context, {
  required ApiClient apiClient,
}) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: _ScriptAssistBody(apiClient: apiClient),
      ),
    ),
  );
}

class _ScriptAssistBody extends StatefulWidget {
  final ApiClient apiClient;

  const _ScriptAssistBody({required this.apiClient});

  @override
  State<_ScriptAssistBody> createState() => _ScriptAssistBodyState();
}

class _ScriptAssistBodyState extends State<_ScriptAssistBody> {
  final _topicController = TextEditingController();
  final _instructionsController = TextEditingController();
  int _targetSeconds = 60;
  bool _generating = false;
  String? _error;

  @override
  void dispose() {
    _topicController.dispose();
    _instructionsController.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    final topic = _topicController.text.trim();
    if (topic.isEmpty || _generating) return;
    setState(() {
      _generating = true;
      _error = null;
    });
    try {
      final script = await widget.apiClient.generateScript(
        topic: topic,
        instructions: _instructionsController.text.trim().isEmpty
            ? null
            : _instructionsController.text.trim(),
        targetSeconds: _targetSeconds,
      );
      if (mounted) Navigator.pop(context, script);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.brand;
    final canGenerate = _topicController.text.trim().isNotEmpty && !_generating;
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(AppRadii.card),
      ),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Write script with AI',
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
          const SizedBox(height: 6),
          Text(
            'Topic',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: c.text),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _topicController,
            autofocus: true,
            maxLines: 3,
            minLines: 2,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: 'What should the video be about?',
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Style / instructions (optional)',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: c.text),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _instructionsController,
            decoration: const InputDecoration(
              hintText: 'e.g. upbeat, aimed at beginners, end with a question',
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Length',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: c.text),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final s in _lengths)
                ChoiceChip(
                  label: Text('~${s}s'),
                  selected: _targetSeconds == s,
                  showCheckmark: false,
                  onSelected: (_) => setState(() => _targetSeconds = s),
                  backgroundColor: c.surface,
                  selectedColor: c.blueDeep.withValues(alpha: 0.28),
                  side: BorderSide(color: _targetSeconds == s ? c.blueDeep : c.outline),
                  labelStyle: TextStyle(
                    color: c.text,
                    fontWeight: _targetSeconds == s ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: c.danger.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: c.danger.withValues(alpha: 0.4)),
              ),
              child: Text(
                _error!,
                style: TextStyle(color: c.text, fontSize: 12.5, height: 1.4),
              ),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: canGenerate ? _generate : null,
            icon: _generating
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.auto_awesome_rounded, size: 18),
            label: Text(_generating ? 'Writing…' : 'Write script'),
          ),
        ],
      ),
    );
  }
}
