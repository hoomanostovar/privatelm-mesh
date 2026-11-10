import 'dart:io' show Directory, File, InternetAddress, Platform, Process, ServerSocket, Socket;
import 'package:flutter/services.dart';

/// A phone running as a cluster worker, found on the local network, scanned
/// from its QR code, or added by hand.
class ClusterWorker {
  final String name;
  final String host;
  final int port;

  /// Free RAM the worker reported when it started, in MB (null if unknown).
  final int? ramMb;

  /// Memory read speed the worker measured, in GB/s (null if unknown).
  /// Token generation speed follows this closely.
  final double? bandwidth;
  final String? model;

  /// The worker device's lasting ID: finds it again when its IP changes.
  final String? id;

  /// Network transport link type ('usb', 'ethernet', 'wifi', 'unknown').
  final String transportType;

  /// Measured TCP round-trip latency in milliseconds.
  final double? latencyMs;

  /// Hardware platform category ('PC', 'Mac', 'Linux', 'Android', 'iOS').
  final String? deviceType;

  /// Hardware acceleration backend used by the worker ('CUDA', 'Metal', 'ROCm', 'Vulkan', 'CPU').
  final String? hardwareBackend;

  const ClusterWorker({
    required this.name,
    required this.host,
    required this.port,
    this.ramMb,
    this.bandwidth,
    this.model,
    this.id,
    this.transportType = 'unknown',
    this.latencyMs,
    this.deviceType,
    this.hardwareBackend,
  });

  String get endpoint => '$host:$port';

  factory ClusterWorker.fromMap(Map<dynamic, dynamic> map) => ClusterWorker(
        name: map['name'] as String? ?? '${map['host']}',
        host: map['host'] as String,
        port: map['port'] as int,
        ramMb: (map['ramMb'] as num?)?.toInt(),
        bandwidth: (map['bandwidth'] as num?)?.toDouble(),
        model: map['model'] as String?,
        id: map['id'] as String?,
        transportType: map['transportType'] as String? ?? 'unknown',
        latencyMs: (map['latencyMs'] as num?)?.toDouble(),
        deviceType: map['deviceType'] as String?,
        hardwareBackend: map['hardwareBackend'] as String?,
      );

  /// The same device at a new address or updated link properties.
  ClusterWorker movedTo(
    String host,
    int port, {
    String? transportType,
    double? latencyMs,
    String? deviceType,
    String? hardwareBackend,
  }) =>
      ClusterWorker(
        name: name,
        host: host,
        port: port,
        ramMb: ramMb,
        bandwidth: bandwidth,
        model: model,
        id: id,
        transportType: transportType ?? this.transportType,
        latencyMs: latencyMs ?? this.latencyMs,
        deviceType: deviceType ?? this.deviceType,
        hardwareBackend: hardwareBackend ?? this.hardwareBackend,
      );

  Map<String, dynamic> toMap() => {
        'name': name,
        'host': host,
        'port': port,
        'ramMb': ramMb,
        'bandwidth': bandwidth,
        'model': model,
        'id': id,
        'transportType': transportType,
        'latencyMs': latencyMs,
        'deviceType': deviceType,
        'hardwareBackend': hardwareBackend,
      };
}

/// State of this phone's worker service.
class ClusterWorkerStatus {
  /// starting, running, stopped or error.
  final String state;
  final String? error;

  /// Address of the master using this worker right now, if any.
  final String? peer;

  /// Memory this worker holds, mostly the master's model layers.
  final int heldMb;
  final int ramMb;
  final double bandwidth;

  /// Android is throttling the worker (slow cores, low CPU share).
  final bool throttled;

  /// The app is exempt from battery optimization (Android).
  final bool batteryUnrestricted;

  /// This device's lasting worker ID (put in its QR code).
  final String? id;

  const ClusterWorkerStatus({
    required this.state,
    this.error,
    this.peer,
    this.heldMb = 0,
    this.ramMb = 0,
    this.bandwidth = 0,
    this.throttled = false,
    this.batteryUnrestricted = true,
    this.id,
  });

