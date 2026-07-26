import 'dart:io';
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
import 'composite.dart';
import 'render_scene_payload.dart';
import 'scene_repository.dart';
import 'storyboard_preview.dart';
import 'stored_scene.dart';

String _fmtTime(double seconds) {
  final m = seconds ~/ 60;
  final s = seconds - m * 60;
  return '$m:${s.toStringAsFixed(1).padLeft(4, '0')}';
}

String _slugify(String s) {
  final lower = s
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final trimmed = lower.length > 48 ? lower.substring(0, 48) : lower;
  return trimmed.isEmpty ? 'video' : trimmed;
}

/// Per-project storyboard: a voiceover clip is transcribed and turned into
/// timed scenes with AI image prompts, each scene gets an image (upload or
/// AI-generated), scenes can be reordered/deleted, and the whole thing
/// previews and exports to mp4. Mirrors the web frontend's `StoryboardScreen`.
class StoryboardScreen extends StatefulWidget {
  final ProjectRepository projects;
  final GalleryRepository gallery;
  final SceneRepository scenes;
  final ApiClient apiClient;
  final AudioPlayer player;

  const StoryboardScreen({
    super.key,
    required this.projects,
    required this.gallery,
    required this.scenes,
    required this.apiClient,
    required this.player,
  });

  @override
  State<StoryboardScreen> createState() => StoryboardScreenState();
}

class StoryboardScreenState extends State<StoryboardScreen> {
  List<Project> _projects = [];
  String? _projectId;
  List<GalleryItem> _clips = [];
  String? _pickedClipId;
  List<StoredScene>? _sceneList;
  Map<String, Uint8List> _imageBytes = {};
  bool _busy = false;
  bool _exporting = false;
  final Set<String> _generatingIds = {};
  bool _batchGenerating = false;

  @override
  void initState() {
    super.initState();
    _loadProjectsAndClips();
  }

  Future<void> _loadProjectsAndClips() async {
    final projects = await widget.projects.load();
    final clips = await widget.gallery.load();
    if (!mounted) return;
    setState(() {
      _projects = projects;
      _clips = clips;
      if (_projectId == null || !projects.any((p) => p.id == _projectId)) {
        _projectId = projects.isNotEmpty ? projects.first.id : null;
      }
    });
    await _loadStoryboard();
  }

  /// Refreshes the project list (e.g. after Gallery/composer creates, renames,
  /// or deletes a project elsewhere).
  Future<void> refreshProjects() => _loadProjectsAndClips();

  /// Refreshes the clip list (e.g. after a new take is saved to the gallery).
  Future<void> refreshClips() async {
    final clips = await widget.gallery.load();
    if (mounted) setState(() => _clips = clips);
  }

  Future<void> _selectProject(String id) async {
    setState(() {
      _projectId = id;
      _pickedClipId = null;
    });
    await _loadStoryboard();
  }

  Future<void> _loadStoryboard() async {
    final projectId = _projectId;
    if (projectId == null) {
      setState(() => _sceneList = null);
      return;
    }
    setState(() {
      _sceneList = null;
      _imageBytes = {};
    });
    final list = await widget.scenes.listForProject(projectId);
    if (!mounted || _projectId != projectId) return;
    final images = <String, Uint8List>{};
    for (final s in list) {
      if (!s.hasImage) continue;
      final bytes = await widget.scenes.getSceneImage(s.id);
      if (bytes != null) images[s.id] = bytes;
    }
    if (!mounted || _projectId != projectId) return;
    setState(() {
      _sceneList = list;
      _imageBytes = images;
    });
  }

  List<GalleryItem> get _projectClips =>
      _clips.where((c) => c.projectId == _projectId).toList();

  String get _voiceClipId {
    final scenes = _sceneList;
    if (scenes != null && scenes.isNotEmpty) return scenes.first.clipId;
    if (_pickedClipId != null) return _pickedClipId!;
    final clips = _projectClips;
    return clips.isNotEmpty ? clips.first.id : '';
  }

  GalleryItem? get _voiceClip {
    final id = _voiceClipId;
    if (id.isEmpty) return null;
    for (final c in _clips) {
      if (c.id == id) return c;
    }
    return null;
  }

