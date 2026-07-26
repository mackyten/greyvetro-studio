import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/api_client.dart';
import '../../core/audio_player.dart';
import '../../core/audio_scrubber.dart';
import '../../core/theme.dart';
import '../presets/preset_repository.dart';
import '../projects/project.dart';
import '../projects/project_name_dialog.dart';
import '../projects/project_repository.dart';
import '../storyboard/scene_repository.dart';
import '../stt/transcript_modal.dart';
import 'gallery_item.dart';
import 'gallery_repository.dart';

/// 'all' | 'unsorted' | a project id.
typedef _GalleryFilter = String;

const _allFilter = 'all';
const _unsortedFilter = 'unsorted';

class GalleryScreen extends StatefulWidget {
  final GalleryRepository repository;
  final PresetRepository presets;
  final ProjectRepository projects;
  final SceneRepository scenes;
  final AudioPlayer player;
  final ApiClient apiClient;
  final ValueChanged<GalleryItem> onEdit;

  /// Copy this item's voice + settings into the composer (keeps current text).
  final ValueChanged<GalleryItem> onUseSettings;

  /// Called after a preset is created here, so the Presets tab can refresh.
  final VoidCallback onPresetsChanged;

  /// Called after a project is created, renamed, or deleted here, so the
  /// composer's Project selector can refresh.
  final VoidCallback onProjectsChanged;

  const GalleryScreen({
    super.key,
    required this.repository,
    required this.presets,
    required this.projects,
    required this.scenes,
    required this.player,
    required this.apiClient,
    required this.onEdit,
    required this.onUseSettings,
    required this.onPresetsChanged,
    required this.onProjectsChanged,
  });

  @override
  State<GalleryScreen> createState() => GalleryScreenState();
}