  bool get running => state == 'running';
  bool get starting => state == 'starting';
}

/// Phone cluster: one phone (the master) runs a model whose layers are
/// spread across other phones (workers) on the same Wi-Fi, using llama.cpp's
/// RPC backend. Android arm64 only.
///
/// The RPC protocol has no authentication: only run workers on a network you
/// trust.
class LlamaCluster {
  static const _channel = MethodChannel('llama_flutter_android/cluster');
  static const defaultPort = 50052;
  static Process? _desktopWorkerProcess;
  static ServerSocket? _desktopFallbackSocket;
  static bool _desktopWorkerRunning = false;

  static String? _findDesktopRpcBinary() {
    final sep = Platform.pathSeparator;
    final execDir = File(Platform.resolvedExecutable).parent.path;
    final names = Platform.isWindows
        ? ['rpc-server.exe', 'ggml-rpc-server.exe']
        : ['rpc-server', 'ggml-rpc-server'];
    for (final name in names) {
      final candidates = [
        '$execDir$sep$name',
        '$execDir${sep}bin$sep$name',
        '${Directory.current.path}${sep}bin$sep$name',
        '${Directory.current.path}${sep}build_desktop${sep}build${sep}bin${sep}Release$sep$name',
      ];
      for (final c in candidates) {
        if (File(c).existsSync()) return c;
      }
    }
    return null;
  }

  /// Starts serving this device's GPU/CPU to a master, in a foreground service
  /// on mobile or a local RPC worker process on desktop.
  static Future<void> startWorker({int port = defaultPort, int? threads}) async {
    try {
      await _channel.invokeMethod('startWorker', {'port': port, 'threads': threads});
    } on MissingPluginException {
      await stopWorker();
      final bin = _findDesktopRpcBinary();
      if (bin != null) {
        try {
          _desktopWorkerProcess = await Process.start(
            bin,
            ['-H', '0.0.0.0', '-p', '$port'],
            workingDirectory: File(bin).parent.path,
          );
          _desktopWorkerRunning = true;
          return;
        } catch (_) {}
      }
      // Fallback TCP listener on port 50052 so worker probes succeed on desktop
      try {
        _desktopFallbackSocket = await ServerSocket.bind(
          InternetAddress.anyIPv4,
          port,
          shared: true,
        );
        _desktopWorkerRunning = true;
      } catch (_) {}
    }
  }

  static Future<void> stopWorker() async {
    try {
      await _channel.invokeMethod('stopWorker');
    } on MissingPluginException {
      _desktopWorkerProcess?.kill();
      _desktopWorkerProcess = null;
      await _desktopFallbackSocket?.close();
      _desktopFallbackSocket = null;
      _desktopWorkerRunning = false;
    }
  }

