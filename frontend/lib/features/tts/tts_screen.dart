import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/api_client.dart';
import '../../core/audio_player.dart';
import '../../core/audio_scrubber.dart';
import '../../core/theme.dart';
import '../gallery/gallery_repository.dart';
import '../presets/preset.dart';
import '../presets/preset_repository.dart';
import '../projects/project_repository.dart';
import '../projects/project_select.dart';
import '../script/script_assist_modal.dart';
import '../voices/voice_model.dart';
import '../voices/voice_picker.dart';

class TtsScreen extends StatefulWidget {
  final ApiClient apiClient;
  final AudioPlayer player;
  final GalleryRepository gallery;
  final PresetRepository presets;
  final ProjectRepository projects;

  /// Called after a generation is saved to the gallery, so the gallery tab
  /// can refresh.
  final VoidCallback onSavedToGallery;

  /// Called after a generation consumes credits, so the sidebar credit badge
  /// can refresh.
  final VoidCallback onGenerated;

  /// Called after a preset is created here, so the Presets tab can refresh.
  final VoidCallback onPresetsChanged;

  /// Called after a project is created here, so the Gallery tab can refresh.
  final VoidCallback onProjectsChanged;

  const TtsScreen({
    super.key,
    required this.apiClient,
    required this.player,
    required this.gallery,
    required this.presets,
    required this.projects,
    required this.onSavedToGallery,
    required this.onGenerated,
    required this.onPresetsChanged,
    required this.onProjectsChanged,
  });

  @override
  State<TtsScreen> createState() => TtsScreenState();
}

class TtsScreenState extends State<TtsScreen> {
  final _textController = TextEditingController();
  VoiceModel? _selectedVoice;
  bool _loading = false;
  Uint8List? _audioBytes;
  String? _tempAudioPath;
  bool _saved = false;
  String? _error;

  double _stability = 0.5;
  double _similarity = 0.75;
  double _style = 0.0;
  // On by default: this is the strongest lever for making a cloned voice
  // resemble the original speaker.
  bool _speakerBoost = true;
  bool _showAdvanced = false;

  List<Preset> _presets = [];

  final _projectSelectKey = GlobalKey<ProjectSelectState>();
  String? _activeProjectId;

  @override
  void initState() {
    super.initState();
    _textController.addListener(() => setState(() {}));
    reloadPresets();
  }

  Future<void> reloadPresets() async {
    final presets = await widget.presets.load();
    if (mounted) setState(() => _presets = presets);
  }

