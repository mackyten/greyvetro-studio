import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../features/script/scene_prompt.dart';
import '../features/storyboard/render_scene_payload.dart';
import '../features/stt/transcript_model.dart';
import '../features/timeline/model/timeline.dart';
import '../features/usage/usage_model.dart';
import '../features/voices/voice_model.dart';

class ApiClient {
  static const _base = 'http://localhost:5050';
  final _client = http.Client();

  Future<List<VoiceModel>> getVoices() async {
    final res = await _client.get(Uri.parse('$_base/voices'));
    _checkStatus(res);
    final list = jsonDecode(res.body) as List;
    return list.map((e) => VoiceModel.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<UsageModel> getUsage() async {
    final res = await _client.get(Uri.parse('$_base/usage'));
    _checkStatus(res);
    return UsageModel.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<Uint8List> generateSpeech({
    required String text,
    required String voiceId,
    double stability = 0.5,
    double similarityBoost = 0.75,
    double style = 0.0,
    bool useSpeakerBoost = false,
  }) async {
    final res = await _client.post(
      Uri.parse('$_base/tts'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'text': text,
        'voiceId': voiceId,
        'stability': stability,
        'similarityBoost': similarityBoost,
        'style': style,
        'useSpeakerBoost': useSpeakerBoost,
      }),
    );
    _checkStatus(res);
    return res.bodyBytes;
  }

  Future<Transcript> transcribeAudio({
    required Uint8List bytes,
    required String fileName,
  }) async {
    final req = http.MultipartRequest('POST', Uri.parse('$_base/stt'))
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: fileName));
    final res = await http.Response.fromStream(await _client.send(req));
    _checkStatus(res);
    return Transcript.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<String> generateScript({
    required String topic,
    String? instructions,
    int targetSeconds = 60,
  }) async {
    final res = await _client.post(
      Uri.parse('$_base/script'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'topic': topic,
        'instructions': instructions,
        'targetSeconds': targetSeconds,
      }),
    );
    _checkStatus(res);
    return (jsonDecode(res.body) as Map<String, dynamic>)['script'] as String;
  }

  Future<List<ScenePrompt>> generateScenes({
    required Transcript transcript,
    String? instructions,
  }) async {
    final res = await _client.post(
      Uri.parse('$_base/script/scenes'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'transcript': transcript.toJson(),
        'instructions': instructions,
      }),
    );
    _checkStatus(res);
    final list = (jsonDecode(res.body) as Map<String, dynamic>)['scenes'] as List;
    return list.map((e) => ScenePrompt.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// AI-generates a scene image from its visual prompt (Gemini Nano Banana Pro).
  Future<Uint8List> generateSceneImage(String prompt) async {
    final res = await _client.post(
      Uri.parse('$_base/script/scenes/image'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'prompt': prompt}),
    );
    _checkStatus(res);
    return res.bodyBytes;
  }

  /// Assembles composited scene frames + voiceover into a vertical mp4
  /// (server-side ffmpeg; the legacy scene-based render path).
  Future<Uint8List> renderStoryboard({
    required Uint8List audio,
    required List<RenderScenePayload> scenes,
  }) async {
    final req = http.MultipartRequest('POST', Uri.parse('$_base/render'))
      ..files.add(http.MultipartFile.fromBytes('audio', audio, filename: 'voiceover.mp3'));
    final sceneDtos = <Map<String, dynamic>>[];
    for (var i = 0; i < scenes.length; i++) {
      sceneDtos.add({'start': scenes[i].start, 'end': scenes[i].end, 'imageIndex': i});
      req.files.add(
        http.MultipartFile.fromBytes('image-$i', scenes[i].image, filename: 'image-$i.png'),
      );
    }
    req.fields['scenes'] = jsonEncode(sceneDtos);
    final res = await http.Response.fromStream(await _client.send(req));
    _checkStatus(res);
    return res.bodyBytes;
  }

  /// Renders a structured [Timeline] document to a vertical mp4. Asset blobs
  /// (`asset-<sourceId>`) and pre-rendered transparent caption overlay PNGs
  /// (`caption-<clipId>`) ride along as multipart parts — no ffmpeg syntax
  /// ever crosses the wire, the backend compiles the filter graph.
  Future<Uint8List> renderTimeline({
    required Timeline timeline,
    required Map<String, Uint8List> assets,
    Map<String, Uint8List> captions = const {},
  }) async {
    final req = http.MultipartRequest('POST', Uri.parse('$_base/render'))
      ..fields['timeline'] = jsonEncode(timeline.toJson());
    assets.forEach((id, bytes) {
      req.files.add(http.MultipartFile.fromBytes('asset-$id', bytes, filename: '$id.bin'));
    });
    captions.forEach((id, bytes) {
      req.files.add(http.MultipartFile.fromBytes('caption-$id', bytes, filename: '$id.png'));
    });
    final res = await http.Response.fromStream(await _client.send(req));
    _checkStatus(res);
    return res.bodyBytes;
  }

  Future<VoiceModel> cloneVoice({
    required String name,
    required String description,
    required List<String> samplePaths,
  }) async {
    final req = http.MultipartRequest('POST', Uri.parse('$_base/voices/clone'))
      ..fields['name'] = name
      ..fields['description'] = description;
    for (final path in samplePaths) {
      req.files.add(await http.MultipartFile.fromPath('files', path));
    }
    final res = await http.Response.fromStream(await _client.send(req));
    _checkStatus(res);
    return VoiceModel.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  void _checkStatus(http.Response res) {
    if (res.statusCode < 200 || res.statusCode >= 300) {
      // ASP.NET ProblemDetails wraps the real message in a `detail` field
      // alongside type/title/status boilerplate — surface just that.
      var message = res.body;
      try {
        final problem = jsonDecode(res.body);
        if (problem is Map && problem['detail'] is String && (problem['detail'] as String).isNotEmpty) {
          message = problem['detail'] as String;
        }
      } catch (_) {
        // Not JSON — use the raw body as-is.
      }
      throw Exception('API error ${res.statusCode}: $message');
    }
  }

  void dispose() => _client.close();
}