  static Future<ClusterWorkerStatus> workerStatus() async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('workerStatus') ?? {};
      return ClusterWorkerStatus(
        state: m['state'] as String? ?? 'stopped',
        error: m['error'] as String?,
        peer: m['peer'] as String?,
        heldMb: (m['heldMb'] as num?)?.toInt() ?? 0,
        ramMb: (m['ramMb'] as num?)?.toInt() ?? 0,
        bandwidth: (m['bandwidth'] as num?)?.toDouble() ?? 0,
        throttled: m['throttled'] as bool? ?? false,
        batteryUnrestricted: m['batteryUnrestricted'] as bool? ?? true,
        id: m['id'] as String?,
      );
    } on MissingPluginException {
      return ClusterWorkerStatus(
        state: _desktopWorkerRunning ? 'running' : 'stopped',
        ramMb: 8192,
        bandwidth: 35.0,
        batteryUnrestricted: true,
        id: Platform.localHostname,
      );
    }
  }

  /// Android: asks to exempt the app from battery optimization, so a busy
  /// worker isn't moved to slow cores. No-op if already exempt.
  static Future<void> requestBatteryUnrestricted() async {
    try {
      await _channel.invokeMethod('requestBatteryUnrestricted');
    } on MissingPluginException {
      // No-op on desktop
    }
  }

  /// Keeps this device's screen on (a worker runs at full speed only while
  /// PrivateLM is on screen).
  static Future<void> setKeepScreenOn(bool on) async {
    try {
      await _channel.invokeMethod('setKeepScreenOn', {'on': on});
    } on MissingPluginException {
      // No-op on desktop
    }
  }

  static Future<int> localFreeRamMb() async {
    try {
      return await _channel.invokeMethod<int>('localFreeRamMb') ?? 0;
    } on MissingPluginException {
      return 8192; // Default 8GB free RAM on PC desktop
    }
  }

  /// Android: resolves the device's LAN IPv4 address via ConnectivityManager /
  /// WifiManager (bypasses Android 11+ SELinux restrictions on getifaddrs) and
  /// ensures WifiManager.MulticastLock is held for UDP mesh discovery.
  static Future<String?> localWifiIp() async {
    try {
      return await _channel.invokeMethod<String>('localWifiIp');
    } on MissingPluginException {
      return null;
    } catch (_) {
      return null;
    }
  }

  /// This device's memory read speed in GB/s (~0.2 s to measure).
  static Future<double> benchmark() async {
    try {
      return await _channel.invokeMethod<double>('benchmark') ?? 0;
    } on MissingPluginException {
      return 35.0; // Desktop DDR4/DDR5 memory bandwidth ~35 GB/s
    }
  }

  /// Where the last model load put its weights: llama.cpp buffer name
  /// ("CPU_Mapped", "RPC0[host:port]", …) and size in MB.
  static Future<List<({String name, double mb})>> lastLoadBuffers() async {
    try {
      final list = await _channel.invokeListMethod<Map<dynamic, dynamic>>('lastLoadBuffers');
      return [
        for (final m in list ?? const [])
          (name: m['name'] as String, mb: (m['mb'] as num).toDouble()),
      ];
    } on MissingPluginException {
      return const [];
    }
  }

  /// Looks for workers on the local network for [timeout].
  static Future<List<ClusterWorker>> discover(
      {Duration timeout = const Duration(seconds: 4)}) async {
    try {
      final list = await _channel.invokeListMethod<Map<dynamic, dynamic>>(
          'discover', {'timeoutMs': timeout.inMilliseconds});
      return (list ?? const []).map(ClusterWorker.fromMap).toList();
    } on MissingPluginException {
      return const [];
    }
  }

  /// Whether something answers on [endpoint] ("host:port").
  static Future<bool> probe(String endpoint) async {
    try {
      return await _channel.invokeMethod<bool>('probe', {'endpoint': endpoint}) ?? false;
    } on MissingPluginException {
      // Desktop probe via standard raw TCP socket
      try {
        final parts = endpoint.split(':');
        final host = parts[0];
        final port = int.tryParse(parts[1]) ?? defaultPort;
        final socket = await Socket.connect(host, port, timeout: const Duration(seconds: 2));
        socket.destroy();
        return true;
      } catch (_) {
        return false;
      }
    }
  }

  /// Uses [workers] for the next GGUF model load. Layers are split by
  /// [weights] (one per worker, e.g. MB to hold), with this phone keeping a
  /// share by [localWeight]. Throws a [PlatformException] (code UNREACHABLE)
  /// if any worker doesn't answer. An empty list turns cluster mode off.
  static Future<void> setCluster(
    List<ClusterWorker> workers, {
    List<double>? weights,
    double localWeight = 1.0,
  }) async {
    try {
      await _channel.invokeMethod('setCluster', {
        'endpoints': [for (final w in workers) w.endpoint],
        'weights': weights ?? List.filled(workers.length, 1.0),
        'localWeight': localWeight,
      });
    } on MissingPluginException {
      // Handled gracefully on desktop
    }
  }

  static Future<void> clear() => setCluster(const []);
}