class GalleryScreenState extends State<GalleryScreen> {
  List<GalleryItem>? _items;
  List<Project> _projects = [];
  _GalleryFilter _filter = _allFilter;
  String? _transcribingId;

  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    final items = await widget.repository.load();
    final projects = await widget.projects.load();
    if (mounted) {
      setState(() {
        _items = items;
        _projects = projects;
        if (_filter != _allFilter &&
            _filter != _unsortedFilter &&
            !projects.any((p) => p.id == _filter)) {
          _filter = _allFilter;
        }
      });
    }
  }

  Project? get _activeProject {
    for (final p in _projects) {
      if (p.id == _filter) return p;
    }
    return null;
  }

  List<GalleryItem> get _visibleItems {
    final items = _items ?? const [];
    if (_filter == _allFilter) return items;
    if (_filter == _unsortedFilter) {
      return items.where((i) => i.projectId == null).toList();
    }
    return items.where((i) => i.projectId == _filter).toList();
  }

  Future<void> _play(GalleryItem item) async {
    final path = await widget.repository.filePath(item);
    await widget.player.toggle(path);
  }

  Future<void> _delete(GalleryItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete recording?'),
        content: const Text('This removes the audio file and its entry permanently.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.brand.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (widget.player.isPlaying(await widget.repository.filePath(item))) {
      await widget.player.stop();
    }
    await widget.repository.delete(item);
    await refresh();
  }

  Future<void> _createProject() async {
    final name = await showProjectNameDialog(context, title: 'New project');
    if (name == null || name.trim().isEmpty) return;
    final project = await widget.projects.add(name);
    setState(() {
      _projects = [..._projects, project];
      _filter = project.id;
    });
    widget.onProjectsChanged();
  }

  Future<void> _renameActiveProject() async {
    final project = _activeProject;
    if (project == null) return;
    final name = await showProjectNameDialog(
      context,
      title: 'Rename project',
      initialName: project.name,
    );
    if (name == null || name.trim().isEmpty) return;
    await widget.projects.rename(project.id, name);
    setState(() {
      _projects = _projects
          .map((p) => p.id == project.id ? p.copyWith(name: name.trim()) : p)
          .toList();
    });
    widget.onProjectsChanged();
  }

  Future<void> _deleteActiveProject() async {
    final project = _activeProject;
    if (project == null) return;
    final count = _visibleItems.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete project "${project.name}"?'),
        content: Text(
          'Its $count clip${count == 1 ? '' : 's'} will be kept in Unsorted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.brand.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.projects.delete(project.id);
    await widget.repository.clearProjectId(project.id);
    await widget.scenes.deleteForProject(project.id);
    setState(() => _filter = _allFilter);
    await refresh();
    widget.onProjectsChanged();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Project "${project.name}" deleted — clips kept in Unsorted.')),
      );
    }
  }

  Future<void> _moveToProject(GalleryItem item) async {
    final choice = await showDialog<String?>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Move to project'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, ''),
            child: Row(
              children: [
                if (item.projectId == null)
                  Icon(Icons.check_rounded, size: 18, color: context.brand.blueDeep)
                else
                  const SizedBox(width: 18),
                const SizedBox(width: 8),
                const Text('Unsorted'),
              ],
            ),
          ),
          for (final p in _projects)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, p.id),
              child: Row(
                children: [
                  if (item.projectId == p.id)
                    Icon(Icons.check_rounded, size: 18, color: context.brand.blueDeep)
                  else
                    const SizedBox(width: 18),
                  const SizedBox(width: 8),
                  Icon(Icons.folder_outlined, size: 16, color: context.brand.text2),
                  const SizedBox(width: 6),
                  Text(p.name),
                ],
              ),
            ),
        ],
      ),
    );
    if (choice == null) return;
    final projectId = choice.isEmpty ? null : choice;
    await widget.repository.updateProjectId(item.id, projectId);
    setState(() {
      _items = _items
          ?.map((i) => i.id == item.id
              ? i.copyWith(projectId: projectId, clearProjectId: projectId == null)
              : i)
          .toList();
    });
    if (mounted) {
      var target = 'Unsorted';
      for (final p in _projects) {
        if (p.id == projectId) {
          target = p.name;
          break;
        }
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Moved to $target.')),
      );
    }
  }

  Future<void> _renameClip(GalleryItem item) async {
    final controller = TextEditingController(text: clipTitleOf(item));
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename clip'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Title'),
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
    if (title == null || title.trim().isEmpty) return;
    await widget.repository.updateTitle(item.id, title.trim());
    setState(() {
      _items = _items?.map((i) => i.id == item.id ? i.copyWith(title: title.trim()) : i).toList();
    });
  }

  Future<void> _transcribe(GalleryItem item) async {
    if (item.transcript != null) {
      _openTranscript(item);
      return;
    }
    if (_transcribingId != null) return;
    setState(() => _transcribingId = item.id);
    try {
      final bytes = await File(await widget.repository.filePath(item)).readAsBytes();
      final transcript = await widget.apiClient.transcribeAudio(
        bytes: bytes,
        fileName: item.fileName,
      );
      await widget.repository.updateTranscript(item.id, transcript);
      final updated = item.copyWith(transcript: transcript);
      setState(() {
        _items = _items?.map((i) => i.id == item.id ? updated : i).toList();
      });
      _openTranscript(updated);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Transcription failed: $e'),
            backgroundColor: context.brand.danger,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _transcribingId = null);
    }
  }

  void _openTranscript(GalleryItem item) {
    final transcript = item.transcript;
    if (transcript == null) return;
    showTranscriptModal(
      context,
      title: clipTitleOf(item),
      transcript: transcript,
      apiClient: widget.apiClient,
    );
  }

  Future<void> _export(GalleryItem item) async {
    try {
      final downloads = await getDownloadsDirectory();
      if (downloads == null) throw Exception('Downloads directory unavailable');
      final dest = File('${downloads.path}/${item.fileName}');
      await File(await widget.repository.filePath(item)).copy(dest.path);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Exported to ${dest.path}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Export failed: $e'),
            backgroundColor: context.brand.danger,
          ),
        );
      }
    }
  }

  Future<void> _saveItemAsPreset(GalleryItem item) async {
    final dup = await widget.presets.findMatching(
      voiceId: item.voiceId,
      stability: item.stability,
      similarityBoost: item.similarityBoost,
      style: item.style,
      useSpeakerBoost: item.useSpeakerBoost,
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
    if (!mounted) return;
    final controller = TextEditingController(text: item.voiceName);
    final name = await showDialog<String>(
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
    if (name == null || name.trim().isEmpty) return;
    await widget.presets.add(
      name: name.trim(),
      voiceId: item.voiceId,
      voiceName: item.voiceName,
      stability: item.stability,
      similarityBoost: item.similarityBoost,
      style: item.style,
      useSpeakerBoost: item.useSpeakerBoost,
    );
    widget.onPresetsChanged();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved preset “${name.trim()}”')),
      );
    }
  }

  /// Column count for the masonry grid, by available content width.
  static int _columnsFor(double width) {
    if (width >= 1180) return 3;
    if (width >= 780) return 2;
    return 1;
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    if (items == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final visible = _visibleItems;

    return RefreshIndicator(
      onRefresh: refresh,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final cols = _columnsFor(constraints.maxWidth);
          final pad = constraints.maxWidth >= 780 ? 32.0 : 20.0;
          return SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.all(pad),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _screenHeader(visible.length),
                const SizedBox(height: 14),
                _projectChipRow(),
                const SizedBox(height: 18),
                if (visible.isEmpty)
                  _emptyBody()
                else
                  _masonry(visible, cols),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _screenHeader(int count) {
    final c = context.brand;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Text(
            'Gallery',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
              color: c.text,
            ),
          ),
        ),
        Text(
          count == 0
              ? 'No recordings'
              : '$count recording${count == 1 ? '' : 's'}',
          style: AppFonts.monoStyle(size: 12, color: c.text3),
        ),
      ],
    );
  }

  Widget _projectChipRow() {
    final active = _activeProject;
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _filterChip('All', _filter == _allFilter, () => setState(() => _filter = _allFilter)),
                _filterChip(
                  'Unsorted',
                  _filter == _unsortedFilter,
                  () => setState(() => _filter = _unsortedFilter),
                ),
                for (final p in _projects)
                  _filterChip(
                    p.name,
                    _filter == p.id,
                    () => setState(() => _filter = p.id),
                    icon: Icons.folder_outlined,
                  ),
                _filterChip('New project', false, _createProject, icon: Icons.add_rounded),
              ],
            ),
          ),
          if (active != null) ...[
            const SizedBox(width: 4),
            _iconBtn(Icons.edit_outlined, 'Rename project', _renameActiveProject),
            _iconBtn(Icons.delete_outline_rounded, 'Delete project', _deleteActiveProject),
          ],
        ],
      ),
    );
  }

  Widget _filterChip(String label, bool selected, VoidCallback onTap, {IconData? icon}) {
    final c = context.brand;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        avatar: icon != null
            ? Icon(icon, size: 15, color: selected ? c.blueDeep : c.text3)
            : null,
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
        showCheckmark: false,
        backgroundColor: c.surface,
        selectedColor: c.blueDeep.withValues(alpha: 0.28),
        side: BorderSide(color: selected ? c.blueDeep : c.outline),
        labelStyle: TextStyle(
          color: c.text,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    );
  }

  /// Round-robin distribution across [cols] columns — a lightweight masonry
  /// that tolerates the variable card heights (text preview + inline scrubber).
  Widget _masonry(List<GalleryItem> items, int cols) {
    final columns = List.generate(cols, (_) => <Widget>[]);
    for (var i = 0; i < items.length; i++) {
      columns[i % cols].add(
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: _card(items[i]),
        ),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var ci = 0; ci < cols; ci++) ...[
          if (ci > 0) const SizedBox(width: 14),
          Expanded(child: Column(children: columns[ci])),
        ],
      ],
    );
  }

  Widget _emptyBody() {
    final c = context.brand;
    final isAll = _filter == _allFilter;
    return Padding(
      padding: const EdgeInsets.only(top: 80),
      child: Column(
        children: [
          Icon(Icons.library_music_rounded, size: 52, color: c.blueDeep),
          const SizedBox(height: 16),
          Text(
            isAll ? 'No saved audio yet' : 'No clips in this view',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: c.text,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            isAll
                ? 'Generate speech and tap “Save to Gallery”.'
                : 'Save a clip with this project selected, or move an existing one here.',
            style: TextStyle(color: c.text3),
          ),
        ],
      ),
    );
  }

  Widget _card(GalleryItem item) {
    final c = context.brand;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    gradient: c.sliderGradient,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    item.voiceName.isNotEmpty
                        ? item.voiceName.characters.first.toUpperCase()
                        : '?',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      InkWell(
                        onTap: () => _renameClip(item),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                clipTitleOf(item),
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: c.text,
                                ),
                              ),
                            ),
                            const SizedBox(width: 5),
                            Icon(Icons.edit_outlined, size: 12, color: c.text3),
                          ],
                        ),
                      ),
                      Text(
                        '${item.voiceName} · ${_formatDate(item.createdAt)}',
                        style: AppFonts.monoStyle(size: 11, color: c.text3),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              item.text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13.5, color: c.text2, height: 1.45),
            ),
            Divider(height: 24, color: c.outline),
            ValueListenableBuilder<String?>(
              valueListenable: widget.player.playing,
              builder: (context, playingPath, _) {
                return FutureBuilder<String>(
                  future: widget.repository.filePath(item),
                  builder: (context, snap) {
                    final isPlaying =
                        snap.data != null && snap.data == playingPath;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            _playButton(isPlaying, () => _play(item)),
                            const Spacer(),
                            _iconBtn(Icons.edit_outlined, 'Edit & regenerate',
                                () => widget.onEdit(item)),
                            _transcribingId == item.id
                                ? const Padding(
                                    padding: EdgeInsets.all(10),
                                    child: SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    ),
                                  )
                                : _iconBtn(
                                    item.transcript != null
                                        ? Icons.description_rounded
                                        : Icons.description_outlined,
                                    item.transcript != null ? 'Transcript' : 'Transcribe',
                                    () => _transcribe(item),
                                  ),
                            _iconBtn(Icons.download_rounded, 'Export',
                                () => _export(item)),
                            _iconBtn(Icons.delete_outline_rounded, 'Delete',
                                () => _delete(item)),
                            PopupMenuButton<String>(
                              icon: Icon(Icons.more_vert_rounded, color: c.text3),
                              tooltip: 'More',
                              position: PopupMenuPosition.under,
                              onSelected: (v) {
                                if (v == 'move') _moveToProject(item);
                                if (v == 'use') widget.onUseSettings(item);
                                if (v == 'preset') _saveItemAsPreset(item);
                              },
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                  value: 'move',
                                  child: ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: Icon(Icons.drive_file_move_outline),
                                    title: Text('Move to project…'),
                                  ),
                                ),
                                PopupMenuItem(
                                  value: 'use',
                                  child: ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: Icon(Icons.tune_rounded),
                                    title: Text('Use these settings'),
                                  ),
                                ),
                                PopupMenuItem(
                                  value: 'preset',
                                  child: ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: Icon(Icons.bookmark_add_outlined),
                                    title: Text('Save as preset'),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        if (isPlaying)
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: AudioScrubber(player: widget.player),
                          ),
                      ],
                    );
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _playButton(bool isPlaying, VoidCallback onTap) {
    final c = context.brand;
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            gradient: c.sliderGradient,
            shape: BoxShape.circle,
          ),
          child: Icon(
            isPlaying ? Icons.stop_rounded : Icons.play_arrow_rounded,
            color: Colors.white,
            size: 21,
          ),
        ),
      ),
    );
  }

  Widget _iconBtn(IconData icon, String tooltip, VoidCallback onTap) =>
      IconButton(
        icon: Icon(icon, color: context.brand.text2),
        tooltip: tooltip,
        onPressed: onTap,
      );

  String _formatDate(DateTime dt) {
    final d = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}  ${two(d.hour)}:${two(d.minute)}';
  }
}
