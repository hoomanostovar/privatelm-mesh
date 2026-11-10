import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:get/get.dart';
import 'cluster_service.dart';
import 'device_info_service.dart';
import 'hive_service.dart';

/// Node telemetry statistics.
class NodeTelemetry {
  final String nodeId;
  final String nodeName;
  final DateTime connectedAt;
  int tokensGenerated;
  double tokensPerSecond;
  double wattage;
  String status; // 'ready', 'communicating', 'loading', 'unloading', 'benchmarking'

  NodeTelemetry({
    required this.nodeId,
    required this.nodeName,
    required this.connectedAt,
    this.tokensGenerated = 0,
    this.tokensPerSecond = 0.0,
    this.wattage = 15.0,
    this.status = 'ready',
  });

  Duration get uptime => DateTime.now().difference(connectedAt);

  String get formattedUptime {
    final d = uptime;
    if (d.inDays > 0) return '${d.inDays}d ${d.inHours % 24}h';
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
    if (d.inMinutes > 0) return '${d.inMinutes}m ${d.inSeconds % 60}s';
    return '${d.inSeconds}s';
  }
}

/// Mesh Telemetry Service:
/// Tracks live uptime, token production, throughput, and estimated wattage
/// for each participating node and across the pooled cluster.
class MeshTelemetryService extends GetxService {
  final HiveService _hive = Get.find<HiveService>();
  
  final startTime = DateTime.now();
  final nodeTelemetryMap = <String, NodeTelemetry>{}.obs;

  // Local node stats
  final localTokensGenerated = 0.obs;
  final localTokensPerSecond = 0.0.obs;
  final localWattage = 15.0.obs;
  final localStatus = 'ready'.obs;

  Timer? _ticker;

  Duration get localUptime => DateTime.now().difference(startTime);

  String get formattedLocalUptime {
    final d = localUptime;
    if (d.inDays > 0) return '${d.inDays}d ${d.inHours % 24}h';
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
    if (d.inMinutes > 0) return '${d.inMinutes}m ${d.inSeconds % 60}s';
    return '${d.inSeconds}s';
  }

  /// Total tokens generated across all devices on the mesh.
  int get meshTotalTokens {
    int total = localTokensGenerated.value;
    for (final node in nodeTelemetryMap.values) {
      total += node.tokensGenerated;
    }
    return total;
  }

  /// Aggregate real-time tokens per second across active cluster generators.
  double get meshTokensPerSecond {
    double speed = localTokensPerSecond.value;
    for (final node in nodeTelemetryMap.values) {
      speed += node.tokensPerSecond;
    }
    return speed;
  }

  /// Total estimated cluster power consumption in Watts.
  double get meshTotalWattage {
    double total = localWattage.value;
    for (final node in nodeTelemetryMap.values) {
      total += node.wattage;
    }
    return total;
  }

  /// Energy efficiency: Tokens per second per Watt (higher is better).
  double get tokensPerWatt {
    final w = meshTotalWattage;
    if (w <= 0.0) return 0.0;
    return meshTokensPerSecond / w;
  }

