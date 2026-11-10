import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' show IconData, Icons;
import 'package:get/get.dart';
import '../models/hardware_acceleration.dart';
import '../models/transport_type.dart';
import 'device_info_service.dart';
import 'inference_service.dart';
import 'mesh_telemetry_service.dart';
import 'mesh_distribution_service.dart';

/// Represents a discovered peer device participating in the PrivateLM Mesh.
class MeshNode {
  final String id;
  final String name;
  final String host;
  final int port;
  final String deviceType; // 'PC', 'Mac', 'Linux', 'Phone', 'Tablet'
  final String gpuName;
  final double gpuVramGB;
  final double totalRamGB;
  final double freeRamGB;
  final String transportType;
  final String hardwareBackend;
  final String status; // 'ready', 'worker', 'master', 'communicating', 'loading', 'benchmarking'
  final String? activeModel;
  final String? activeModelName;
  final double? activeModelSizeMB;
  final int uptimeSeconds;
  final int tokensGenerated;
  final double tokensPerSec;
  final double wattage;
  final DateTime lastSeen;

  const MeshNode({
    required this.id,
    required this.name,
    required this.host,
    this.port = 50052,
    required this.deviceType,
    this.gpuName = '',
    this.gpuVramGB = 0.0,
    this.totalRamGB = 0.0,
    this.freeRamGB = 0.0,
    this.transportType = 'wifi',
    this.hardwareBackend = 'Auto',
    this.status = 'ready',
    this.activeModel,
    this.activeModelName,
    this.activeModelSizeMB,
    this.uptimeSeconds = 0,
    this.tokensGenerated = 0,
    this.tokensPerSec = 0.0,
    this.wattage = 15.0,
    required this.lastSeen,
  });

  String get endpoint => '$host:$port';

  IconData get icon {
    switch (deviceType.toLowerCase()) {
      case 'pc':
      case 'windows pc':
      case 'linux pc':
        return Icons.desktop_windows_rounded;
      case 'mac':
        return Icons.laptop_mac_rounded;
      case 'tablet':
      case 'ipad':
        return Icons.tablet_android_rounded;
      case 'iphone':
      case 'phone':
      case 'android phone':
      default:
        return Icons.smartphone_rounded;
    }
  }

  TransportType get transport => TransportTypeExt.fromString(transportType);

  MeshNode copyWith({
    String? host,
    int? port,
    double? freeRamGB,
    String? status,
    String? activeModel,
    int? tokensGenerated,
    double? tokensPerSec,
    double? wattage,
    DateTime? lastSeen,
  }) =>
      MeshNode(
        id: id,
        name: name,
        host: host ?? this.host,
        port: port ?? this.port,
        deviceType: deviceType,
        gpuName: gpuName,
        gpuVramGB: gpuVramGB,
        totalRamGB: totalRamGB,
        freeRamGB: freeRamGB ?? this.freeRamGB,
        transportType: transportType,
        hardwareBackend: hardwareBackend,
        status: status ?? this.status,
        activeModel: activeModel ?? this.activeModel,
        activeModelName: activeModelName,
        activeModelSizeMB: activeModelSizeMB,
        uptimeSeconds: uptimeSeconds,
        tokensGenerated: tokensGenerated ?? this.tokensGenerated,
        tokensPerSec: tokensPerSec ?? this.tokensPerSec,
        wattage: wattage ?? this.wattage,
        lastSeen: lastSeen ?? this.lastSeen,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'port': port,
        'deviceType': deviceType,
        'gpuName': gpuName,
        'gpuVramGB': gpuVramGB,
        'totalRamGB': totalRamGB,
        'freeRamGB': freeRamGB,
        'transportType': transportType,
        'hardwareBackend': hardwareBackend,
        'status': status,
        'activeModel': activeModel,
        'activeModelName': activeModelName,
        'activeModelSizeMB': activeModelSizeMB,
        'uptimeSeconds': uptimeSeconds,
        'tokensGenerated': tokensGenerated,
        'tokensPerSec': tokensPerSec,
        'wattage': wattage,
      };

