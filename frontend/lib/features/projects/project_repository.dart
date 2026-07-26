import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'project.dart';

/// Local persistence for projects: a single JSON index stored under the app
/// documents directory (mirrors [PresetRepository]'s pattern), plus a small
/// file tracking which project is currently active in the composer — the
/// Flutter equivalent of the web frontend's `localStorage` active-project key.
class ProjectRepository {
  static const _folder = 'grey_vetro_projects';
  static const _indexFile = 'projects.json';
  static const _activeFile = 'active_project.txt';

  Directory? _dir;

  Future<Directory> _dirRef() async {
    if (_dir != null) return _dir!;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/$_folder');
    if (!await dir.exists()) await dir.create(recursive: true);
    return _dir = dir;
  }

  Future<File> _indexRef() async => File('${(await _dirRef()).path}/$_indexFile');

  Future<File> _activeRef() async => File('${(await _dirRef()).path}/$_activeFile');

  Future<List<Project>> load() async {
    final index = await _indexRef();
    if (!await index.exists()) return [];
    try {
      final list = jsonDecode(await index.readAsString()) as List;
      final items =
          list.map((e) => Project.fromJson(e as Map<String, dynamic>)).toList();
      // Oldest first, matching the web frontend's project list order.
      items.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      return items;
    } catch (_) {
      return [];
    }
  }

  Future<void> _save(List<Project> items) async {
    final index = await _indexRef();
    await index.writeAsString(
      jsonEncode(items.map((e) => e.toJson()).toList()),
    );
  }

  Future<Project> add(String name) async {
    final project = Project(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name.trim(),
      createdAt: DateTime.now(),
    );
    final items = await load();
    items.add(project);
    await _save(items);
    return project;
  }

  Future<void> rename(String id, String name) async {
    final items = await load();
    final idx = items.indexWhere((p) => p.id == id);
    if (idx == -1) return;
    items[idx] = items[idx].copyWith(name: name.trim());
    await _save(items);
  }

  /// Removes the project. Callers are responsible for moving its clips to
  /// Unsorted (see `GalleryRepository.clearProjectId`) and clearing it as the
  /// active project if it was selected.
  Future<void> delete(String id) async {
    final items = await load();
    items.removeWhere((p) => p.id == id);
    await _save(items);
  }

  Future<String?> loadActiveId() async {
    final file = await _activeRef();
    if (!await file.exists()) return null;
    final id = (await file.readAsString()).trim();
    return id.isEmpty ? null : id;
  }

  Future<void> setActiveId(String? id) async {
    final file = await _activeRef();
    if (id == null) {
      if (await file.exists()) await file.delete();
    } else {
      await file.writeAsString(id);
    }
  }
}