  /// Refreshes the Project selector (e.g. after the Gallery tab creates,
  /// renames, or deletes a project).
  Future<void> reloadProjects() async {
    await _projectSelectKey.currentState?.refresh();
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  /// Load a saved recording back into the composer (edit & regenerate flow).
  void applyPrefill(
    String text,
    VoiceModel voice, {
    double? stability,
    double? similarity,
    double? style,
    bool? speakerBoost,
  }) {
    setState(() {
      _textController.text = text;
      _selectedVoice = voice;
      if (stability != null) _stability = stability;
      if (similarity != null) _similarity = similarity;
      if (style != null) _style = style;
      if (speakerBoost != null) _speakerBoost = speakerBoost;
      _audioBytes = null;
      _tempAudioPath = null;
      _saved = false;
      _error = null;
    });
  }

  /// Apply a saved bundle of voice + settings, keeping the current text.
  /// Used by the Presets menu and by "Use these settings" from the gallery.
  void applySettings({
    required String voiceId,
    required String voiceName,
    required double stability,
    required double similarity,
    required double style,
    required bool speakerBoost,
  }) {
    setState(() {
      _selectedVoice = VoiceModel(
        id: voiceId,
        name: voiceName,
        description: '',
        isCustom: false,
      );
      _stability = stability;
      _similarity = similarity;
      _style = style;
      _speakerBoost = speakerBoost;
      _showAdvanced = true; // reveal so the applied values are visible
    });
  }

  void _applyPreset(Preset p) {
    applySettings(
      voiceId: p.voiceId,
      voiceName: p.voiceName,
      stability: p.stability,
      similarity: p.similarityBoost,
      style: p.style,
      speakerBoost: p.useSpeakerBoost,
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Applied preset “${p.name}”')),
    );
  }

  Future<void> _saveAsPreset() async {
    if (_selectedVoice == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a voice before saving a preset')),
      );
      return;
    }
    final dup = await widget.presets.findMatching(
      voiceId: _selectedVoice!.id,
      stability: _stability,
      similarityBoost: _similarity,
      style: _style,
      useSpeakerBoost: _speakerBoost,
    );
    if (dup != null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('These settings are already saved as “${dup.name}”'),
            backgroundColor: context.brand.pinkDeep,
          ),
        );
      }
      return;
    }
    final name = await _promptPresetName(_selectedVoice!.name);
    if (name == null || name.trim().isEmpty) return;
    await widget.presets.add(
      name: name.trim(),
      voiceId: _selectedVoice!.id,
      voiceName: _selectedVoice!.name,
      stability: _stability,
      similarityBoost: _similarity,
      style: _style,
      useSpeakerBoost: _speakerBoost,
    );
    await reloadPresets();
    widget.onPresetsChanged();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved preset “${name.trim()}”')),
      );
    }
  }

  Future<void> _deletePreset(Preset p) async {
    await widget.presets.delete(p);
    await reloadPresets();
    widget.onPresetsChanged();
  }

  Future<String?> _promptPresetName(String suggestion) {
    final controller = TextEditingController(text: suggestion);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save preset'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Preset name',
            hintText: 'e.g. Warm narration',
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _generate() async {
    if (_selectedVoice == null || _textController.text.trim().isEmpty) return;
    await widget.player.stop();
    setState(() {
      _loading = true;
      _error = null;
      _audioBytes = null;
      _tempAudioPath = null;
      _saved = false;
    });
    try {
      final bytes = await widget.apiClient.generateSpeech(
        text: _textController.text.trim(),
        voiceId: _selectedVoice!.id,
        stability: _stability,
        similarityBoost: _similarity,
        style: _style,
        useSpeakerBoost: _speakerBoost,
      );
      final tmp = await getTemporaryDirectory();
      if (!await tmp.exists()) await tmp.create(recursive: true);
      final file = File('${tmp.path}/grey_vetro_preview.mp3');
      await file.writeAsBytes(bytes);
      setState(() {
        _audioBytes = bytes;
        _tempAudioPath = file.path;
      });
      widget.onGenerated();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _togglePlayback() async {
    if (_tempAudioPath == null) return;
    await widget.player.toggle(_tempAudioPath!);
  }

  Future<void> _saveToGallery() async {
    if (_audioBytes == null || _selectedVoice == null) return;
    try {
      await widget.gallery.add(
        bytes: _audioBytes!,
        text: _textController.text.trim(),
        voiceId: _selectedVoice!.id,
        voiceName: _selectedVoice!.name,
        stability: _stability,
        similarityBoost: _similarity,
        style: _style,
        useSpeakerBoost: _speakerBoost,
        projectId: _activeProjectId,
      );
      setState(() => _saved = true);
      widget.onSavedToGallery();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved to your gallery')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Save failed: $e'),
            backgroundColor: context.brand.danger,
          ),
        );
      }
    }
  }

  Future<void> _writeWithAi() async {
    final script = await showScriptAssistModal(context, apiClient: widget.apiClient);
    if (script != null) {
      setState(() {
        _textController.text = script;
        _audioBytes = null;
        _tempAudioPath = null;
        _saved = false;
      });
    }
  }

  Future<void> _openVoicePicker() async {
    final voice = await showVoicePicker(
      context,
      apiClient: widget.apiClient,
      player: widget.player,
      selected: _selectedVoice,
    );
    if (voice != null) setState(() => _selectedVoice = voice);
  }

  /// Below this content width the composer reflows to a single column.
  static const _twoColumnBreakpoint = 880.0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final twoColumn = constraints.maxWidth >= _twoColumnBreakpoint;
            final pad = twoColumn ? 32.0 : 22.0;
            return Padding(
              padding: EdgeInsets.fromLTRB(pad, pad - 6, pad, pad),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _header(),
                  const SizedBox(height: 18),
                  Expanded(
                    child: twoColumn ? _wideBody() : _narrowBody(),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  // ---- Layouts --------------------------------------------------------------

  Widget _wideBody() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _editorCard(expand: true)),
        const SizedBox(width: 20),
        SizedBox(
          width: 360,
          child: SingleChildScrollView(child: _rail()),
        ),
      ],
    );
  }

  Widget _narrowBody() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _editorCard(expand: false),
          const SizedBox(height: 14),
          _rail(),
        ],
      ),
    );
  }

  /// The right-hand controls column (voice, settings, generate, result).
  Widget _rail() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: ProjectSelect(
            key: _projectSelectKey,
            repository: widget.projects,
            onChanged: (id) => _activeProjectId = id,
          ),
        ),
        const SizedBox(height: 13),
        _voiceCard(),
        const SizedBox(height: 13),
        _settingsCard(),
        const SizedBox(height: 13),
        _generateButton(),
        if (_error != null) ...[
          const SizedBox(height: 13),
          _errorBanner(_error!),
        ],
        if (_audioBytes != null) ...[
          const SizedBox(height: 13),
          _resultCard(),
        ],
      ],
    );
  }

  // ---- Header ---------------------------------------------------------------

  Widget _header() {
    final c = context.brand;
    final charCount = _textController.text.characters.length;
    // Rough spoken duration estimate (~15 chars/sec).
    final secs = (charCount / 15).round();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Text(
            'New speech',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
              color: c.text,
            ),
          ),
        ),
        Text(
          charCount == 0 ? 'Ready' : '$charCount chars · ~${secs}s',
          style: AppFonts.monoStyle(size: 12, color: c.text3),
        ),
      ],
    );
  }

  // ---- Editor ---------------------------------------------------------------

  Widget _editorCard({required bool expand}) {
    final c = context.brand;
    final charCount = _textController.text.characters.length;
    final field = TextField(
      controller: _textController,
      expands: expand,
      maxLines: expand ? null : 8,
      minLines: expand ? null : 6,
      textAlignVertical: TextAlignVertical.top,
      style: TextStyle(fontSize: 16, color: c.text, height: 1.6),
      decoration: InputDecoration(
        hintText: 'Type or paste the text you want to hear…',
        hintStyle: TextStyle(color: c.text3, height: 1.6),
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        filled: false,
        contentPadding: EdgeInsets.zero,
      ),
    );
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (expand)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
                child: field,
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
              child: field,
            ),
          Divider(height: 1, color: c.outline),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '$charCount characters',
                    style: AppFonts.monoStyle(size: 11.5, color: c.text3),
                  ),
                ),
                TextButton.icon(
                  onPressed: _writeWithAi,
                  style: TextButton.styleFrom(
                    foregroundColor: c.blueDeep,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  icon: const Icon(Icons.auto_awesome_rounded, size: 16),
                  label: const Text('Write with AI', style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---- Voice card -----------------------------------------------------------

  Widget _voiceCard() {
    final c = context.brand;
    final voice = _selectedVoice;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.card),
        onTap: _openVoicePicker,
        child: Padding(
          padding: const EdgeInsets.all(13),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  gradient: c.sliderGradient,
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: voice == null
                    ? const Icon(Icons.record_voice_over_rounded,
                        color: Colors.white, size: 20)
                    : Text(
                        voice.name.isNotEmpty
                            ? voice.name.characters.first.toUpperCase()
                            : '?',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                      ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      voice?.name ?? 'Choose a voice',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: c.text,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      voice == null
                          ? 'Tap to browse available voices'
                          : (voice.isCustom ? 'My voice' : 'Built-in voice'),
                      style: TextStyle(fontSize: 11.5, color: c.text3),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: c.text3),
            ],
          ),
        ),
      ),
    );
  }

  // ---- Voice settings (collapsible) ----------------------------------------

  Widget _settingsCard() {
    final c = context.brand;
    return Card(
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(AppRadii.card),
            onTap: () => setState(() => _showAdvanced = !_showAdvanced),
            child: Padding(
              padding: const EdgeInsets.all(15),
              child: Row(
                children: [
                  Icon(Icons.tune_rounded, size: 19, color: c.blueDeep),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Text(
                      'Voice settings',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: c.text,
                      ),
                    ),
                  ),
                  Icon(
                    _showAdvanced
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    color: c.text3,
                  ),
                ],
              ),
            ),
          ),
          if (_showAdvanced)
            Padding(
              padding: const EdgeInsets.fromLTRB(15, 0, 15, 14),
              child: Column(
                children: [
                  _presetBar(),
                  Divider(height: 22, color: c.outline),
                  _slider(
                    label: 'Stability',
                    hint: 'Lower = more expressive · Higher = more consistent',
                    value: _stability,
                    onChanged: (v) => setState(() => _stability = v),
                  ),
                  const SizedBox(height: 12),
                  _slider(
                    label: 'Similarity',
                    hint: 'How closely to match the original voice',
                    value: _similarity,
                    onChanged: (v) => setState(() => _similarity = v),
                  ),
                  const SizedBox(height: 12),
                  _slider(
                    label: 'Style',
                    hint: 'Higher = more expressive · 0 = most neutral & stable',
                    value: _style,
                    onChanged: (v) => setState(() => _style = v),
                  ),
                  const SizedBox(height: 4),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    activeThumbColor: Colors.white,
                    activeTrackColor: c.blueDeep,
                    value: _speakerBoost,
                    onChanged: (v) => setState(() => _speakerBoost = v),
                    title: Text(
                      'Speaker boost',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: c.text,
                      ),
                    ),
                    subtitle: Text(
                      'Boosts resemblance to your original voice',
                      style: TextStyle(fontSize: 11.5, color: c.text3),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _presetBar() {
    final c = context.brand;
    return Row(
      children: [
        Expanded(
          child: _presets.isEmpty
              ? Text(
                  'No presets yet — save your current settings to reuse them.',
                  style: TextStyle(fontSize: 11.5, color: c.text3),
                )
              : PopupMenuButton<Preset>(
                  onSelected: _applyPreset,
                  position: PopupMenuPosition.under,
                  itemBuilder: (ctx) => _presets
                      .map(
                        (p) => PopupMenuItem<Preset>(
                          value: p,
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(p.name,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w600)),
                                    Text(p.voiceName,
                                        style: TextStyle(
                                            fontSize: 12, color: c.text3)),
                                  ],
                                ),
                              ),
                              IconButton(
                                icon: Icon(Icons.delete_outline_rounded,
                                    size: 18, color: c.text3),
                                tooltip: 'Delete preset',
                                onPressed: () {
                                  Navigator.pop(ctx);
                                  _deletePreset(p);
                                },
                              ),
                            ],
                          ),
                        ),
                      )
                      .toList(),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.bookmark_rounded,
                          size: 17, color: c.blueDeep),
                      const SizedBox(width: 7),
                      Text('Apply preset',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: c.text)),
                      Icon(Icons.arrow_drop_down_rounded, color: c.text3),
                    ],
                  ),
                ),
        ),
        TextButton.icon(
          onPressed: _saveAsPreset,
          style: TextButton.styleFrom(
            foregroundColor: c.blueDeep,
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          icon: const Icon(Icons.bookmark_add_outlined, size: 17),
          label: const Text('Save', style: TextStyle(fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }

  Widget _slider({
    required String label,
    required String hint,
    required double value,
    required ValueChanged<double> onChanged,
  }) {
    final c = context.brand;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: c.text,
                ),
              ),
            ),
            Text(
              '${(value * 100).round()}%',
              style: AppFonts.monoStyle(size: 12, color: c.blueDeep),
            ),
          ],
        ),
        Text(hint, style: TextStyle(fontSize: 11, color: c.text3)),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 6,
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          ),
          child: Slider(
            value: value,
            onChanged: onChanged,
            activeColor: c.blueDeep,
            inactiveColor: c.outline,
          ),
        ),
      ],
    );
  }

  // ---- Generate button (gradient) ------------------------------------------

  Widget _generateButton() {
    final c = context.brand;
    final enabled = !_loading &&
        _selectedVoice != null &&
        _textController.text.trim().isNotEmpty;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? _generate : null,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 15),
          decoration: BoxDecoration(
            gradient: enabled ? c.heroGradient : null,
            color: enabled ? null : c.surfaceMuted,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_loading)
                SizedBox(
                  width: 17,
                  height: 17,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.4,
                    color: c.onAccent,
                  ),
                )
              else
                Icon(
                  Icons.auto_awesome_rounded,
                  size: 18,
                  color: enabled ? c.onAccent : c.text3,
                ),
              const SizedBox(width: 9),
              Text(
                _loading ? 'Generating…' : 'Generate speech',
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w800,
                  color: enabled ? c.onAccent : c.text3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- Error banner ---------------------------------------------------------

  Widget _errorBanner(String message) {
    final c = context.brand;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.danger.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.danger.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, size: 19, color: c.danger),
          const SizedBox(width: 11),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: c.text, fontSize: 12.5, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  // ---- Result card ----------------------------------------------------------

  Widget _resultCard() {
    final c = context.brand;
    return ValueListenableBuilder<String?>(
      valueListenable: widget.player.playing,
      builder: (context, playingPath, _) {
        final isPlaying =
            _tempAudioPath != null && _tempAudioPath == playingPath;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(15),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.auto_awesome_rounded, size: 18, color: c.blueDeep),
                    const SizedBox(width: 9),
                    Text(
                      'Your audio is ready',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: c.text,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    _playButton(isPlaying),
                    const SizedBox(width: 12),
                    Expanded(
                      child: isPlaying
                          ? AudioScrubber(player: widget.player)
                          : Text(
                              'Press play to preview',
                              style: TextStyle(fontSize: 12.5, color: c.text3),
                            ),
                    ),
                  ],
                ),
                const SizedBox(height: 13),
                _saveButton(),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _playButton(bool isPlaying) {
    final c = context.brand;
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: _togglePlayback,
        child: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            gradient: c.sliderGradient,
            shape: BoxShape.circle,
          ),
          child: Icon(
            isPlaying ? Icons.stop_rounded : Icons.play_arrow_rounded,
            color: Colors.white,
            size: 22,
          ),
        ),
      ),
    );
  }

  Widget _saveButton() {
    final c = context.brand;
    if (_saved) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: c.success.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(AppRadii.field),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check_rounded, size: 18, color: c.success),
            const SizedBox(width: 8),
            Text(
              'Saved to gallery',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: c.success,
              ),
            ),
          ],
        ),
      );
    }
    return OutlinedButton.icon(
      onPressed: _saveToGallery,
      icon: const Icon(Icons.bookmark_add_outlined, size: 18),
      label: const Text('Save to Gallery'),
    );
  }
}