  factory MeshNode.fromJson(Map<String, dynamic> json, String remoteAddress) {
    return MeshNode(
      id: json['id'] as String? ?? remoteAddress,
      name: json['name'] as String? ?? remoteAddress,
      host: remoteAddress,
      port: (json['port'] as num?)?.toInt() ?? 50052,
      deviceType: json['deviceType'] as String? ?? 'Device',
      gpuName: json['gpuName'] as String? ?? '',
      gpuVramGB: ((json['gpuVramGB'] as num?) ?? 0.0).toDouble(),
      totalRamGB: ((json['totalRamGB'] as num?) ?? 0.0).toDouble(),
      freeRamGB: ((json['freeRamGB'] as num?) ?? 0.0).toDouble(),
      transportType: json['transportType'] as String? ?? 'wifi',
      hardwareBackend: json['hardwareBackend'] as String? ?? 'Auto',
      status: json['status'] as String? ?? 'ready',
      activeModel: json['activeModel'] as String?,
      activeModelName: json['activeModelName'] as String?,
      activeModelSizeMB: ((json['activeModelSizeMB'] as num?) ?? 0.0).toDouble(),
      uptimeSeconds: (json['uptimeSeconds'] as num?)?.toInt() ?? 0,
      tokensGenerated: (json['tokensGenerated'] as num?)?.toInt() ?? 0,
      tokensPerSec: ((json['tokensPerSec'] as num?) ?? 0.0).toDouble(),
      wattage: ((json['wattage'] as num?) ?? 15.0).toDouble(),
      lastSeen: DateTime.now(),
    );
  }
}

/// Mesh Discovery & Presence Service.
///
/// Every node running PrivateLM Mesh announces itself over local UDP broadcast (port 50053).
/// Allows real-time live inventory auditing of online devices, pooled VRAM/RAM capacity,
/// and automated capability evaluation for running large models across phones, tablets, and PCs.
class MeshDiscoveryService extends GetxService {
  static const int beaconPort = 50053;
  static const String magicHeader = 'PLMESH_V1:';

  final onlineNodes = <String, MeshNode>{}.obs;
  RawDatagramSocket? _socket;
  Timer? _beaconTimer;
  Timer? _pruneTimer;

  String? _localNodeId;
  String get localNodeId => _localNodeId ??= 'node_${Platform.operatingSystem}_${DateTime.now().millisecondsSinceEpoch % 100000}';

  @override
  void onInit() {
    super.onInit();
    if (!kIsWeb) {
      _startDiscovery();
    }
  }

  @override
  void onClose() {
    _beaconTimer?.cancel();
    _pruneTimer?.cancel();
    _socket?.close();
    super.onClose();
  }

  /// Total online nodes excluding local host.
  List<MeshNode> get peerNodes => onlineNodes.values.where((n) => n.id != localNodeId).toList();

  /// Total pooled cluster VRAM (GB) across all live mesh devices.
  double get totalMeshVramGB {
    final dev = Get.isRegistered<DeviceInfoService>() ? Get.find<DeviceInfoService>() : null;
    final localVram = dev?.gpuVramGB.value ?? 0.0;
    final remoteVram = peerNodes.fold<double>(0.0, (sum, n) => sum + n.gpuVramGB);
    return localVram + remoteVram;
  }

  /// Total pooled available memory (GB) across all live mesh devices.
  double get totalMeshFreeRamGB {
    final dev = Get.isRegistered<DeviceInfoService>() ? Get.find<DeviceInfoService>() : null;
    final localFree = dev?.availableRamGB.value ?? 4.0;
    final remoteFree = peerNodes.fold<double>(0.0, (sum, n) => sum + n.freeRamGB);
    return localFree + remoteFree;
  }

  /// Evaluates what class of models can be run across the current mesh topology.
  String get meshModelRecommendation {
    final totalPool = totalMeshFreeRamGB;
    final count = peerNodes.length + 1;

    if (totalPool >= 45.0) {
      return '🚀 Elite Mesh ($count devices · ${totalPool.toStringAsFixed(1)} GB Pool): Can run 70B MoE (Llama-3 70B, Qwen 72B)';
    } else if (totalPool >= 22.0) {
      return '⚡ Heavy Mesh ($count devices · ${totalPool.toStringAsFixed(1)} GB Pool): Can run 27B-32B models (Qwen 32B, Gemma 27B)';
    } else if (totalPool >= 12.0) {
      return '💪 Strong Mesh ($count devices · ${totalPool.toStringAsFixed(1)} GB Pool): Can run 14B models (Qwen2.5 14B, DeepSeek 14B)';
    } else if (totalPool >= 6.0) {
      return '✨ Balanced Mesh ($count devices · ${totalPool.toStringAsFixed(1)} GB Pool): Can run 7B-8B models (Llama 3.1 8B, Qwen 7B)';
    } else {
      return '📱 Compact Mesh ($count devices · ${totalPool.toStringAsFixed(1)} GB Pool): Best for 1B-3B models';
    }
  }

  Future<void> _startDiscovery() async {
    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        beaconPort,
        reuseAddress: true,
        reusePort: !Platform.isWindows,
      );
      _socket?.broadcastEnabled = true;

      _socket?.listen((event) {
        if (event == RawSocketEvent.read) {
          final dg = _socket?.receive();
          if (dg != null) {
            _handlePacket(dg);
          }
        }
      });

      // Periodic broadcast beacon (every 4 seconds)
      _beaconTimer = Timer.periodic(const Duration(seconds: 4), (_) => broadcastPresence());
      broadcastPresence();

