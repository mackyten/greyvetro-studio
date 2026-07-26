import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import '../script/scene_prompt.dart';
import 'stored_scene.dart';

/// Local persistence for storyboards: a single JSON index (all projects'
/// scenes, like the web frontend's single IndexedDB scene store) plus one
/// image file per scene with an image, stored under the app documents
/// directory — mirrors [GalleryRepository]'s metadata-index + files pattern.
class SceneRepository {
  static const _folder = 'grey_vetro_storyboard';
  static const _indexFile = 'storyboard.json';

  Directory? _dir;

  Future<Directory> _dirRef() async {
    if (_dir != null) return _dir!;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/$_folder');
    if (!await dir.exists()) await dir.create(recursive: true);
    return _dir = dir;
  }

  Future<File> _indexRef() async => File('${(await _dirRef()).path}/$_indexFile');

  Future<String> _imagePathFor(String sceneId) async =>
      '${(await _dirRef()).path}/scene_$sceneId.img';

  Future<List<StoredScene>> _loadAll() async {
    final index = await _indexRef();
    if (!await index.exists()) return [];
    try {
      final list = jsonDecode(await index.readAsString()) as List;
      return list.map((e) => StoredScene.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveAll(List<StoredScene> items) async {
    final index = await _indexRef();
    await index.writeAsString(jsonEncode(items.map((e) => e.toJson()).toList()));
  }

  Future<List<StoredScene>> listForProject(String projectId) async {
    final scenes = (await _loadAll()).where((s) => s.projectId == projectId).toList();
    scenes.sort((a, b) => a.order.compareTo(b.order));
    return scenes;
  }

  /// Replaces a project's storyboard with freshly generated scenes, deleting
  /// any previous scenes and their images.
  Future<List<StoredScene>> replaceForProject(
    String projectId,
    String clipId,
    List<ScenePrompt> scenes,
  ) async {
    final all = await _loadAll();
    final kept = <StoredScene>[];
    for (final s in all) {
      if (s.projectId == projectId) {
        final path = await _imagePathFor(s.id);
        final file = File(path);
        if (await file.exists()) await file.delete();
      } else {
        kept.add(s);
      }
    }
    final baseId = DateTime.now().millisecondsSinceEpoch;
    final created = <StoredScene>[
      for (var i = 0; i < scenes.length; i++)
        StoredScene.fromPrompt(
          scenes[i],
          id: '$baseId-$i',
          projectId: projectId,
          clipId: clipId,
          order: i,
        ),
    ];
    await _saveAll([...kept, ...created]);
    return created;
  }

  Future<void> updateScene(
    String id, {
    String? narration,
    String? imagePrompt,
    double? start,
    double? end,
  }) async {
    final all = await _loadAll();
    final idx = all.indexWhere((s) => s.id == id);
    if (idx == -1) return;
    all[idx] = all[idx].copyWith(
      narration: narration,
      imagePrompt: imagePrompt,
      start: start,
      end: end,
    );
    await _saveAll(all);
  }

  Future<void> deleteScene(String id) async {
    final all = await _loadAll();
    all.removeWhere((s) => s.id == id);
    await _saveAll(all);
    final file = File(await _imagePathFor(id));
    if (await file.exists()) await file.delete();
  }

  Future<Uint8List?> getSceneImage(String id) async {
    final file = File(await _imagePathFor(id));
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  Future<void> setSceneImage(String id, Uint8List bytes) async {
    final file = File(await _imagePathFor(id));
    await file.writeAsBytes(bytes);
    final all = await _loadAll();
    final idx = all.indexWhere((s) => s.id == id);
    if (idx != -1) {
      all[idx] = all[idx].copyWith(hasImage: true);
      await _saveAll(all);
    }
  }

  Future<void> removeSceneImage(String id) async {
    final file = File(await _imagePathFor(id));
    if (await file.exists()) await file.delete();
    final all = await _loadAll();
    final idx = all.indexWhere((s) => s.id == id);
    if (idx != -1) {
      all[idx] = all[idx].copyWith(hasImage: false);
      await _saveAll(all);
    }
  }

  /// Reorders a project's scenes and re-anchors their times: each scene keeps
  /// its duration, narration, prompt, and image; start times are recomputed
  /// so the new order stays contiguous from 0.
  Future<List<StoredScene>> reorder(String projectId, List<String> orderedIds) async {
    final all = await _loadAll();
    final byId = {for (final s in all) s.id: s};
    var cursor = 0.0;
    final updated = <StoredScene>[];
    for (var i = 0; i < orderedIds.length; i++) {
      final s = byId[orderedIds[i]];
      if (s == null) continue;
      final duration = s.end - s.start;
      final next = s.copyWith(order: i, start: cursor, end: cursor + duration);
      cursor += duration;
      updated.add(next);
    }
    final untouched = all.where((s) => s.projectId != projectId).toList();
    await _saveAll([...untouched, ...updated]);
    return updated;
  }

  /// Removes every scene (and image) belonging to a deleted project.
  Future<void> deleteForProject(String projectId) async {
    final all = await _loadAll();
    final kept = <StoredScene>[];
    for (final s in all) {
      if (s.projectId == projectId) {
        final file = File(await _imagePathFor(s.id));
        if (await file.exists()) await file.delete();
      } else {
        kept.add(s);
      }
    }
    await _saveAll(kept);
  }
}
