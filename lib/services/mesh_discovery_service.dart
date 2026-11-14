import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' show IconData, Icons;
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:llama_flutter_android/llama_flutter_android.dart';
import '../core/constants.dart';
import '../models/hardware_acceleration.dart';
import '../models/transport_type.dart';
import 'cluster_service.dart';
import 'device_info_service.dart';
import 'hive_service.dart';
import 'inference_service.dart';
import 'mesh_telemetry_service.dart';
import 'mesh_distribution_service.dart';
import 'network_transport_service.dart';

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
  final List<String> alternateHosts;
  final double? latencyMs;

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
    this.alternateHosts = const [],
    this.latencyMs,
  });

  String get endpoint => '$host:$port';

  bool get isOffline => status == 'offline';

  /// True when this device is connected over WAN / 5G / Mobile Hotspot / Overlay VPN.
  bool get isAwayNode =>
      transport.isAwayTransport(latencyMs) ||
      NetworkTransportService.isWanOrOverlayIp(host);

  IconData get icon {
    final lower = deviceType.toLowerCase();
    if (lower.contains('pc') || lower.contains('desktop') || lower.contains('windows') || lower.contains('linux')) {
      return Icons.desktop_windows_rounded;
    }
    if (lower.contains('mac') || lower.contains('laptop')) {
      return Icons.laptop_mac_rounded;
    }
    if (lower.contains('tablet') || lower.contains('ipad') || lower.contains('pad')) {
      return Icons.tablet_android_rounded;
    }
    return Icons.smartphone_rounded;
  }

  TransportType get transport => TransportTypeExt.fromString(transportType);

  MeshNode copyWith({
    String? name,
    String? host,
    int? port,
    double? freeRamGB,
    String? transportType,
    String? status,
    String? activeModel,
    int? tokensGenerated,
    double? tokensPerSec,
    double? wattage,
    DateTime? lastSeen,
    List<String>? alternateHosts,
    double? latencyMs,
  }) =>
      MeshNode(
        id: id,
        name: name ?? this.name,
        host: host ?? this.host,
        port: port ?? this.port,
        deviceType: deviceType,
        gpuName: gpuName,
        gpuVramGB: gpuVramGB,
        totalRamGB: totalRamGB,
        freeRamGB: freeRamGB ?? this.freeRamGB,
        transportType: transportType ?? this.transportType,
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
        alternateHosts: alternateHosts ?? this.alternateHosts,
        latencyMs: latencyMs ?? this.latencyMs,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
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
        'lastSeenMs': lastSeen.millisecondsSinceEpoch,
        if (alternateHosts.isNotEmpty) 'allIps': alternateHosts,
        if (latencyMs != null) 'latencyMs': latencyMs,
      };

  factory MeshNode.fromJson(Map<String, dynamic> json, String remoteAddress) {
    final savedMs = (json['lastSeenMs'] as num?)?.toInt();
    final effectiveHost =
        remoteAddress.isNotEmpty ? remoteAddress : (json['host'] as String? ?? '');
    final rawAllIps = json['allIps'] is List
        ? (json['allIps'] as List)
            .map((e) => e.toString().trim())
            .where((s) => s.isNotEmpty)
            .toList()
        : const <String>[];
    final rawTransport = json['transportType'] as String? ?? 'wifi';
    final effectiveTransport =
        NetworkTransportService.isWanOrOverlayIp(effectiveHost) ? 'wan' : rawTransport;

    return MeshNode(
      id: json['id'] as String? ?? effectiveHost,
      name: json['name'] as String? ?? effectiveHost,
      host: effectiveHost,
      port: (json['port'] as num?)?.toInt() ?? 50052,
      deviceType: json['deviceType'] as String? ?? 'Device',
      gpuName: json['gpuName'] as String? ?? '',
      gpuVramGB: ((json['gpuVramGB'] as num?) ?? 0.0).toDouble(),
      totalRamGB: ((json['totalRamGB'] as num?) ?? 0.0).toDouble(),
      freeRamGB: ((json['freeRamGB'] as num?) ?? 0.0).toDouble(),
      transportType: effectiveTransport,
      hardwareBackend: json['hardwareBackend'] as String? ?? 'Auto',
      status: json['status'] as String? ?? 'ready',
      activeModel: json['activeModel'] as String?,
      activeModelName: json['activeModelName'] as String?,
      activeModelSizeMB: ((json['activeModelSizeMB'] as num?) ?? 0.0).toDouble(),
      uptimeSeconds: (json['uptimeSeconds'] as num?)?.toInt() ?? 0,
      tokensGenerated: (json['tokensGenerated'] as num?)?.toInt() ?? 0,
      tokensPerSec: ((json['tokensPerSec'] as num?) ?? 0.0).toDouble(),
      wattage: ((json['wattage'] as num?) ?? 15.0).toDouble(),
      lastSeen: savedMs != null
          ? DateTime.fromMillisecondsSinceEpoch(savedMs)
          : DateTime.now(),
      alternateHosts: rawAllIps,
      latencyMs: (json['latencyMs'] as num?)?.toDouble(),
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

  /// Persistent custom device aliases synced across the entire mesh (nodeId or host -> customName).
  final deviceAliases = <String, String>{}.obs;

  /// Custom user-assigned name for this local device.
  final localCustomName = ''.obs;

  /// All active local IPv4 addresses (LAN + Tailscale/WireGuard/Overlay VPN).
  final localAddresses = <String>[].obs;

  /// Returns this device's active Tailscale / Overlay VPN IP (e.g. 100.x.y.z) if available.
  String? get localOverlayIp =>
      localAddresses.firstWhereOrNull(NetworkTransportService.isWanOrOverlayIp);

  /// Returns this device's primary LAN IP (e.g. 192.168.x.x) if available.
  String? get localLanIp =>
      localAddresses.firstWhereOrNull((ip) => !NetworkTransportService.isWanOrOverlayIp(ip));

  RawDatagramSocket? _socket;
  Timer? _beaconTimer;
  Timer? _pruneTimer;
  int _beaconTickCount = 0;

  String? _localNodeId;
  String get localNodeId {
    if (_localNodeId != null) return _localNodeId!;
    if (Get.isRegistered<HiveService>()) {
      final hive = Get.find<HiveService>();
      final savedId = hive.getSetting<String>(AppConstants.keyLocalNodeId);
      if (savedId != null && savedId.isNotEmpty) {
        _localNodeId = savedId;
        return savedId;
      }
      final generated = 'node_${Platform.operatingSystem}_${DateTime.now().millisecondsSinceEpoch % 1000000}';
      hive.setSetting(AppConstants.keyLocalNodeId, generated);
      _localNodeId = generated;
      return generated;
    }
    return _localNodeId ??= 'node_${Platform.operatingSystem}_${DateTime.now().millisecondsSinceEpoch % 1000000}';
  }

  @override
  void onInit() {
    super.onInit();
    _loadPersistentMeshRegistry();
    if (!kIsWeb) {
      _startDiscovery();
    }
  }

  void _loadPersistentMeshRegistry() {
    if (!Get.isRegistered<HiveService>()) return;
    final hive = Get.find<HiveService>();

    final savedLocalName = hive.getSetting<String>(AppConstants.keyCustomDeviceName) ?? '';
    localCustomName.value = savedLocalName;

    final rawAliases = hive.getSetting<Map>(AppConstants.keyMeshDeviceAliases);
    if (rawAliases != null) {
      rawAliases.forEach((k, v) {
        if (k is String && v is String && v.trim().isNotEmpty) {
          deviceAliases[k] = v.trim();
        }
      });
    }

    if (savedLocalName.isNotEmpty) {
      deviceAliases[localNodeId] = savedLocalName;
    }

    // Restore previously known mesh peers in 'offline' state so turned-off or crashed devices
    // remain identifiable by their custom name until they come back online or are forgotten.
    final rawKnown = hive.getSetting<List>(AppConstants.keyKnownMeshNodes);
    if (rawKnown != null) {
      for (final item in rawKnown) {
        if (item is Map) {
          try {
            final map = Map<String, dynamic>.from(item);
            final host = map['host'] as String? ?? '';
            var node = MeshNode.fromJson(map, host).copyWith(status: 'offline');
            final alias = resolveCustomName(node.id, host: node.host, fallback: node.name);
            node = node.copyWith(name: alias);
            if (node.id != localNodeId) {
              onlineNodes[node.id] = node;
            }
          } catch (_) {}
        }
      }
    }
  }

  Future<void> _saveKnownNodesToHive() async {
    if (!Get.isRegistered<HiveService>()) return;
    final hive = Get.find<HiveService>();
    final list = [
      for (final n in onlineNodes.values)
        if (n.id != localNodeId) n.toJson(),
    ];
    await hive.setSetting(AppConstants.keyKnownMeshNodes, list);
  }

  Future<void> _saveAliasesToHive() async {
    if (!Get.isRegistered<HiveService>()) return;
    final hive = Get.find<HiveService>();
    await hive.setSetting(
      AppConstants.keyMeshDeviceAliases,
      Map<String, String>.from(deviceAliases),
    );
  }

  /// Resolves the user-assigned persistent name for a node ID or host, falling back to hardware name.
  String resolveCustomName(String nodeId, {String? host, required String fallback}) {
    if (nodeId == localNodeId || nodeId == 'local') {
      if (localCustomName.value.trim().isNotEmpty) {
        return localCustomName.value.trim();
      }
    }
    final byId = deviceAliases[nodeId];
    if (byId != null && byId.trim().isNotEmpty) return byId.trim();
    if (host != null && host.isNotEmpty) {
      final byHost = deviceAliases[host];
      if (byHost != null && byHost.trim().isNotEmpty) return byHost.trim();
    }
    return fallback;
  }

  /// Renames any device (local or remote peer) and persists + broadcasts the new name across the entire mesh.
  Future<void> renameDevice({
    required String nodeId,
    String? host,
    required String newName,
  }) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) return;

    final isLocal = nodeId == 'local' || nodeId == localNodeId;
    final effectiveId = isLocal ? localNodeId : nodeId;

    deviceAliases[effectiveId] = trimmed;
    if (host != null && host.isNotEmpty) {
      deviceAliases[host] = trimmed;
    }

    if (isLocal) {
      localCustomName.value = trimmed;
      if (Get.isRegistered<HiveService>()) {
        await Get.find<HiveService>().setSetting(AppConstants.keyCustomDeviceName, trimmed);
      }
      if (Get.isRegistered<ClusterService>()) {
        Get.find<ClusterService>().deviceName = trimmed;
      }
    } else {
      final existing = onlineNodes[effectiveId];
      if (existing != null) {
        onlineNodes[effectiveId] = existing.copyWith(name: trimmed);
      }
      if (Get.isRegistered<ClusterService>()) {
        final cluster = Get.find<ClusterService>();
        for (var i = 0; i < cluster.workers.length; i++) {
          final w = cluster.workers[i];
          if (w.id == effectiveId || (host != null && w.host == host)) {
            cluster.workers[i] = ClusterWorker(
              name: trimmed,
              host: w.host,
              port: w.port,
              ramMb: w.ramMb,
              bandwidth: w.bandwidth,
              model: w.model,
              id: w.id,
              deviceType: w.deviceType,
              transportType: w.transportType,
              hardwareBackend: w.hardwareBackend,
              latencyMs: w.latencyMs,
            );
          }
        }
      }
    }

    await _saveAliasesToHive();
    await _saveKnownNodesToHive();
    onlineNodes.refresh();

    // Broadcast updated alias map immediately over UDP
    unawaited(broadcastPresence());

    // Also push direct HTTP rename notification to all online peers so they persist it immediately
    for (final peer in onlinePeerNodes) {
      unawaited(
        http
            .post(
              Uri.parse('http://${peer.host}:50054/api/mesh/rename'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'target_id': effectiveId,
                'target_host': host ?? '',
                'name': trimmed,
                'aliases': Map<String, String>.from(deviceAliases),
              }),
            )
            .timeout(const Duration(seconds: 2))
            .catchError((_) => http.Response('', 500)),
      );
    }
  }

  /// Applies a rename or alias map received from another peer on the mesh.
  Future<void> applyRemoteRename({
    String? targetId,
    String? targetHost,
    String? newName,
    Map<String, dynamic>? incomingAliases,
  }) async {
    var changed = false;
    if (incomingAliases != null) {
      incomingAliases.forEach((k, v) {
        if (v is String && v.trim().isNotEmpty && deviceAliases[k] != v.trim()) {
          deviceAliases[k] = v.trim();
          changed = true;
        }
      });
    }
    if (targetId != null && targetId.isNotEmpty && newName != null && newName.trim().isNotEmpty) {
      final trimmed = newName.trim();
      if (deviceAliases[targetId] != trimmed) {
        deviceAliases[targetId] = trimmed;
        changed = true;
      }
      if (targetHost != null && targetHost.isNotEmpty) {
        deviceAliases[targetHost] = trimmed;
      }
      if (targetId == localNodeId) {
        localCustomName.value = trimmed;
        if (Get.isRegistered<HiveService>()) {
          await Get.find<HiveService>().setSetting(AppConstants.keyCustomDeviceName, trimmed);
        }
        if (Get.isRegistered<ClusterService>()) {
          Get.find<ClusterService>().deviceName = trimmed;
        }
        changed = true;
      }
    }

    if (changed) {
      for (final entry in onlineNodes.entries.toList()) {
        final alias = resolveCustomName(entry.key, host: entry.value.host, fallback: entry.value.name);
        if (alias != entry.value.name) {
          onlineNodes[entry.key] = entry.value.copyWith(name: alias);
        }
      }
      await _saveAliasesToHive();
      await _saveKnownNodesToHive();
      onlineNodes.refresh();
    }
  }

  /// Permanently removes an offline node from the known mesh registry.
  Future<void> forgetNode(String nodeId) async {
    onlineNodes.remove(nodeId);
    await _saveKnownNodesToHive();
  }

  @override
  void onClose() {
    _beaconTimer?.cancel();
    _pruneTimer?.cancel();
    _socket?.close();
    super.onClose();
  }

  /// All known peer nodes (online first, followed by offline/crashed nodes).
  List<MeshNode> get peerNodes {
    final list = onlineNodes.values.where((n) => n.id != localNodeId).toList();
    list.sort((a, b) {
      if (a.isOffline != b.isOffline) return a.isOffline ? 1 : -1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  /// Currently online & reachable peer nodes.
  List<MeshNode> get onlinePeerNodes =>
      peerNodes.where((n) => !n.isOffline).toList();

  /// Online peer nodes on the local Home LAN / USB / Ethernet (<24ms).
  List<MeshNode> get homePeerNodes =>
      onlinePeerNodes.where((n) => !n.isAwayNode).toList();

  /// Online peer nodes connected over WAN / 5G Mobile / Overlay VPN.
  List<MeshNode> get awayPeerNodes =>
      onlinePeerNodes.where((n) => n.isAwayNode).toList();

  /// Known peer nodes that went offline or crashed.
  List<MeshNode> get offlinePeerNodes =>
      peerNodes.where((n) => n.isOffline).toList();

  /// Total pooled cluster VRAM (GB) across all live mesh devices.
  double get totalMeshVramGB {
    final dev = Get.isRegistered<DeviceInfoService>() ? Get.find<DeviceInfoService>() : null;
    final localVram = dev?.gpuVramGB.value ?? 0.0;
    final remoteVram = onlinePeerNodes.fold<double>(0.0, (sum, n) => sum + n.gpuVramGB);
    return localVram + remoteVram;
  }

  /// Total pooled available memory (GB) across all live mesh devices.
  double get totalMeshFreeRamGB {
    final dev = Get.isRegistered<DeviceInfoService>() ? Get.find<DeviceInfoService>() : null;
    final localFree = dev?.availableRamGB.value ?? 4.0;
    final remoteFree = onlinePeerNodes.fold<double>(0.0, (sum, n) => sum + n.freeRamGB);
    return localFree + remoteFree;
  }

  /// Evaluates what class of models can be run across the current mesh topology.
  String get meshModelRecommendation {
    final totalPool = totalMeshFreeRamGB;
    final count = onlinePeerNodes.length + 1;

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
      if (!kIsWeb && Platform.isAndroid) {
        // Ensure Android MulticastLock is acquired immediately on startup
        unawaited(LlamaCluster.localWifiIp());
      }
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        beaconPort,
        reuseAddress: true,
        reusePort: !Platform.isWindows,
      );
      _socket?.broadcastEnabled = true;

      _socket?.listen((event) {
        if (event == RawSocketEvent.read) {
          Datagram? dg;
          while ((dg = _socket?.receive()) != null) {
            _handlePacket(dg!);
          }
        }
      });

      // Periodic broadcast beacon (every 4 seconds)
      _beaconTimer = Timer.periodic(
        const Duration(seconds: 4),
        (_) => broadcastPresence(),
      );
      unawaited(broadcastPresence(forceUnicastSweep: true));

      // Mark inactive nodes as 'offline' (after 18s of no heartbeats) rather than
      // erasing them, and first attempt Automatic Roaming Failover across any known
      // secondary/WAN/Tailscale IPs or HTTP keep-alive if UDP was blocked over 5G.
      _pruneTimer = Timer.periodic(const Duration(seconds: 4), (_) async {
        final now = DateTime.now();
        var changed = false;
        for (final entry in onlineNodes.entries.toList()) {
          if (entry.key == localNodeId) continue;
          final node = entry.value;
          final silenceSec = now.difference(node.lastSeen).inSeconds;
          if (!node.isOffline && silenceSec >= 10) {
            final recovered = await _probeNodeFailover(node);
            if (!recovered && silenceSec > 18) {
              onlineNodes[entry.key] = node.copyWith(
                status: 'offline',
                tokensPerSec: 0.0,
                wattage: 0.0,
              );
              changed = true;
            }
          } else if (node.isOffline && node.alternateHosts.isNotEmpty && _beaconTickCount % 3 == 0) {
            // Periodically check if an offline device roamed onto its mobile/VPN address
            unawaited(_probeNodeFailover(node));
          }
        }
        if (changed) {
          onlineNodes.refresh();
          unawaited(_saveKnownNodesToHive());
        }
      });
    } catch (e) {
      print('[MeshDiscovery] Failed to bind UDP socket: $e');
    }
  }

  /// Automatic Roaming Failover & WAN HTTP Keep-Alive:
  /// Probes a node's primary host and all known `alternateHosts` (e.g. Tailscale 100.x.y.z
  /// or mobile hotspot IP) over HTTP `/api/mesh/status` when UDP heartbeats drop.
  /// If reachable on a secondary IP, promotes that IP and updates the active cluster pool.
  Future<bool> _probeNodeFailover(MeshNode node) async {
    final candidates = <String>{
      if (node.host.isNotEmpty) node.host,
      ...node.alternateHosts.where((ip) => ip.isNotEmpty),
    };
    for (final candidateIp in candidates) {
      try {
        final sw = Stopwatch()..start();
        final resp = await http
            .get(Uri.parse('http://$candidateIp:50054/api/mesh/status'))
            .timeout(const Duration(milliseconds: 1600));
        sw.stop();
        if (resp.statusCode == 200) {
          final data = jsonDecode(resp.body) as Map<String, dynamic>;
          await ingestRemoteHandshake(
            data,
            remoteIp: candidateIp,
            measuredLatencyMs: sw.elapsedMicroseconds / 1000.0,
          );
          return true;
        }
      } catch (_) {}
    }
    return false;
  }

  /// Collects all local IPv4 addresses across all interfaces, including
  /// Android's ConnectivityManager/WifiManager fallback and Tailscale/WireGuard/VPN interfaces.
  Future<List<String>> _getLocalIpv4Addresses() async {
    final ips = <String>{};
    if (!kIsWeb && Platform.isAndroid) {
      try {
        final androidIp = await LlamaCluster.localWifiIp();
        if (androidIp != null && androidIp.isNotEmpty && !androidIp.startsWith('127.')) {
          ips.add(androidIp);
        }
      } catch (_) {}
    }
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback && !addr.address.startsWith('127.') && !addr.address.startsWith('169.254.')) {
            ips.add(addr.address);
          }
        }
      }
    } catch (_) {}
    if (Get.isRegistered<ClusterService>()) {
      final wifiIp = Get.find<ClusterService>().wifiAddress.value;
      if (wifiIp != null && wifiIp.isNotEmpty && !wifiIp.startsWith('127.')) {
        ips.add(wifiIp);
      }
    }
    final list = ips.toList();
    if (list.join(',') != localAddresses.join(',')) {
      localAddresses.assignAll(list);
    }
    return list;
  }

  String get localDisplayName {
    final dev = Get.isRegistered<DeviceInfoService>() ? Get.find<DeviceInfoService>() : null;
    final defaultName = '${Platform.localHostname} (${dev?.deviceNoun ?? "Node"})';
    return resolveCustomName(localNodeId, fallback: defaultName);
  }

  Map<String, dynamic> _buildBeaconMap({bool isReply = false}) {
    final dev = Get.isRegistered<DeviceInfoService>() ? Get.find<DeviceInfoService>() : null;
    final inf = Get.isRegistered<InferenceService>() ? Get.find<InferenceService>() : null;
    final telem = Get.isRegistered<MeshTelemetryService>() ? Get.find<MeshTelemetryService>() : null;

    final gpuName = dev?.gpuName.value ?? '';
    final gpuVram = dev?.gpuVramGB.value ?? 0.0;
    final totalRam = dev?.totalRamGB.value ?? 8.0;
    final freeRam = dev?.availableRamGB.value ?? 4.0;
    final deviceType = dev?.deviceNoun ?? 'Device';
    final activeModel = inf?.loadedModelName.value ?? '';
    final isDesktop = !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

    return {
      'id': localNodeId,
      'name': localDisplayName,
      'port': 50052,
      'deviceType': deviceType,
      'gpuName': gpuName,
      'gpuVramGB': gpuVram,
      'totalRamGB': totalRam,
      'freeRamGB': freeRam,
      'transportType': isDesktop ? 'ethernet' : 'wifi',
      'hardwareBackend': dev?.recommendedBackend.displayName ?? 'Auto',
      'status': telem?.localStatus.value ?? 'ready',
      'activeModel': activeModel,
      'activeModelName': activeModel,
      'uptimeSeconds': telem?.localUptime.inSeconds ?? 0,
      'tokensGenerated': telem?.localTokensGenerated.value ?? 0,
      'tokensPerSec': telem?.localTokensPerSecond.value ?? 0.0,
      'wattage': telem?.localWattage.value ?? 15.0,
      if (localAddresses.isNotEmpty) 'allIps': List<String>.from(localAddresses),
      if (deviceAliases.isNotEmpty) 'aliases': Map<String, String>.from(deviceAliases),
      if (isReply) 'isReply': true,
    };
  }

  /// Builds a full multi-node handshake payload containing this device's beacon
  /// plus all known online peers in its sub-cluster (so connecting to 1 Home node
  /// automatically discovers all other Home nodes, and vice-versa for Away nodes!).
  Future<Map<String, dynamic>> buildFullHandshakePayload() async {
    await _getLocalIpv4Addresses();
    final map = _buildBeaconMap(isReply: true);
    map['peers'] = [
      for (final p in onlinePeerNodes) p.toJson(),
    ];
    return map;
  }

  /// Ingests a remote node's beacon or full handshake payload (over UDP or HTTP WAN),
  /// merges its multi-home `alternateHosts`, and registers any gossiped sub-cluster peers.
  Future<MeshNode?> ingestRemoteHandshake(
    Map<String, dynamic> json, {
    required String remoteIp,
    double? measuredLatencyMs,
  }) async {
    var node = MeshNode.fromJson(json, remoteIp);
    if (node.id == localNodeId) return null;

    if (json['aliases'] is Map) {
      await applyRemoteRename(
        incomingAliases: Map<String, dynamic>.from(json['aliases'] as Map),
      );
    }

    final prev = onlineNodes[node.id];
    final mergedAlts = <String>{
      ...node.alternateHosts,
      if (prev != null && prev.host.isNotEmpty) prev.host,
      if (prev != null) ...prev.alternateHosts,
      if (remoteIp.isNotEmpty) remoteIp,
    }..removeWhere((ip) => ip.isEmpty || ip == '127.0.0.1' || ip == 'localhost');

    final resolvedName = resolveCustomName(node.id, host: node.host, fallback: node.name);
    final lat = measuredLatencyMs ?? node.latencyMs ?? prev?.latencyMs;
    final isWanLink = NetworkTransportService.isWanOrOverlayIp(remoteIp) ||
        (lat != null && lat >= 24.0) ||
        node.transportType == 'wan';

    node = node.copyWith(
      name: resolvedName,
      alternateHosts: mergedAlts.toList(),
      latencyMs: lat,
      transportType: isWanLink ? 'wan' : node.transportType,
      lastSeen: DateTime.now(),
    );

    final isFirstSeen = prev == null || prev.isOffline || prev.host != node.host;
    onlineNodes[node.id] = node;

    if (isFirstSeen || prev.name != node.name) {
      unawaited(_saveKnownNodesToHive());
    }

    if (Get.isRegistered<ClusterService>()) {
      unawaited(Get.find<ClusterService>().syncDiscoveredPeer(node));
    }

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

    // Ingest gossiped sub-cluster peers if included in HTTP handshake
    if (json['peers'] is List) {
      for (final rawPeer in (json['peers'] as List)) {
        if (rawPeer is Map) {
          final peerMap = Map<String, dynamic>.from(rawPeer);
          final peerId = peerMap['id'] as String? ?? '';
          if (peerId.isEmpty || peerId == localNodeId || onlineNodes.containsKey(peerId)) {
            continue;
          }
          // Try reaching the gossiped peer's advertised IPs
          final peerHost = peerMap['host'] as String? ?? '';
          final peerAlts = peerMap['allIps'] is List
              ? (peerMap['allIps'] as List).map((e) => e.toString()).toList()
              : const <String>[];
          for (final candidate in <String>{if (peerHost.isNotEmpty) peerHost, ...peerAlts}) {
            if (localAddresses.contains(candidate)) continue;
            unawaited(_probeGossipedPeer(candidate));
          }
        }
      }
    }

    return node;
  }

  Future<void> _probeGossipedPeer(String ip) async {
    try {
      final sw = Stopwatch()..start();
      final r = await http
          .get(Uri.parse('http://$ip:50054/api/mesh/status'))
          .timeout(const Duration(milliseconds: 1500));
      sw.stop();
      if (r.statusCode == 200) {
        final data = jsonDecode(r.body) as Map<String, dynamic>;
        await ingestRemoteHandshake(
          data,
          remoteIp: ip,
          measuredLatencyMs: sw.elapsedMicroseconds / 1000.0,
        );
      }
    } catch (_) {}
  }

  /// Connects an Away / Mobile / Tailscale / Remote device (and its co-located sub-cluster)
  /// by IP address, Tailscale hostname, or URL. Returns null on success, or an error string.
  Future<String?> connectRemotePeer(String rawInput) async {
    var clean = rawInput.trim();
    if (clean.isEmpty) {
      return 'Enter the remote device\'s Tailscale IP (100.x.y.z), WAN IP, or LAN IP.';
    }
    clean = clean
        .replaceFirst(RegExp(r'^https?://', caseSensitive: false), '')
        .split('/')
        .first
        .trim();
    final host = clean.contains(':')
        ? clean.substring(0, clean.lastIndexOf(':')).trim()
        : clean;
    if (host.isEmpty) {
      return 'Invalid address "$rawInput".';
    }

    // 1. Send immediate UDP beacon to port 50053 in case UDP is open
    try {
      final resolved = await InternetAddress.lookup(host);
      if (resolved.isNotEmpty) {
        final payload = jsonEncode(_buildBeaconMap(isReply: false));
        final bytes = utf8.encode('$magicHeader$payload');
        _socket?.send(bytes, resolved.first, beaconPort);
      }
    } catch (_) {}

    // 2. Perform bidirectional HTTP handshake on port 50054 (works reliably over 5G / VPN / TCP)
    try {
      final myHandshake = await buildFullHandshakePayload();
      final sw = Stopwatch()..start();
      final resp = await http
          .post(
            Uri.parse('http://$host:50054/api/mesh/handshake'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(myHandshake),
          )
          .timeout(const Duration(seconds: 4));
      sw.stop();

      if (resp.statusCode == 200) {
        final remoteData = jsonDecode(resp.body) as Map<String, dynamic>;
        final node = await ingestRemoteHandshake(
          remoteData,
          remoteIp: host,
          measuredLatencyMs: sw.elapsedMicroseconds / 1000.0,
        );
        if (node != null && Get.isRegistered<ClusterService>()) {
          await Get.find<ClusterService>().addMeshNode(node);
        }
        return null;
      }
    } catch (_) {}

    // 3. Fallback: direct ggml-rpc worker port probe (50052) via ClusterService
    if (Get.isRegistered<ClusterService>()) {
      final err = await Get.find<ClusterService>().addManual(clean);
      if (err == null) return null;
    }

    return 'Could not reach $host on ports 50054 or 50052. Verify PrivateLM Mesh is open on that device and reachable via Tailscale/VPN or port-forwarding.';
  }

  /// Sends a presence beacon announcing this node's hardware and availability.
  Future<void> broadcastPresence({bool forceUnicastSweep = false}) async {
    if (_socket == null) return;
    _beaconTickCount++;

    // Gather local IPv4 addresses first so allIps in beacon is up to date
    final localIps = await _getLocalIpv4Addresses();
    final prefixes = <String>{};

    final payload = jsonEncode(_buildBeaconMap(isReply: false));
    final message = '$magicHeader$payload';
    final data = utf8.encode(message);

    // 1. Broadcast on general 255.255.255.255
    try {
      _socket?.send(data, InternetAddress('255.255.255.255'), beaconPort);
    } catch (_) {}

    for (final ip in localIps) {
      final parts = ip.split('.');
      if (parts.length == 4) {
        final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
        prefixes.add(prefix);
        final bcast = '$prefix.255';
        try {
          _socket?.send(data, InternetAddress(bcast), beaconPort);
        } catch (_) {}
      }
    }

    // 3. Direct unicast keep-alive to already-discovered mesh nodes, their alternate/WAN IPs, and cluster workers
    final knownHosts = <String>{
      for (final node in onlineNodes.values)
        if (node.id != localNodeId) ...[
          if (node.host.isNotEmpty) node.host,
          ...node.alternateHosts.where((ip) => ip.isNotEmpty),
        ],
      if (Get.isRegistered<ClusterService>())
        for (final w in Get.find<ClusterService>().workers)
          if (w.host.isNotEmpty) w.host,
    }..removeWhere(localIps.contains);

    for (final host in knownHosts) {
      try {
        _socket?.send(data, InternetAddress(host), beaconPort);
      } catch (_) {}
    }

    // 4. Unicast UDP /24 subnet sweep every 2nd tick (8s) or on demand.
    // Includes private LAN subnets (192.168.x.x, 10.x.x.x, 172.16-31.x.x)
    final shouldSweep = forceUnicastSweep || (_beaconTickCount % 2 == 1);
    if (shouldSweep && prefixes.isNotEmpty) {
      for (final prefix in prefixes) {
        if (!prefix.startsWith('192.168.') &&
            !prefix.startsWith('10.') &&
            !prefix.startsWith('172.')) {
          continue;
        }
        for (var hostId = 1; hostId <= 254; hostId++) {
          final targetIp = '$prefix.$hostId';
          if (localIps.contains(targetIp)) continue;
          try {
            _socket?.send(data, InternetAddress(targetIp), beaconPort);
          } catch (_) {}
        }
      }
    }
  }

  void _handlePacket(Datagram dg) {
    try {
      final text = utf8.decode(dg.data);
      if (!text.startsWith(magicHeader)) return;

      final jsonStr = text.substring(magicHeader.length);
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      final remoteIp = dg.address.address;

      final senderId = json['id'] as String? ?? '';
      if (senderId == localNodeId) return;

      final prev = onlineNodes[senderId];
      final isFirstSeen = prev == null || prev.isOffline || prev.host != remoteIp;

      unawaited(ingestRemoteHandshake(json, remoteIp: remoteIp).then((node) {
        if (node == null) return;
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
      }));

      // Immediately send a direct unicast reply back to the sender if this wasn't
      // already a reply (or if we just discovered this peer for the first time).
      if (json['isReply'] != true || isFirstSeen) {
        try {
          final replyPayload = jsonEncode(_buildBeaconMap(isReply: true));
          final replyBytes = utf8.encode('$magicHeader$replyPayload');
          _socket?.send(replyBytes, dg.address, beaconPort);
        } catch (_) {}
      }
    } catch (_) {}
  }
}
