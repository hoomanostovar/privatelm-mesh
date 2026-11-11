import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import '../core/constants.dart';
import '../models/hardware_acceleration.dart';
import 'device_info_service.dart';
import 'hive_service.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart' show ChatMessage;
import 'inference_android.dart' show LoadResult;

/// Desktop inference engine for Windows, macOS, and Linux.
///
/// Runs llama.cpp `llama-server` as a local subprocess on port 50051,
/// providing native GPU hardware acceleration (CUDA, ROCm, Vulkan, DirectML, Metal)
/// and cluster pooling via `--rpc`. Self-provisions engine if missing.
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
  ComputeBackend _activeBackend = ComputeBackend.auto;
  static const int port = 50051;

  bool get isModelLoaded => _isModelLoaded;
  bool get ggufVisionLoaded => _ggufVisionLoaded;
  String get currentModelPath => _currentModelPath;
  String get gpuName => _currentGpuName;
  int get gpuLayers => _currentGpuLayers;
  ComputeBackend get activeBackend => _activeBackend;

  /// Default application engine storage directory.
  static String getEngineDirectory() {
    final sep = Platform.pathSeparator;
    if (Platform.isWindows) {
      final local = Platform.environment['LOCALAPPDATA'] ?? 'C:\\Users\\Default\\AppData\\Local';
      return '$local${sep}PrivateLM${sep}engine';
    } else if (Platform.isMacOS) {
      final home = Platform.environment['HOME'] ?? '';
      return '$home${sep}Library${sep}Application Support${sep}PrivateLM${sep}engine';
    } else {
      final home = Platform.environment['HOME'] ?? '';
      return '$home$sep.local${sep}share${sep}PrivateLM${sep}engine';
    }
  }

  /// Find the built `llama-server` binary on disk.
  static String? findBinary() {
    final execDir = File(Platform.resolvedExecutable).parent.path;
    final exeName = Platform.isWindows ? 'llama-server.exe' : 'llama-server';
    final sep = Platform.pathSeparator;
    final engineDir = getEngineDirectory();

    final candidates = [
      '$execDir$sep$exeName',
      '$execDir${sep}bin$sep$exeName',
      '$execDir${sep}data$sep$exeName',
      '$execDir$sep..${sep}Resources$sep$exeName',
      '$engineDir$sep$exeName',
      '${Directory.current.path}${sep}bin$sep$exeName',
      '${Directory.current.path}${sep}build\\windows\\x64\\runner\\Release$sep$exeName',
      '${Directory.current.path}${sep}build\\windows\\x64\\runner\\Debug$sep$exeName',
      '${Directory.current.path}${sep}build_desktop${sep}build${sep}bin${sep}Release$sep$exeName',
      '${Directory.current.path}${sep}build_desktop${sep}build${sep}bin$sep$exeName',
    ];

    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  /// Automatically provisions the prebuilt engine from GitHub Releases if missing.
  static Future<String?> autoProvisionEngine({void Function(double)? onProgress}) async {
    final engineDir = getEngineDirectory();
    final sep = Platform.pathSeparator;
    final exeName = Platform.isWindows ? 'llama-server.exe' : 'llama-server';
    final targetExe = '$engineDir$sep$exeName';

    if (File(targetExe).existsSync()) return targetExe;

    final dir = Directory(engineDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);

    String assetName;
    if (Platform.isWindows) {
      assetName = 'PrivateLM-Mesh-Windows-x64.zip';
    } else if (Platform.isMacOS) {
      assetName = 'PrivateLM-Mesh-macOS.zip';
    } else {
      assetName = 'PrivateLM-Mesh-Linux-x64.tar.gz';
    }

    final downloadUrl =
        'https://github.com/${AppConstants.githubRepo}/releases/latest/download/$assetName';
    final client = http.Client();
    try {
      var request = http.Request('GET', Uri.parse(downloadUrl));
      var response = await client.send(request);

      if (response.statusCode != 200) {
        final fallbackUrl =
            'https://github.com/${AppConstants.githubRepo}/releases/download/v1.1.5/$assetName';
        request = http.Request('GET', Uri.parse(fallbackUrl));
        response = await client.send(request);
      }

      if (response.statusCode != 200) {
        return null;
      }

      final totalBytes = response.contentLength ?? 25000000;
      var receivedBytes = 0;
      final bytesBuilder = BytesBuilder();

      await for (final chunk in response.stream) {
        bytesBuilder.add(chunk);
        receivedBytes += chunk.length;
        if (onProgress != null && totalBytes > 0) {
          final progress = (receivedBytes / totalBytes).clamp(0.0, 1.0);
          onProgress(0.02 + progress * 0.15);
        }
      }

      final downloadedBytes = bytesBuilder.takeBytes();
      if (assetName.endsWith('.zip')) {
        final archive = ZipDecoder().decodeBytes(downloadedBytes);
        for (final file in archive) {
          if (file.isFile) {
            final filename = file.name.split('/').last;
            if (filename.endsWith('.exe') || filename.endsWith('.dll') || filename == 'llama-server') {
              final outFile = File('$engineDir$sep$filename');
              outFile.writeAsBytesSync(file.content as List<int>);
            }
          }
        }
      }

      if (File(targetExe).existsSync()) {
        if (!Platform.isWindows) {
          Process.runSync('chmod', ['+x', targetExe]);
        }
        return targetExe;
      }
    } catch (e) {
      print('[DesktopEngine] Engine auto-provisioning failed: $e');
    } finally {
      client.close();
    }
    return null;
  }

  /// Helper to spawn llama-server process and wait until the health endpoint is 200 OK.
  Future<({bool success, String? error, int? exitCode})> _startProcessAndAwaitHealth({
    required String binary,
    required List<String> args,
    void Function(double)? onProgress,
    int timeoutSeconds = 60,
  }) async {
    final stderrLines = <String>[];

    if (Platform.isWindows) {
      try {
        Process.runSync('taskkill', ['/F', '/IM', 'llama-server.exe', '/T']);
      } catch (_) {}
    }
    // Allow OS network stack to release port cleanly
    await Future.delayed(const Duration(milliseconds: 350));

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
        final trimmed = line.trim();
        if (trimmed.isNotEmpty) print('[llama-server] $trimmed');
      });

      _serverProcess!.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        final trimmed = line.trim();
        if (trimmed.isNotEmpty) {
          stderrLines.add(trimmed);
          if (stderrLines.length > 30) stderrLines.removeAt(0);
          print('[llama-server:err] $trimmed');
        }
      });

      final healthUri = Uri.parse('http://127.0.0.1:$port/health');
      final maxIters = timeoutSeconds * 2;
      for (var i = 0; i < maxIters; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        onProgress?.call(0.1 + (i / maxIters.toDouble()) * 0.85);

        final exitCode = await _serverProcess?.exitCode.timeout(
          const Duration(milliseconds: 10),
          onTimeout: () => -999,
        );
        if (exitCode != -999) {
          final errDetail = stderrLines.isNotEmpty ? stderrLines.join(' | ') : 'Process terminated';
          return (
            success: false,
            error: 'llama-server exited with code $exitCode: $errDetail',
            exitCode: exitCode,
          );
        }

        try {
          final res = await http.get(healthUri).timeout(const Duration(seconds: 1));
          if (res.statusCode == 200) {
            return (success: true, error: null, exitCode: null);
          }
          if (res.statusCode == 503) {
            print('[DesktopEngine] llama-server loading weights (HTTP 503)...');
          }
        } catch (_) {}
      }

      return (
        success: false,
        error: 'Timed out waiting for local llama-server to start.',
        exitCode: null,
      );
    } catch (e) {
      return (
        success: false,
        error: 'Failed to launch desktop inference engine: $e',
        exitCode: null,
      );
    }
  }

  /// Start `llama-server` with the model, GPU layers, hardware acceleration, and cluster workers.
  Future<LoadResult> loadModel({
    required String modelPath,
    int threads = 0,
    int contextSize = 2048,
    int gpuLayers = -1,
    String? mmprojPath,
    List<String>? rpcEndpoints,
    void Function(double)? onProgress,
  }) async {
    await unloadModel();
    if (Platform.isWindows) {
      try {
        Process.runSync('taskkill', ['/F', '/IM', 'llama-server.exe', '/T']);
      } catch (_) {}
    }
    await Future.delayed(const Duration(milliseconds: 300));

    // Resolve model file path robustly
    var resolvedModelFile = File(modelPath);
    String resolvedModelPath = resolvedModelFile.path;
    if (!resolvedModelFile.existsSync()) {
      final basename = modelPath.split(RegExp(r'[/\\]')).last;
      final candidates = [
        modelPath,
        resolvedModelFile.absolute.path,
        if (Platform.isWindows && Platform.environment['USERPROFILE'] != null)
          '${Platform.environment['USERPROFILE']}\\Documents\\models\\$basename',
        if (Platform.environment['HOME'] != null)
          '${Platform.environment['HOME']}/models/$basename',
        'models/$basename',
      ];
      for (final c in candidates) {
        if (File(c).existsSync()) {
          resolvedModelFile = File(c);
          resolvedModelPath = resolvedModelFile.absolute.path;
          break;
        }
      }
    }

    if (!resolvedModelFile.existsSync()) {
      return LoadResult(
        success: false,
        message: 'Model file not found on disk: $modelPath',
      );
    }
    resolvedModelPath = resolvedModelFile.absolute.path;

    var binary = findBinary();
    if (binary == null) {
      onProgress?.call(0.02);
      binary = await autoProvisionEngine(onProgress: onProgress);
      if (binary == null) {
        return LoadResult(
          success: false,
          message: 'llama-server binary could not be found or downloaded. Please check network connection.',
        );
      }
    }

    final dev = Get.isRegistered<DeviceInfoService>()
        ? Get.find<DeviceInfoService>()
        : null;
    final hive = Get.isRegistered<HiveService>() ? Get.find<HiveService>() : null;

    final detectedGpu = dev?.gpuName.value ?? '';
    final hasGpu = detectedGpu.isNotEmpty;

    // Read user hardware acceleration preferences from settings
    final savedBackendStr = hive?.getSetting<String>(AppConstants.keyComputeBackend);
    final preferredBackend = ComputeBackendExt.fromString(savedBackendStr);
    _activeBackend = preferredBackend == ComputeBackend.auto
        ? (dev?.recommendedBackend ?? ComputeBackend.auto)
        : preferredBackend;

    // Read user-configured GPU offload layers or use auto
    final savedGpuLayers = hive?.getSetting<int>(AppConstants.keyGpuLayers) ?? gpuLayers;
    var effectiveGpuLayers = savedGpuLayers >= 0
        ? savedGpuLayers
        : (_activeBackend.isGpu && hasGpu ? 99 : (hasGpu ? 99 : 0));

    // Read thread configuration
    final configuredThreads = hive?.getSetting<int>(AppConstants.keyInferenceThreads) ?? 0;
    final effectiveThreads = configuredThreads > 0
        ? configuredThreads
        : (threads > 0 ? threads : (Platform.numberOfProcessors > 2 ? Platform.numberOfProcessors - 1 : 2));

    // Read flash attention configuration
    final flashAttention = hive?.getSetting<bool>(AppConstants.keyFlashAttention, defaultValue: true) ?? true;
    final batchSize = hive?.getSetting<int>(AppConstants.keyBatchSize, defaultValue: 512) ?? 512;

    // Pre-flight check for RPC endpoints: verify workers are actually alive before passing to llama-server.
    // If an unreachable RPC endpoint is passed to llama-server, ggml-rpc aborts and crashes the entire process.
    // Also filter out this machine's own IP addresses so Unified Mesh nodes never connect to their own rpc-server.
    final localIps = <String>{'127.0.0.1', 'localhost', '0.0.0.0'};
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          localIps.add(addr.address);
        }
      }
    } catch (_) {}

    final verifiedRpcEndpoints = <String>[];
    if (rpcEndpoints != null && rpcEndpoints.isNotEmpty) {
      for (final ep in rpcEndpoints) {
        try {
          final parts = ep.split(':');
          final host = parts[0];
          final portNum = parts.length > 1 ? (int.tryParse(parts[1]) ?? 50052) : 50052;
          // Skip self-loopback on default local RPC port 50052 (keep ADB USB forwarded ports like 127.0.0.1:50055+)
          if (localIps.contains(host) && portNum == 50052) {
            continue;
          }
          final socket = await Socket.connect(host, portNum, timeout: const Duration(milliseconds: 500));
          socket.destroy();
          verifiedRpcEndpoints.add(ep);
          print('[DesktopEngine] RPC worker $ep is online and responsive.');
        } catch (_) {
          print('[DesktopEngine] RPC worker $ep is unreachable; excluding to prevent crash.');
        }
      }
    }

    var args = <String>[
      '--model', resolvedModelPath,
      '--port', '$port',
      '--host', '127.0.0.1',
      '--ctx-size', '$contextSize',
      '--threads', '$effectiveThreads',
      '--n-gpu-layers', '$effectiveGpuLayers',
      '--batch-size', '$batchSize',
    ];

    if (flashAttention && _activeBackend.isGpu) {
      args.addAll(['--flash-attn', 'on']);
    }

    if (mmprojPath != null && File(mmprojPath).existsSync()) {
      args.addAll(['--mmproj', mmprojPath]);
    }

    if (verifiedRpcEndpoints.isNotEmpty) {
      args.addAll(['--rpc', verifiedRpcEndpoints.join(',')]);
    }

    print('[DesktopEngine] Launching ($activeBackend): $binary ${args.join(' ')}');
    onProgress?.call(0.1);

    // Phase 1: Try normal launch with active configuration
    var launchResult = await _startProcessAndAwaitHealth(
      binary: binary,
      args: args,
      onProgress: onProgress,
    );

    // Phase 2: If crashed and had RPC endpoints, auto-retry standalone without RPC
    if (!launchResult.success && verifiedRpcEndpoints.isNotEmpty) {
      print('[DesktopEngine] RPC startup failed (${launchResult.error}). Retrying in standalone local mode...');
      final noRpcArgs = List<String>.from(args);
      final rpcIdx = noRpcArgs.indexOf('--rpc');
      if (rpcIdx != -1) {
        noRpcArgs.removeAt(rpcIdx);
        if (rpcIdx < noRpcArgs.length) noRpcArgs.removeAt(rpcIdx);
      }
      launchResult = await _startProcessAndAwaitHealth(
        binary: binary,
        args: noRpcArgs,
        onProgress: onProgress,
      );
      if (launchResult.success) {
        args = noRpcArgs;
      }
    }

    // Phase 3: If crashed and had GPU / flash attention, auto-retry in safe CPU mode
    if (!launchResult.success && (effectiveGpuLayers > 0 || args.contains('--flash-attn'))) {
      print('[DesktopEngine] GPU startup failed (${launchResult.error}). Retrying in safe CPU mode...');
      final cpuArgs = List<String>.from(args);
      final faIdx = cpuArgs.indexOf('--flash-attn');
      if (faIdx != -1) {
        cpuArgs.removeAt(faIdx);
        if (faIdx < cpuArgs.length && (cpuArgs[faIdx] == 'on' || cpuArgs[faIdx] == 'off' || cpuArgs[faIdx] == 'auto')) {
          cpuArgs.removeAt(faIdx);
        }
      }
      final gpuIdx = cpuArgs.indexOf('--n-gpu-layers');
      if (gpuIdx != -1 && gpuIdx + 1 < cpuArgs.length) {
        cpuArgs[gpuIdx + 1] = '0';
      }
      final rpcIdx = cpuArgs.indexOf('--rpc');
      if (rpcIdx != -1) {
        cpuArgs.removeAt(rpcIdx);
        if (rpcIdx < cpuArgs.length) cpuArgs.removeAt(rpcIdx);
      }
      launchResult = await _startProcessAndAwaitHealth(
        binary: binary,
        args: cpuArgs,
        onProgress: onProgress,
      );
      if (launchResult.success) {
        _activeBackend = ComputeBackend.cpuAvx2;
        effectiveGpuLayers = 0;
      }
    }

    if (!launchResult.success) {
      await unloadModel();
      return LoadResult(
        success: false,
        message: launchResult.error ?? 'Failed to start inference engine.',
      );
    }

    _isModelLoaded = true;
    _ggufVisionLoaded = mmprojPath != null;
    _currentModelPath = resolvedModelPath;
    _currentGpuName = detectedGpu;
    _currentGpuLayers = effectiveGpuLayers;

    onProgress?.call(1.0);

    final backendStr = effectiveGpuLayers > 0
        ? '${_activeBackend.displayName} ($detectedGpu)'
        : _activeBackend.displayName;
    return LoadResult(
      success: true,
      message: 'Model loaded on $backendStr ($effectiveGpuLayers layers).',
      gpuName: detectedGpu,
      gpuLayers: effectiveGpuLayers,
      runtime: 'llama',
      backend: effectiveGpuLayers > 0 ? 'gpu' : 'cpu',
    );
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
    final healthUri = Uri.parse('http://127.0.0.1:$port/health');

    // If server is momentarily finishing its load state (503), wait for 200 OK before sending
    for (var w = 0; w < 30; w++) {
      try {
        final hRes = await client.get(healthUri).timeout(const Duration(milliseconds: 500));
        if (hRes.statusCode == 200) break;
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 500));
    }

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
      if (streamedResponse.statusCode == 503) {
        yield 'Model is still finishing initialization into memory. Please retry in a few seconds.';
        return;
      }
      if (streamedResponse.statusCode != 200) {
        final errBody = await streamedResponse.stream.bytesToString();
        print('[DesktopEngine] Error ${streamedResponse.statusCode}: $errBody');
        yield 'ERROR: llama-server returned ${streamedResponse.statusCode}: $errBody';
        return;
      }
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
    if (Platform.isWindows) {
      try {
        Process.runSync('taskkill', ['/F', '/IM', 'llama-server.exe', '/T']);
      } catch (_) {}
    }
  }
}
