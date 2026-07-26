import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'model/timeline.dart';

/// Local persistence for timelines: one JSON document per project (keyed by
/// the timeline id, which equals the project id in this phase), stored under
/// the app documents directory. Mirrors the web frontend's `timelineRepo.ts`
/// (one timeline per project, browser-local like the storyboard scenes).
class TimelineRepository {
  static const _folder = 'grey_vetro_timeline';
  static const _indexFile = 'timelines.json';

  Directory? _dir;

  Future<Directory> _dirRef() async {
    if (_dir != null) return _dir!;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/$_folder');
    if (!await dir.exists()) await dir.create(recursive: true);
    return _dir = dir;
  }

  Future<File> _indexRef() async => File('${(await _dirRef()).path}/$_indexFile');

  Future<Map<String, dynamic>> _loadAll() async {
    final index = await _indexRef();
    if (!await index.exists()) return {};
    try {
      return jsonDecode(await index.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveAll(Map<String, dynamic> all) async {
    final index = await _indexRef();
    await index.writeAsString(jsonEncode(all));
  }

  Future<void> save(Timeline timeline) async {
    final all = await _loadAll();
    all[timeline.id] = timeline.toJson();
    await _saveAll(all);
  }

  Future<Timeline?> get(String id) async {
    final all = await _loadAll();
    final doc = all[id];
    if (doc == null) return null;
    return Timeline.fromJson(doc as Map<String, dynamic>);
  }

  Future<void> delete(String id) async {
    final all = await _loadAll();
    if (all.remove(id) != null) await _saveAll(all);
  }
}
