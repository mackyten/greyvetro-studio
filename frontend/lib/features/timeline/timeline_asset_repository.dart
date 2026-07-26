import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';

/// Local blob storage for timeline-editor-added media (currently: overlay
/// images), keyed by asset id under the app documents directory. No JSON
/// index — the [Timeline] document itself (persisted via
/// [TimelineRepository]) already carries each asset's metadata; this
/// repository only holds the raw bytes.
class TimelineAssetRepository {
  static const _folder = 'grey_vetro_timeline_assets';

  Directory? _dir;

  Future<Directory> _dirRef() async {
    if (_dir != null) return _dir!;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/$_folder');
    if (!await dir.exists()) await dir.create(recursive: true);
    return _dir = dir;
  }

  Future<String> _pathFor(String assetId) async => '${(await _dirRef()).path}/$assetId.bin';

  Future<Uint8List?> get(String assetId) async {
    final file = File(await _pathFor(assetId));
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  Future<void> set(String assetId, Uint8List bytes) async {
    await File(await _pathFor(assetId)).writeAsBytes(bytes);
  }

  Future<void> delete(String assetId) async {
    final file = File(await _pathFor(assetId));
    if (await file.exists()) await file.delete();
  }
}