  Future<void> _generateStoryboard() async {
    final clip = _voiceClip;
    final projectId = _projectId;
    if (clip == null || projectId == null || _busy) return;
    if (_sceneList != null && _sceneList!.isNotEmpty) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Regenerate the storyboard?'),
          content: const Text('Current scenes and their images will be replaced.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Regenerate')),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    setState(() => _busy = true);
    try {
      var transcript = clip.transcript;
      if (transcript == null) {
        final bytes = await File(await widget.gallery.filePath(clip)).readAsBytes();
        transcript = await widget.apiClient.transcribeAudio(bytes: bytes, fileName: clip.fileName);
        await widget.gallery.updateTranscript(clip.id, transcript);
        final updatedClip = clip.copyWith(transcript: transcript);
        setState(() {
          _clips = _clips.map((c) => c.id == clip.id ? updatedClip : c).toList();
        });
      }
      final proposed = await widget.apiClient.generateScenes(transcript: transcript);
      final stored = await widget.scenes.replaceForProject(projectId, clip.id, proposed);
      if (!mounted) return;
      setState(() {
        _sceneList = stored;
        _imageBytes = {};
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Storyboard created — ${stored.length} scenes.')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Storyboard generation failed: $e'),
            backgroundColor: context.brand.danger,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickImage(StoredScene scene) async {
    final result = await FilePicker.pickFiles(type: FileType.image);
    final path = result?.files.first.path;
    if (path == null) return;
    final bytes = await File(path).readAsBytes();
    await widget.scenes.setSceneImage(scene.id, bytes);
    if (!mounted) return;
    setState(() {
      _imageBytes = {..._imageBytes, scene.id: bytes};
      _sceneList = _sceneList
          ?.map((s) => s.id == scene.id ? s.copyWith(hasImage: true) : s)
          .toList();
    });
  }

  Future<void> _removeImage(StoredScene scene) async {
    await widget.scenes.removeSceneImage(scene.id);
    if (!mounted) return;
    setState(() {
      _imageBytes = {..._imageBytes}..remove(scene.id);
      _sceneList = _sceneList
          ?.map((s) => s.id == scene.id ? s.copyWith(hasImage: false) : s)
          .toList();
    });
  }

  Future<bool> _generateImage(StoredScene scene) async {
    if (_generatingIds.contains(scene.id)) return false;
    setState(() => _generatingIds.add(scene.id));
    try {
      final bytes = await widget.apiClient.generateSceneImage(scene.imagePrompt);
      await widget.scenes.setSceneImage(scene.id, bytes);
      if (mounted) {
        setState(() {
          _imageBytes = {..._imageBytes, scene.id: bytes};
          _sceneList = _sceneList
              ?.map((s) => s.id == scene.id ? s.copyWith(hasImage: true) : s)
              .toList();
        });
      }
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Image generation failed: $e'),
            backgroundColor: context.brand.danger,
          ),
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => _generatingIds.remove(scene.id));
    }
  }

  // Sequential with a short pause between calls — Gemini's free tier is rate-limited
  // per minute, and a burst of parallel image requests trips it immediately.
  Future<void> _generateAllImages() async {
    final list = _sceneList;
    if (list == null || _batchGenerating) return;
    final missing = list.where((s) => !s.hasImage).toList();
    if (missing.isEmpty) return;
    setState(() => _batchGenerating = true);
    var ok = 0;
    for (var i = 0; i < missing.length; i++) {
      if (await _generateImage(missing[i])) ok++;
      if (i < missing.length - 1) {
        await Future.delayed(const Duration(milliseconds: 1200));
      }
    }
    if (!mounted) return;
    setState(() => _batchGenerating = false);
    final message = ok == missing.length
        ? 'Generated $ok scene image${ok == 1 ? '' : 's'}.'
        : ok > 0
            ? 'Generated $ok/${missing.length} scene images — some failed.'
            : 'Image generation failed for all scenes.';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  // Deleting a scene closes the timeline gap: the previous scene absorbs its
  // slot (or the next scene starts earlier if the first scene was removed).
  Future<void> _removeScene(StoredScene scene, int index) async {
    final list = _sceneList;
    final projectId = _projectId;
    if (list == null || projectId == null) return;
    await widget.scenes.deleteScene(scene.id);
    final prev = index > 0 ? list[index - 1] : null;
    final next = index < list.length - 1 ? list[index + 1] : null;
    if (prev != null) {
      await widget.scenes.updateScene(prev.id, end: scene.end);
    } else if (next != null) {
      await widget.scenes.updateScene(next.id, start: scene.start);
    }
    final refreshed = await widget.scenes.listForProject(projectId);
    if (!mounted) return;
    setState(() {
      _sceneList = refreshed;
      _imageBytes = {..._imageBytes}..remove(scene.id);
    });
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Scene removed.')));
  }

  Future<void> _reorder(int oldIndex, int newIndex) async {
    final list = _sceneList;
    final projectId = _projectId;
    if (list == null || projectId == null) return;
    final ids = list.map((s) => s.id).toList();
    final moved = ids.removeAt(oldIndex);
    ids.insert(newIndex, moved);
    final updated = await widget.scenes.reorder(projectId, ids);
    if (!mounted) return;
    setState(() => _sceneList = updated);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Scenes reordered — times re-anchored.')),
    );
  }