      // Prune inactive nodes (timeout after 12 seconds of no heartbeats)
      _pruneTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        final now = DateTime.now();
        onlineNodes.removeWhere((id, node) {
          return id != localNodeId && now.difference(node.lastSeen).inSeconds > 12;
        });
      });
    } catch (e) {
      print('[MeshDiscovery] Failed to bind UDP socket: $e');
    }
  }

  /// Sends a presence beacon announcing this node's hardware and availability.
  Future<void> broadcastPresence() async {
    if (_socket == null) return;

    final dev = Get.isRegistered<DeviceInfoService>() ? Get.find<DeviceInfoService>() : null;
    final inf = Get.isRegistered<InferenceService>() ? Get.find<InferenceService>() : null;
    final telem = Get.isRegistered<MeshTelemetryService>() ? Get.find<MeshTelemetryService>() : null;

    final gpuName = dev?.gpuName.value ?? '';
    final gpuVram = dev?.gpuVramGB.value ?? 0.0;
    final totalRam = dev?.totalRamGB.value ?? 8.0;
    final freeRam = dev?.availableRamGB.value ?? 4.0;
    final deviceType = dev?.deviceNoun ?? 'Device';
    final activeModel = inf?.loadedModelName.value ?? '';

    String localTransport = 'wifi';
    try {
      final ifaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final iface in ifaces) {
        final name = iface.name.toLowerCase();
        if (name.contains('ethernet') || name.startsWith('eth') || name.startsWith('enp')) {
          localTransport = 'ethernet';
          break;
        }
      }
    } catch (_) {}

    final payload = jsonEncode({
      'id': localNodeId,
      'name': '${Platform.localHostname} (${dev?.deviceNoun ?? "Node"})',
      'port': 50052,
      'deviceType': deviceType,
      'gpuName': gpuName,
      'gpuVramGB': gpuVram,
      'totalRamGB': totalRam,
      'freeRamGB': freeRam,
      'transportType': localTransport,
      'hardwareBackend': dev?.recommendedBackend.displayName ?? 'Auto',
      'status': telem?.localStatus.value ?? 'ready',
      'activeModel': activeModel,
      'activeModelName': activeModel,
      'uptimeSeconds': telem?.localUptime.inSeconds ?? 0,
      'tokensGenerated': telem?.localTokensGenerated.value ?? 0,
      'tokensPerSec': telem?.localTokensPerSecond.value ?? 0.0,
      'wattage': telem?.localWattage.value ?? 15.0,
    });

    final message = '$magicHeader$payload';
    final data = utf8.encode(message);

    // Broadcast on general 255.255.255.255
    try {
      _socket?.send(data, InternetAddress('255.255.255.255'), beaconPort);
    } catch (_) {}

    // Also send on interface broadcast addresses
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final parts = addr.address.split('.');
          if (parts.length == 4) {
            final bcast = '${parts[0]}.${parts[1]}.${parts[2]}.255';
            try {
              _socket?.send(data, InternetAddress(bcast), beaconPort);
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
  }

  void _handlePacket(Datagram dg) {
    try {
      final text = utf8.decode(dg.data);
      if (!text.startsWith(magicHeader)) return;

      final jsonStr = text.substring(magicHeader.length);
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      final remoteIp = dg.address.address;

      final node = MeshNode.fromJson(json, remoteIp);
      // Ignore our own loopback UDP broadcast packets so local telemetry is never double-counted
      if (node.id == localNodeId) return;

      onlineNodes[node.id] = node;

      if (Get.isRegistered<MeshTelemetryService>()) {
        Get.find<MeshTelemetryService>().updatePeerTelemetry(
          nodeId: node.id,
          nodeName: node.name,
          tokensGenerated: node.tokensGenerated,
          tokensPerSecond: node.tokensPerSec,
          wattage: node.wattage,
          status: node.status,
        );
      }

      if (node.activeModel != null && node.activeModel!.isNotEmpty) {
        if (Get.isRegistered<MeshDistributionService>()) {
          final dist = Get.find<MeshDistributionService>();
          if (dist.meshOfferedModel.value?.filename != node.activeModel) {
            final offer = MeshModelOffer(
              filename: node.activeModel!,
              modelName: node.activeModelName ?? node.activeModel!,
              sizeMB: node.activeModelSizeMB ?? 4000.0,
              sourceNodeId: node.id,
              sourceNodeName: node.name,
              p2pUrl: 'http://${node.host}:50054/models/${Uri.encodeComponent(node.activeModel!)}',
            );
            dist.meshOfferedModel.value = offer;
            if (dist.autoSyncOnJoin.value) {
              unawaited(dist.syncOfferedModel(offer));
            }
          }
        }
      }
    } catch (_) {}
  }
}