  @override
  void onInit() {
    super.onInit();
    final savedTokens = _hive.getSetting<int>('mesh_local_tokens') ?? 0;
    localTokensGenerated.value = savedTokens;

    _updateLocalWattageEstimate(isInferencing: false);

    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      nodeTelemetryMap.refresh();
      _decayTokensPerSecond();
    });
  }

  @override
  void onClose() {
    _ticker?.cancel();
    super.onClose();
  }

  /// Update local power draw estimate based on GPU model, device type, and load.
  void _updateLocalWattageEstimate({required bool isInferencing}) {
    if (kIsWeb) {
      localWattage.value = isInferencing ? 45.0 : 15.0;
      return;
    }

    final dev = Get.isRegistered<DeviceInfoService>() ? Get.find<DeviceInfoService>() : null;
    final gpu = (dev?.gpuName.value ?? '').toLowerCase();

    if (Platform.isWindows || Platform.isLinux) {
      if (gpu.contains('4090')) {
        localWattage.value = isInferencing ? 320.0 : 35.0;
      } else if (gpu.contains('4080') || gpu.contains('3080')) {
        localWattage.value = isInferencing ? 260.0 : 30.0;
      } else if (gpu.contains('4070') || gpu.contains('3070')) {
        localWattage.value = isInferencing ? 200.0 : 25.0;
      } else if (gpu.contains('4060') || gpu.contains('3060')) {
        localWattage.value = isInferencing ? 140.0 : 20.0;
      } else if (gpu.contains('amd') || gpu.contains('radeon') || gpu.contains('xt')) {
        localWattage.value = isInferencing ? 220.0 : 30.0;
      } else {
        // CPU inference
        localWattage.value = isInferencing ? 95.0 : 25.0;
      }
    } else if (Platform.isMacOS) {
      // Apple Silicon
      if (gpu.contains('ultra') || gpu.contains('max')) {
        localWattage.value = isInferencing ? 45.0 : 8.0;
      } else if (gpu.contains('pro')) {
        localWattage.value = isInferencing ? 32.0 : 6.0;
      } else {
        localWattage.value = isInferencing ? 20.0 : 5.0;
      }
    } else if (Platform.isAndroid || Platform.isIOS) {
      // Mobile phone or tablet
      final isTablet = (dev?.deviceNoun ?? '').toLowerCase().contains('tablet');
      if (isTablet) {
        localWattage.value = isInferencing ? 10.5 : 2.5;
      } else {
        localWattage.value = isInferencing ? 7.2 : 1.8;
      }
    }
  }

  /// Called whenever tokens are emitted from the local model or cluster.
  void recordTokenEmission({int tokenCount = 1, double? instantaneousSpeed}) {
    localTokensGenerated.value += tokenCount;
    _hive.setSetting('mesh_local_tokens', localTokensGenerated.value);

    if (instantaneousSpeed != null && instantaneousSpeed > 0) {
      localTokensPerSecond.value = instantaneousSpeed;
    }
    _updateLocalWattageEstimate(isInferencing: true);
    localStatus.value = 'communicating';

    // Attribute tokens proportionally across active cluster workers if in a cluster split
    if (Get.isRegistered<ClusterService>()) {
      final cluster = Get.find<ClusterService>();
      if (cluster.split.length > 1) {
        for (final w in cluster.workers) {
          final id = w.id ?? w.endpoint;
          final existing = nodeTelemetryMap[id];
          if (existing != null) {
            existing.tokensGenerated += tokenCount;
            if (instantaneousSpeed != null && instantaneousSpeed > 0) {
              existing.tokensPerSecond = instantaneousSpeed;
            }
            existing.status = 'communicating';
          }
        }
        nodeTelemetryMap.refresh();
      }
    }
  }

  /// Sets node status ('ready', 'communicating', 'loading', 'unloading', 'benchmarking').
  void setLocalStatus(String status) {
    localStatus.value = status;
    final isBusy = status == 'communicating' || status == 'loading' || status == 'benchmarking';
    _updateLocalWattageEstimate(isInferencing: isBusy);
  }

  /// Gradual decay for speed gauge when idle.
  void _decayTokensPerSecond() {
    if (localTokensPerSecond.value > 0.5) {
      localTokensPerSecond.value *= 0.85;
      if (localTokensPerSecond.value < 0.5) {
        localTokensPerSecond.value = 0.0;
        _updateLocalWattageEstimate(isInferencing: false);
        if (localStatus.value == 'communicating') {
          localStatus.value = 'ready';
        }
      }
    }
  }

  /// Update or register telemetry for a remote peer node.
  void updatePeerTelemetry({
    required String nodeId,
    required String nodeName,
    int? tokensGenerated,
    double? tokensPerSecond,
    double? wattage,
    String? status,
  }) {
    if (!nodeTelemetryMap.containsKey(nodeId)) {
      nodeTelemetryMap[nodeId] = NodeTelemetry(
        nodeId: nodeId,
        nodeName: nodeName,
        connectedAt: DateTime.now(),
        tokensGenerated: tokensGenerated ?? 0,
        tokensPerSecond: tokensPerSecond ?? 0.0,
        wattage: wattage ?? 18.0,
        status: status ?? 'ready',
      );
    } else {
      final t = nodeTelemetryMap[nodeId]!;
      if (tokensGenerated != null) t.tokensGenerated = tokensGenerated;
      if (tokensPerSecond != null) t.tokensPerSecond = tokensPerSecond;
      if (wattage != null) t.wattage = wattage;
      if (status != null) t.status = status;
    }
    nodeTelemetryMap.refresh();
  }
}