  Future<void> _copyPrompt(StoredScene scene, int index) async {
    await Clipboard.setData(ClipboardData(text: scene.imagePrompt));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Scene ${index + 1} prompt copied.')),
      );
    }
  }

  Future<void> _preview() async {
    final list = _sceneList;
    final clip = _voiceClip;
    if (list == null || list.isEmpty || clip == null) return;
    final path = await widget.gallery.filePath(clip);
    if (!mounted) return;
    await showStoryboardPreview(
      context,
      title: clipTitleOf(clip),
      scenes: list,
      imageBytes: _imageBytes,
      audioPath: path,
      player: widget.player,
    );
  }

  Future<void> _export() async {
    final list = _sceneList;
    final clip = _voiceClip;
    if (list == null || list.isEmpty || clip == null || _exporting) return;
    final missing = list.where((s) => !s.hasImage).length;
    if (missing > 0) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('$missing scene${missing == 1 ? ' has' : 's have'} no image yet'),
          content: const Text('They will render as a dark placeholder card. Export anyway?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Export')),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    setState(() => _exporting = true);
    try {
      final audioBytes = await File(await widget.gallery.filePath(clip)).readAsBytes();
      final payload = <RenderScenePayload>[];
      for (final s in list) {
        Uint8List? image;
        if (s.hasImage) {
          image = _imageBytes[s.id] ?? await widget.scenes.getSceneImage(s.id);
        }
        final frame = await compositeFrame(image: image, narration: s.narration, captions: true);
        payload.add(RenderScenePayload(start: s.start, end: s.end, image: frame));
      }
      final mp4 = await widget.apiClient.renderStoryboard(audio: audioBytes, scenes: payload);
      final downloads = await getDownloadsDirectory();
      if (downloads == null) throw Exception('Downloads directory unavailable');
      var projectName = 'video';
      for (final p in _projects) {
        if (p.id == _projectId) projectName = p.name;
      }
      final dest = File('${downloads.path}/${_slugify(projectName)}.mp4');
      await dest.writeAsBytes(mp4);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Exported to ${dest.path}')),
        );
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

  @override
  Widget build(BuildContext context) {
    final c = context.brand;
    if (_projects.isEmpty) {
      return _emptyState(
        icon: Icons.movie_outlined,
        title: 'No projects yet',
        message:
            'A storyboard turns one project into one video. Create a project in the Gallery and save a voiceover take into it first.',
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
                'Storyboard',
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
    final scenes = _sceneList;
    final hasScenes = scenes != null && scenes.isNotEmpty;
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
        if (hasScenes) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : _generateStoryboard,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: Text(_busy ? 'Working…' : 'Regenerate'),
              ),
              if (scenes.any((s) => !s.hasImage))
                OutlinedButton.icon(
                  onPressed: _batchGenerating ? null : _generateAllImages,
                  icon: const Icon(Icons.auto_awesome_rounded, size: 16),
                  label: Text(_batchGenerating ? 'Generating…' : 'Generate images'),
                ),
              OutlinedButton.icon(
                onPressed: _preview,
                icon: const Icon(Icons.play_arrow_rounded, size: 16),
                label: const Text('Preview'),
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
    final scenes = _sceneList;
    if (scenes == null) return const Center(child: CircularProgressIndicator());
    if (scenes.isEmpty) {
      if (_projectClips.isEmpty) {
        return _emptyState(
          icon: Icons.headphones_outlined,
          title: 'No clips in this project',
          message: 'Save a voiceover take into this project from the Studio, then come back to build its storyboard.',
        );
      }
      return _newStoryboardCard();
    }
    final voiceClip = _voiceClip;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (voiceClip != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              'Voiceover: ${clipTitleOf(voiceClip)} · ${scenes.length} scenes · drag to reorder · click a slot to add its image',
              style: AppFonts.monoStyle(size: 11.5, color: context.brand.text3),
            ),
          ),
        Expanded(
          child: ReorderableListView.builder(
            itemCount: scenes.length,
            onReorderItem: _reorder,
            itemBuilder: (ctx, i) => Padding(
              key: ValueKey(scenes[i].id),
              padding: const EdgeInsets.only(bottom: 12),
              child: _sceneCard(scenes[i], i),
            ),
          ),
        ),
      ],
    );
  }

  Widget _newStoryboardCard() {
    final c = context.brand;
    final clips = _projectClips;
    final selected = _voiceClipId;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'New storyboard',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: c.text),
                ),
                const SizedBox(height: 8),
                Text(
                  'The voiceover is the master clock: it gets transcribed with word '
                  'timestamps, then AI proposes timed scenes with image prompts.',
                  style: TextStyle(fontSize: 12.5, color: c.text3, height: 1.4),
                ),
                const SizedBox(height: 16),
                Text(
                  'Voiceover clip',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: c.text),
                ),
                const SizedBox(height: 6),
                DropdownButtonFormField<String>(
                  key: ValueKey('clip-picker-$_projectId'),
                  initialValue: selected.isEmpty ? null : selected,
                  items: [
                    for (final clip in clips)
                      DropdownMenuItem(value: clip.id, child: Text(clipTitleOf(clip))),
                  ],
                  onChanged: (v) => setState(() => _pickedClipId = v),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: (_busy || selected.isEmpty) ? null : _generateStoryboard,
                  icon: const Icon(Icons.movie_outlined, size: 18),
                  label: Text(_busy ? 'Transcribing & generating…' : 'Generate storyboard'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sceneCard(StoredScene scene, int index) {
    final c = context.brand;
    final bytes = _imageBytes[scene.id];
    final generating = _generatingIds.contains(scene.id);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => _pickImage(scene),
              child: Container(
                width: 64,
                height: 96,
                decoration: BoxDecoration(
                  color: c.surfaceMuted,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: c.outline),
                ),
                clipBehavior: Clip.antiAlias,
                child: bytes != null
                    ? Image.memory(bytes, fit: BoxFit.cover)
                    : Center(
                        child: Icon(Icons.add_a_photo_outlined, size: 20, color: c.text3),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Scene ${index + 1} · ${_fmtTime(scene.start)}–${_fmtTime(scene.end)}',
                    style: AppFonts.monoStyle(size: 11.5, color: c.text3),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '“${scene.narration}”',
                    style: TextStyle(color: c.text, fontStyle: FontStyle.italic, fontSize: 13),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    scene.imagePrompt,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.text2, fontSize: 12, height: 1.35),
                  ),
                ],
              ),
            ),
            Column(
              children: [
                generating
                    ? const Padding(
                        padding: EdgeInsets.all(10),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : _iconBtn(
                        Icons.auto_awesome_rounded,
                        scene.hasImage ? 'Regenerate image with AI' : 'Generate image with AI',
                        () => _generateImage(scene),
                      ),
                _iconBtn(Icons.content_copy_rounded, 'Copy image prompt', () => _copyPrompt(scene, index)),
                if (scene.hasImage)
                  _iconBtn(Icons.hide_image_outlined, 'Remove image', () => _removeImage(scene)),
                _iconBtn(Icons.delete_outline_rounded, 'Delete scene', () => _removeScene(scene, index)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _iconBtn(IconData icon, String tooltip, VoidCallback onTap) => IconButton(
        icon: Icon(icon, size: 19, color: context.brand.text2),
        tooltip: tooltip,
        onPressed: onTap,
        padding: const EdgeInsets.all(6),
        constraints: const BoxConstraints(),
      );

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
