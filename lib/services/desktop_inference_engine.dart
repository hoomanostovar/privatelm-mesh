import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'device_info_service.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart' show ChatMessage;
import 'inference_android.dart' show LoadResult;

/// Desktop inference engine for Windows, macOS, and Linux.
///
/// Runs llama.cpp `llama-server` as a local subprocess on port 50051,
/// providing native GPU hardware acceleration (CUDA on Windows, Metal on macOS,
/// Vulkan on Linux) and cluster pooling via `--rpc`.
class DesktopInferenceEngine {
  static final DesktopInferenceEngine instance = DesktopInferenceEngine._();
  DesktopInferenceEngine._();

  Process? _serverProcess;
  http.Client? _activeClient;
  bool _isModelLoaded = false;
  bool _ggufVisionLoaded = false;
  String _currentModelPath = '';
  String _currentGpuName = '';
  int _currentGpuLayers = 0;
  static const int port = 50051;

  bool get isModelLoaded => _isModelLoaded;
  bool get ggufVisionLoaded => _ggufVisionLoaded;
  String get currentModelPath => _currentModelPath;
  String get gpuName => _currentGpuName;
  int get gpuLayers => _currentGpuLayers;

  /// Find the built `llama-server` binary on disk.
  static String? findBinary() {
    final execDir = File(Platform.resolvedExecutable).parent.path;
    final exeName = Platform.isWindows ? 'llama-server.exe' : 'llama-server';
    final sep = Platform.pathSeparator;

    final candidates = [
      '$execDir$sep$exeName',
      '$execDir${sep}data$sep$exeName',
      '$execDir${sep}..${sep}Resources$sep$exeName',
      '${Directory.current.path}${sep}bin$sep$exeName',
      '${Directory.current.path}${sep}build_desktop${sep}build${sep}bin${sep}Release$sep$exeName',
      '${Directory.current.path}${sep}build_desktop${sep}build${sep}bin$sep$exeName',
    ];

    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  /// Start `llama-server` with the model, GPU layers, and cluster workers.
  Future<LoadResult> loadModel({
    required String modelPath,
    int threads = 4,
    int contextSize = 2048,
    int gpuLayers = 0,
    String? mmprojPath,
    List<String>? rpcEndpoints,
    void Function(double)? onProgress,
  }) async {
    await unloadModel();

    final binary = findBinary();
    if (binary == null) {
      return LoadResult(
        success: false,
        message: 'llama-server binary not found on desktop. Please build desktop engine.',
      );
    }

    final dev = Get.isRegistered<DeviceInfoService>()
        ? Get.find<DeviceInfoService>()
        : null;
    final detectedGpu = dev?.gpuName.value ?? '';
    final hasGpu = detectedGpu.isNotEmpty;
    final effectiveGpuLayers = hasGpu && gpuLayers > 0 ? gpuLayers : (hasGpu ? 99 : 0);

    final args = <String>[
      '--model', modelPath,
      '--port', '$port',
      '--host', '127.0.0.1',
      '--ctx-size', '$contextSize',
      '--threads', '$threads',
      '--n-gpu-layers', '$effectiveGpuLayers',
    ];

    if (mmprojPath != null && File(mmprojPath).existsSync()) {
      args.addAll(['--mmproj', mmprojPath]);
    }

    if (rpcEndpoints != null && rpcEndpoints.isNotEmpty) {
      args.addAll(['--rpc', rpcEndpoints.join(',')]);
    }

    print('[DesktopEngine] Launching: $binary ${args.join(' ')}');
    onProgress?.call(0.1);

    try {
      _serverProcess = await Process.start(
        binary,
        args,
        workingDirectory: File(binary).parent.path,
        mode: ProcessStartMode.normal,
      );

      _serverProcess!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        print('[llama-server] $line');
      });

      _serverProcess!.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        print('[llama-server:err] $line');
      });

      // Wait for server health endpoint to respond
      final healthUri = Uri.parse('http://127.0.0.1:$port/health');
      var ready = false;
      for (var i = 0; i < 40; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        onProgress?.call(0.1 + (i / 40.0) * 0.85);

        // Check if process crashed early
        final exitCode = await _serverProcess?.exitCode.timeout(
          const Duration(milliseconds: 10),
          onTimeout: () => -999,
        );
        if (exitCode != -999) {
          return LoadResult(
            success: false,
            message: 'llama-server exited prematurely with code $exitCode.',
          );
        }

        try {
          final res = await http.get(healthUri).timeout(const Duration(seconds: 1));
          if (res.statusCode == 200 || res.statusCode == 503) {
            ready = true;
            break;
          }
        } catch (_) {}
      }

      if (!ready) {
        await unloadModel();
        return LoadResult(
          success: false,
          message: 'Timed out waiting for local llama-server to start.',
        );
      }

      _isModelLoaded = true;
      _ggufVisionLoaded = mmprojPath != null;
      _currentModelPath = modelPath;
      _currentGpuName = detectedGpu;
      _currentGpuLayers = effectiveGpuLayers;

      onProgress?.call(1.0);

      final backendStr = effectiveGpuLayers > 0 ? 'GPU ($detectedGpu)' : 'CPU';
      return LoadResult(
        success: true,
        message: 'Model loaded on $backendStr ($effectiveGpuLayers layers).',
        gpuName: detectedGpu,
        gpuLayers: effectiveGpuLayers,
        runtime: 'llama',
        backend: effectiveGpuLayers > 0 ? 'gpu' : 'cpu',
      );
    } catch (e) {
      await unloadModel();
      return LoadResult(
        success: false,
        message: 'Failed to launch desktop inference engine: $e',
      );
    }
  }

  /// Generate chat completion with SSE streaming.
  Stream<String> generateChat({
    required List<ChatMessage> messages,
    int maxTokens = 512,
    double temperature = 0.7,
    double topP = 0.9,
    int topK = 40,
    double repeatPenalty = 1.1,
  }) async* {
    if (!_isModelLoaded) throw StateError('No model loaded');

    final client = http.Client();
    _activeClient = client;

    final uri = Uri.parse('http://127.0.0.1:$port/v1/chat/completions');
    final formattedMessages = messages.map((m) {
      return {'role': m.role, 'content': m.content};
    }).toList();

    final body = jsonEncode({
      'messages': formattedMessages,
      'max_tokens': maxTokens,
      'temperature': temperature,
      'top_p': topP,
      'stream': true,
    });

    final request = http.Request('POST', uri)
      ..headers['Content-Type'] = 'application/json'
      ..headers['Accept'] = 'text/event-stream'
      ..body = body;

    try {
      final streamedResponse = await client.send(request);
      final lines = streamedResponse.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      await for (final line in lines) {
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data == '[DONE]') break;
        try {
          final json = jsonDecode(data);
          final choices = json['choices'] as List?;
          if (choices != null && choices.isNotEmpty) {
            final delta = choices[0]['delta'];
            if (delta != null && delta['content'] != null) {
              yield delta['content'] as String;
            }
          }
        } catch (_) {}
      }
    } finally {
      if (identical(_activeClient, client)) {
        _activeClient = null;
      }
      client.close();
    }
  }

  /// Stop current generation stream.
  Future<void> stopGeneration() async {
    _activeClient?.close();
    _activeClient = null;
  }

  /// Unload model and stop subprocess.
  Future<void> unloadModel() async {
    stopGeneration();
    _isModelLoaded = false;
    _ggufVisionLoaded = false;
    _currentModelPath = '';
    final p = _serverProcess;
    _serverProcess = null;
    if (p != null) {
      try {
        p.kill(ProcessSignal.sigterm);
      } catch (_) {
        p.kill();
      }
    }
  }
}
