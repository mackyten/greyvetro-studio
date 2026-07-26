import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import '../stt/transcript_model.dart';
import 'gallery_item.dart';

/// Local persistence for generated audio: MP3 files plus a JSON index,
/// stored under the app documents directory.
class GalleryRepository {
  static const _folder = 'grey_vetro_gallery';
  static const _indexFile = 'gallery.json';

  Directory? _dir;

  Future<Directory> _dirRef() async {
    if (_dir != null) return _dir!;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/$_folder');
    if (!await dir.exists()) await dir.create(recursive: true);
    return _dir = dir;
  }

  Future<File> _indexRef() async => File('${(await _dirRef()).path}/$_indexFile');

  Future<List<GalleryItem>> load() async {
    final index = await _indexRef();
    if (!await index.exists()) return [];
    try {
      final list = jsonDecode(await index.readAsString()) as List;
      final items = list
          .map((e) => GalleryItem.fromJson(e as Map<String, dynamic>))
          .toList();
      // Newest first.
      items.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return items;
    } catch (_) {
      return [];
    }
  }

  Future<void> _save(List<GalleryItem> items) async {
    final index = await _indexRef();
    await index.writeAsString(
      jsonEncode(items.map((e) => e.toJson()).toList()),
    );
  }

  /// Absolute path to an item's audio file.
  Future<String> filePath(GalleryItem item) async =>
      '${(await _dirRef()).path}/${item.fileName}';

  Future<GalleryItem> add({
    required Uint8List bytes,
    required String text,
    required String voiceId,
    required String voiceName,
    required double stability,
    required double similarityBoost,
    double style = 0.0,
    bool useSpeakerBoost = false,
    String? projectId,
  }) async {
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final fileName = 'gv_$id.mp3';
    final file = File('${(await _dirRef()).path}/$fileName');
    await file.writeAsBytes(bytes);

    final item = GalleryItem(
      id: id,
      fileName: fileName,
      text: text,
      voiceId: voiceId,
      voiceName: voiceName,
      stability: stability,
      similarityBoost: similarityBoost,
      style: style,
      useSpeakerBoost: useSpeakerBoost,
      createdAt: DateTime.now(),
      projectId: projectId,
    );

    final items = await load();
    items.insert(0, item);
    await _save(items);
    return item;
  }

  Future<void> delete(GalleryItem item) async {
    final file = File(await filePath(item));
    if (await file.exists()) await file.delete();
    final items = await load();
    items.removeWhere((e) => e.id == item.id);
    await _save(items);
  }

  Future<void> _update(String id, GalleryItem Function(GalleryItem) transform) async {
    final items = await load();
    final idx = items.indexWhere((e) => e.id == id);
    if (idx == -1) return;
    items[idx] = transform(items[idx]);
    await _save(items);
  }

  /// Moves a clip into [projectId] (null = Unsorted).
  Future<void> updateProjectId(String itemId, String? projectId) => _update(
        itemId,
        (item) => item.copyWith(projectId: projectId, clearProjectId: projectId == null),
      );

  /// Renames a clip's display title.
  Future<void> updateTitle(String itemId, String title) =>
      _update(itemId, (item) => item.copyWith(title: title));

  /// Persists a clip's word-timestamped STT transcript.
  Future<void> updateTranscript(String itemId, Transcript transcript) =>
      _update(itemId, (item) => item.copyWith(transcript: transcript));

  /// Moves every clip belonging to a deleted project into Unsorted.
  Future<void> clearProjectId(String projectId) async {
    final items = await load();
    var changed = false;
    for (var i = 0; i < items.length; i++) {
      if (items[i].projectId == projectId) {
        items[i] = items[i].copyWith(clearProjectId: true);
        changed = true;
      }
    }
    if (changed) await _save(items);
  }
}
