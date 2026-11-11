import 'dart:async';
import 'dart:io' show File, InternetAddressType, NetworkInterface, Platform;
import 'dart:math' as math;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:llama_flutter_android/llama_flutter_android.dart';

import '../core/constants.dart';
import '../core/ui.dart';
import '../models/hardware_acceleration.dart';
import '../models/transport_type.dart';
import 'adb_bridge_service.dart';
import 'app_log_service.dart';
import 'device_info_service.dart';
import 'hive_service.dart';
import 'mesh_discovery_service.dart';
import 'network_transport_service.dart';

/// Represents one device's proportional memory capacity and model allocation in the mesh.
class MeshDeviceSlice {
  final String id;
  final String name;
  final String? host;
  final String deviceType;
  final String hardwareBackend;
  final TransportType transportType;
  final double latencyMs;
  final double capacityMb;
  final double assignedModelMb;
  final double poolShareFraction; // Device capacity / Total mesh capacity
  final double modelFraction; // Assigned model MB / Total model MB
  final double memoryUtilization; // Assigned model MB / Device capacity
  final int layerStart;
  final int layerEnd;
  final bool isLocal;
  final bool isOffline;

  const MeshDeviceSlice({
    required this.id,
    required this.name,
    this.host,
    required this.deviceType,
    required this.hardwareBackend,
    required this.transportType,
    required this.latencyMs,
    required this.capacityMb,
    required this.assignedModelMb,
    required this.poolShareFraction,
    required this.modelFraction,
    required this.memoryUtilization,
    required this.layerStart,
    required this.layerEnd,
    this.isLocal = false,
    this.isOffline = false,
  });

  int get assignedLayers => assignedModelMb > 0 ? math.max(1, layerEnd - layerStart) : 0;
}

/// What this node does in the heterogeneous mesh cluster.
enum ClusterRole {
  off,

  /// Runs the model, coordinating layers across workers and local GPU/CPU.
  master,

  /// Lends its GPU, processor, and memory to a coordinator.
  worker,
}

/// One node's part of the loaded model.
class ClusterShare {
  final String name;
  final double mb;
  final bool isThisPhone;
  final TransportType transportType;
  const ClusterShare(
    this.name,
    this.mb, {
    this.isThisPhone = false,
    this.transportType = TransportType.unknown,
  });
}

/// A node the master can place model layers on.
class ClusterNodeAllocation {
  final ClusterWorker? worker; // null: the coordinator itself
  final double capacityMb;
  final double speed; // GB/s
  final TransportType transportType;
  final double latencyMs;
  double assignedMb = 0;

  ClusterNodeAllocation({
    required this.worker,
    required this.capacityMb,
    required this.speed,
    this.transportType = TransportType.unknown,
    this.latencyMs = 1.0,
  });
}

/// Heterogeneous Mesh Cluster Service:
/// Pools memory (VRAM / RAM) and compute across PCs, Macs, Linux servers, and mobile devices
/// over USB, Ethernet, and Wi-Fi using `llama.cpp`'s `ggml-rpc`.
class ClusterService extends GetxService {
  final HiveService _hive = Get.find<HiveService>();

  static bool get isSupported => !kIsWeb;

  /// Running a model across workers: supported on Android, Windows, Linux, and macOS.
  static bool get canBeMaster => !kIsWeb;

  /// Only iOS runs an in-process worker thread that cannot be cancelled without closing the app.
  /// Windows, macOS, Linux, and Android run a stoppable worker subprocess/service.
  static bool get workerStopsWithApp => !kIsWeb && Platform.isIOS;

  /// QR codes a worker shows: privatelm://worker?host=…&port=…
  static const _qrScheme = 'privatelm';

  /// Speed assumed for workers paired before they reported one (GB/s).
  static const _unknownSpeed = 4.0;

  /// Workers the master can use on its next GGUF load.
  final workers = <ClusterWorker>[].obs;

  /// Peer IDs or hosts manually unpaired by the user so auto-pool won't re-add them automatically.
  final Set<String> _manuallyExcludedHosts = <String>{};

  /// Unified Mesh Pool enabled: pool all mesh devices & use workers when loading GGUF models.
  final enabled = false.obs;

  /// When true, this device is in dedicated passive worker-only mode.
  /// When false and [enabled] is true, this device is in Unified Peer-to-Peer Mesh mode
  /// (both contributing its own RPC worker daemon AND able to orchestrate models from its UI).
  final dedicatedWorkerOnly = false.obs;

  final found = <ClusterWorker>[].obs;
  final isScanning = false.obs;

  /// Active scheduling strategy (Topology & Latency Optimized by default).
  final schedulerStrategy = ClusterSchedulerStrategy.topologyLatency.obs;

  /// This device's worker service.
  final worker = const ClusterWorkerStatus(state: 'stopped').obs;
  final _workerRequested = false.obs;

  /// The API server is running (other devices, e.g. a PC, use the model).
  final serving = false.obs;

  /// This device's primary network IP address.
  final wifiAddress = RxnString();

  /// How the loaded model is spread across cluster nodes.
  final split = <ClusterShare>[].obs;

  String deviceName = '';
  double? _localSpeed;
  Timer? _statusTimer;

  ClusterRole get role {
    if (dedicatedWorkerOnly.value) return ClusterRole.worker;
    if (enabled.value) return ClusterRole.master;
    if (_workerRequested.value || worker.value.running) return ClusterRole.worker;
    return ClusterRole.off;
  }

  /// "Pixel 8 72% · POCO F1 28%", or null when the model isn't split.
  String? get splitSummary {
    final total = split.fold<double>(0, (a, s) => a + s.mb);
    if (split.length < 2 || total <= 0) return null;
    return split.map((s) => '${s.name} ${(s.mb / total * 100).round()}%').join(' · ');
  }

  @override
  void onInit() {
    super.onInit();
    enabled.value = _hive.getSetting<bool>(AppConstants.keyClusterEnabled) ?? false;
    final savedStrat = _hive.getSetting<String>(AppConstants.keyClusterSchedulerStrategy);
    if (savedStrat != null) {
      schedulerStrategy.value = ClusterSchedulerStrategyExt.fromString(savedStrat);
    }
    final saved = _hive.getSetting<List>(AppConstants.keyClusterWorkers) ?? const [];
    workers.assignAll(saved.whereType<Map>().map(ClusterWorker.fromMap));
    if (isSupported) {
      final savedCustomName = _hive.getSetting<String>(AppConstants.keyCustomDeviceName);
      if (savedCustomName != null && savedCustomName.trim().isNotEmpty) {
        deviceName = savedCustomName.trim();
      } else if (Platform.isIOS) {
        DeviceInfoPlugin().iosInfo.then((info) {
          if (deviceName.isEmpty) deviceName = info.modelName;
        });
      } else if (Platform.isAndroid) {
        DeviceInfoPlugin().androidInfo.then((info) {
          if (deviceName.isEmpty) deviceName = info.model;
        });
      } else if (Platform.isWindows) {
        DeviceInfoPlugin().windowsInfo.then((info) {
          if (deviceName.isEmpty) deviceName = info.computerName;
        });
      } else if (Platform.isMacOS) {
        DeviceInfoPlugin().macOsInfo.then((info) {
          if (deviceName.isEmpty) deviceName = info.computerName;
        });
      } else if (Platform.isLinux) {
        DeviceInfoPlugin().linuxInfo.then((info) {
          if (deviceName.isEmpty) deviceName = info.name;
        });
      }
      refreshWorkerStatus().then((_) {
        if (worker.value.running) {
          _watchWorker();
        } else if (enabled.value) {
          // In Unified Mesh mode, automatically start the local RPC worker listener so peers can pool our memory too.
          startWorker();
        }
      });
      // A worker runs at full speed only while PrivateLM is on screen (it
      // borrows the app's priority), so keep the screen on while sharing.
      ever<ClusterWorkerStatus>(worker, (_) => _updateKeepScreenOn());
      ever<bool>(serving, (_) => _updateKeepScreenOn());
      refreshWifiAddress();
    }
  }

  @override
  void onClose() {
    _statusTimer?.cancel();
    super.onClose();
  }

  /// Android throttles a phone whose screen is off (slow cores, low CPU
  /// share), so keep it on while this device works for others: as a worker,
  /// or serving the model over the network.
  bool? _screenKeptOn;
  void _updateKeepScreenOn() {
    final s = worker.value;
    final on = s.running || s.starting || serving.value;
    if (on == _screenKeptOn) return;
    _screenKeptOn = on;
    LlamaCluster.setKeepScreenOn(on).catchError((_) {});
  }

  Future<void> setRole(ClusterRole next) async {
    if (next == role) return;
    if (next == ClusterRole.off) {
      if (worker.value.running || _workerRequested.value) {
        if (workerStopsWithApp) {
          showToast('Still sharing', 'Close PrivateLM to stop sharing this device.');
          return;
        }
        await stopWorker();
      }
      dedicatedWorkerOnly.value = false;
      await _setEnabled(false);
    } else if (next == ClusterRole.master) {
      // Unified Mesh Pool: participate as both a peer worker AND an active model coordinator
      dedicatedWorkerOnly.value = false;
      await _setEnabled(true);
      if (!worker.value.running && !_workerRequested.value) {
        await startWorker();
      }
    } else if (next == ClusterRole.worker) {
      // Passive Dedicated Worker mode: contribute resources only
      dedicatedWorkerOnly.value = true;
      await _setEnabled(false);
      if (!worker.value.running) {
        await startWorker();
      }
    }
    await refreshWifiAddress();
  }

  // ── Worker ─────────────────────────────────────────────────────────────

  /// What the master scans to add this phone, once the worker is running.
  String? get workerQrData {
    final host = wifiAddress.value;
    final status = worker.value;
    if (host == null || !status.running) return null;
    return Uri(scheme: _qrScheme, host: 'worker', queryParameters: {
      'host': host,
      'port': '${LlamaCluster.defaultPort}',
      if (deviceName.isNotEmpty) 'name': deviceName,
      if (status.ramMb > 0) 'ram': '${status.ramMb}',
      if (status.bandwidth > 0) 'bw': status.bandwidth.toStringAsFixed(1),
      if (status.id != null) 'id': status.id!,
    }).toString();
  }

  Future<void> startWorker() async {
    if (Platform.isAndroid) {
      // Unrestricted battery keeps Android (Samsung especially) from moving
      // the worker to slow cores once it gets busy.
      final status = await LlamaCluster.workerStatus();
      if (!status.batteryUnrestricted) await LlamaCluster.requestBatteryUnrestricted();
    }
    _workerRequested.value = true;
    worker.value = const ClusterWorkerStatus(state: 'starting');
    await LlamaCluster.startWorker();
    _watchWorker();
  }

  Future<void> stopWorker() async {
    _workerRequested.value = false;
    _statusTimer?.cancel();
    await LlamaCluster.stopWorker();
    await Future.delayed(const Duration(milliseconds: 600));
    await refreshWorkerStatus();
  }

  /// Follows the worker service (its own process) while it runs: whether a
  /// master is connected and how much it holds.
  void _watchWorker() {
    _statusTimer?.cancel();
    var checks = 0;
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      await refreshWorkerStatus();
      final s = worker.value;
      // Give the service a few seconds to come up before calling it stopped.
      if (!s.running && !s.starting && ++checks > 3) {
        _workerRequested.value = false;
        _statusTimer?.cancel();
      }
    });
  }

  Future<void> refreshWorkerStatus() async {
    try {
      worker.value = await LlamaCluster.workerStatus();
    } catch (e) {
      Get.find<AppLogService>().error('Cluster worker status failed', details: e);
    }
  }

  /// Finds this device's IPv4 address on Wi-Fi or LAN
  /// (wlan* on Android/Linux, en0 on iOS/macOS, Wi-Fi or Ethernet on Windows).
  Future<void> refreshWifiAddress() async {
    try {
      if (!kIsWeb && Platform.isAndroid) {
        final androidIp = await LlamaCluster.localWifiIp();
        if (androidIp != null && androidIp.isNotEmpty) {
          wifiAddress.value = androidIp;
          return;
        }
      }
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      final preferred = interfaces.where((i) {
        final n = i.name.toLowerCase();
        return n.startsWith('wlan') ||
            n == 'en0' ||
            n.contains('wi-fi') ||
            n.contains('ethernet') ||
            n.startsWith('eth');
      });
      final selected = preferred.isNotEmpty ? preferred.first : (interfaces.isNotEmpty ? interfaces.first : null);
      wifiAddress.value = selected == null || selected.addresses.isEmpty
          ? null
          : selected.addresses.first.address;
    } catch (_) {
      wifiAddress.value = null;
    }
  }

  // ── Master: workers ────────────────────────────────────────────────────

  /// Adds the worker from a scanned QR code. Returns an error message, or
  /// null on success.
  Future<String?> addFromQr(String data) async {
    final uri = Uri.tryParse(data.trim());
    final params = uri?.queryParameters ?? const {};
    final host = params['host'];
    final port = int.tryParse(params['port'] ?? '');
    if (uri == null || uri.scheme != _qrScheme || host == null || port == null) {
      return 'That isn\'t a PrivateLM worker code';
    }
    return _add(ClusterWorker(
      name: params['name'] ?? host,
      host: host,
      port: port,
      ramMb: int.tryParse(params['ram'] ?? ''),
      bandwidth: double.tryParse(params['bw'] ?? ''),
      model: params['name'],
      id: params['id'],
    ));
  }

  /// Adds a worker by IP ("192.168.1.20" or "192.168.1.20:50052"). Returns
  /// an error message, or null on success.
  Future<String?> addManual(String input) async {
    final text = input.trim();
    if (text.isEmpty) return 'Enter the worker device\'s IP address';
    final host = text.contains(':') ? text.substring(0, text.lastIndexOf(':')) : text;
    final port = text.contains(':')
        ? int.tryParse(text.substring(text.lastIndexOf(':') + 1))
        : LlamaCluster.defaultPort;
    if (host.isEmpty || port == null) return 'Use the form 192.168.1.20:50052';
    return _add(ClusterWorker(name: host, host: host, port: port));
  }

  Future<String?> addFound(ClusterWorker w) => _add(w);

  /// Adds a peer node discovered via Mesh UDP Beacon, automatically waking its worker service if needed.
  Future<String?> addMeshNode(MeshNode node) async {
    _manuallyExcludedHosts.remove(node.host);
    // Request remote node to ensure its worker service is running
    try {
      await http
          .post(Uri.parse('http://${node.host}:50054/api/mesh/pair-worker'))
          .timeout(const Duration(seconds: 2));
      await Future.delayed(const Duration(milliseconds: 350));
    } catch (_) {}

    final worker = ClusterWorker(
      name: node.name,
      host: node.host,
      port: node.port,
      ramMb: (node.freeRamGB * 1024).round(),
      model: '${node.deviceType} ${node.gpuName.isNotEmpty ? "(${node.gpuName})" : ""}'.trim(),
      id: node.id,
      deviceType: node.deviceType,
      transportType: node.transportType,
      hardwareBackend: node.hardwareBackend,
    );
    return _add(worker);
  }

  void setSchedulerStrategy(ClusterSchedulerStrategy strategy) {
    schedulerStrategy.value = strategy;
    _hive.setSetting(AppConstants.keyClusterSchedulerStrategy, strategy.id);
  }

  /// Finds saved workers that no longer answer at their address (they moved
  /// to another Wi-Fi, a hotspot, or got a new IP) by their device ID on
  /// the network, and updates them. Returns the ones still unreachable.
  Future<List<ClusterWorker>> relocateWorkers() async {
    final missing = <ClusterWorker>[];
    for (final w in workers) {
      if (!await LlamaCluster.probe(w.endpoint)) missing.add(w);
    }
    if (missing.isEmpty) return const [];
    final seen = await LlamaCluster.discover();
    var moved = 0;
    final unreachable = <ClusterWorker>[];
    for (final w in missing) {
      final match = seen.firstWhereOrNull((s) => w.id != null && s.id == w.id);
      final i = workers.indexWhere((x) => x.endpoint == w.endpoint);
      if (match == null || match.endpoint == w.endpoint || i < 0) {
        unreachable.add(w);
        continue;
      }
      workers[i] = w.movedTo(match.host, match.port);
      moved++;
    }
    if (moved > 0) {
      await _save();
      Get.find<AppLogService>().info('Phone cluster: found $moved worker(s) at a new address');
    }
    return unreachable;
  }

  Future<String?> _add(ClusterWorker worker) async {
    if (!await LlamaCluster.probe(worker.endpoint)) {
      return 'Can\'t reach ${worker.endpoint}. Check that the device is running a worker '
          'and reachable on the network.';
    }

    // Probe latency & detect transport type
    final latency = await NetworkTransportService.instance.measureLatency(worker.host, worker.port) ?? 10.0;
    final transport = await NetworkTransportService.instance.classifyEndpoint(worker.host);

    final enriched = worker.movedTo(
      worker.host,
      worker.port,
      transportType: transport.id,
      latencyMs: latency,
    );

    workers.removeWhere((w) => w.endpoint == enriched.endpoint);
    workers.add(enriched);
    found.removeWhere((w) => w.endpoint == enriched.endpoint);
    if (role != ClusterRole.master) {
      await _setEnabled(true);
    }
    await _save();
    return null;
  }

  /// Automatically scan and bridge all USB-C connected phones via ADB.
  Future<int> autoBridgeUsbDevices() async {
    final adb = Get.isRegistered<AdbBridgeService>() ? Get.find<AdbBridgeService>() : null;
    if (adb == null) return 0;

    final devices = await adb.scanUsbDevices();
    var bridged = 0;
    for (final dev in devices) {
      final success = await adb.forwardDevicePort(dev);
      if (success) {
        final worker = adb.toClusterWorker(dev);
        await _add(worker);
        bridged++;
      }
    }
    return bridged;
  }

  Future<void> remove(ClusterWorker w) async {
    _manuallyExcludedHosts.add(w.host);
    workers.removeWhere((s) => s.endpoint == w.endpoint || s.host == w.host);
    await _save();
  }

  /// Automatically synchronizes a discovered LAN peer into the unified mesh pool
  /// when Mesh Pool mode is enabled, unless the user explicitly excluded it.
  Future<void> syncDiscoveredPeer(MeshNode node) async {
    if (!enabled.value || dedicatedWorkerOnly.value) return;
    if (_manuallyExcludedHosts.contains(node.host)) return;
    if (node.host == wifiAddress.value || node.host == '127.0.0.1' || node.host == 'localhost') return;

    final existingIdx = workers.indexWhere((w) => w.host == node.host || (w.id != null && w.id == node.id));
    final updatedWorker = ClusterWorker(
      name: node.name,
      host: node.host,
      port: node.port,
      ramMb: (node.freeRamGB * 1024).round(),
      model: '${node.deviceType} ${node.gpuName.isNotEmpty ? "(${node.gpuName})" : ""}'.trim(),
      id: node.id,
      deviceType: node.deviceType,
      transportType: node.transportType,
      hardwareBackend: node.hardwareBackend,
      latencyMs: 5.0,
    );
    if (existingIdx >= 0) {
      workers[existingIdx] = updatedWorker;
    } else {
      workers.add(updatedWorker);
      await _save();
    }
  }

  bool isAdded(ClusterWorker w) => workers.any((s) => s.endpoint == w.endpoint || s.host == w.host);

  /// Looks for workers on the Wi-Fi or LAN.
  Future<void> scanNearby() async {
    if (isScanning.value) return;
    isScanning.value = true;
    try {
      final list = await LlamaCluster.discover();
      found.assignAll(list.where((w) => !isAdded(w)));
      await autoBridgeUsbDevices();
    } finally {
      isScanning.value = false;
    }
  }

  Future<void> _setEnabled(bool value) async {
    enabled.value = value;
    await _hive.setSetting(AppConstants.keyClusterEnabled, value);
  }

  Future<void> _save() => _hive.setSetting(
      AppConstants.keyClusterWorkers, [for (final w in workers) w.toMap()]);

  // ── Master: loading & scheduling ───────────────────────────────────────

  /// Plans a GGUF load across heterogeneous nodes with transport awareness.
  Future<int> applyForNextLoad(String modelPath, {String? modelName}) async {
    split.clear();
    if (!isSupported) return 0;
    if (!enabled.value || workers.isEmpty) {
      await LlamaCluster.clear();
      return 0;
    }

    final offline = await relocateWorkers();
    final available = workers.where((w) => !offline.any((o) => o.endpoint == w.endpoint)).toList();
    if (offline.isNotEmpty) {
      final names = offline.map((w) => w.model ?? w.name).join(', ');
      showToast('Mesh Cluster', 'Not reachable, loading without: $names');
    }

    final modelMb = await File(modelPath).length() / (1024 * 1024);
    final needMb = modelMb * 1.1; // + KV cache and working buffers
    _localSpeed ??= await LlamaCluster.benchmark();

    // Coordinator node allocation
    final localFreeMb = await LlamaCluster.localFreeRamMb() * 0.75;
    final master = ClusterNodeAllocation(
      worker: null,
      capacityMb: localFreeMb,
      speed: _localSpeed!,
      transportType: TransportType.unknown,
      latencyMs: 0.0,
    );

    final nodes = <ClusterNodeAllocation>[
      master,
      for (final w in available)
        ClusterNodeAllocation(
          worker: w,
          capacityMb: (w.ramMb ?? 2000) * 0.75,
          speed: w.bandwidth ?? _unknownSpeed,
          transportType: TransportTypeExt.fromString(w.transportType),
          latencyMs: w.latencyMs ?? 15.0,
        ),
    ];

    final totalMb = nodes.fold<double>(0, (a, p) => a + p.capacityMb);
    if (needMb > totalMb) {
      throw Exception('This model (${_gb(modelMb)}) is too big for these '
          '${nodes.length} devices: together they have about ${_gb(totalMb)} '
          'free.${offline.isEmpty ? '' : ' Not reachable: ${offline.map((w) => w.model ?? w.name).join(', ')}.'} '
          'Add another worker, close background apps, or pick a smaller model.');
    }

    if (available.isEmpty) {
      await LlamaCluster.clear();
      return 0;
    }

    // Apply selected scheduler strategy
    final strategy = schedulerStrategy.value;
    switch (strategy) {
      case ClusterSchedulerStrategy.topologyLatency:
        _fillTopologyAware(nodes, needMb);
        break;
      case ClusterSchedulerStrategy.throughputWeighted:
        _splitBySpeed(nodes, needMb);
        break;
      case ClusterSchedulerStrategy.capacityBalanced:
        _fillFastestFirst(nodes, needMb);
        break;
    }

    final used = nodes.where((p) => p.worker != null && p.assignedMb > 0).toList();

    // Populate visual split presentation
    split.assignAll([
      if (master.assignedMb > 0)
        ClusterShare(
          'This Device (Local)',
          master.assignedMb,
          isThisPhone: true,
          transportType: TransportType.unknown,
        ),
      for (final u in used)
        ClusterShare(
          u.worker!.name,
          u.assignedMb,
          transportType: u.transportType,
        ),
    ]);

    if (used.isEmpty) {
      await LlamaCluster.clear();
      return 0;
    }

    try {
      await LlamaCluster.setCluster(
        [for (final p in used) p.worker!],
        weights: [for (final p in used) p.assignedMb],
        localWeight: master.assignedMb,
      );
    } on PlatformException catch (e) {
      throw Exception(
          '${e.message ?? 'A worker is unreachable'}. Check connection or '
          'turn off Mesh Cluster in settings.');
    }
    return used.length;
  }

  /// Topology & Latency-Aware Scheduler:
  /// Packs layers into contiguous blocks along interconnect priority tiers:
  /// Local (Tier 0) -> USB (Tier 1) -> Ethernet (Tier 2) -> Wi-Fi (Tier 3).
  /// Excludes Wi-Fi nodes completely when model fits into low-latency tiers.
  static void _fillTopologyAware(List<ClusterNodeAllocation> nodes, double needMb) {
    // Sort ascending by priority tier (Tier 0/1/2 first), then descending by speed
    final sorted = [...nodes]..sort((a, b) {
        final tierA = a.worker == null ? 0 : a.transportType.priorityTier;
        final tierB = b.worker == null ? 0 : b.transportType.priorityTier;
        if (tierA != tierB) return tierA.compareTo(tierB);
        return b.speed.compareTo(a.speed);
      });

    // Reset assigned MB
    for (final n in sorted) {
      n.assignedMb = 0;
    }

    var left = needMb;
    for (final node in sorted) {
      if (left <= 0.0) break;
      final alloc = math.min(node.capacityMb, left);
      node.assignedMb = alloc;
      left -= alloc;
    }
  }

  /// Fastest first, each up to its free memory.
  static void _fillFastestFirst(List<ClusterNodeAllocation> nodes, double needMb) {
    final bySpeed = [...nodes]..sort((a, b) => b.speed.compareTo(a.speed));
    var left = needMb;
    for (final p in bySpeed) {
      p.assignedMb = math.min(p.capacityMb, left);
      left -= p.assignedMb;
    }
  }

  /// Shares in proportion to speed, capped at each node's free memory.
  static void _splitBySpeed(List<ClusterNodeAllocation> nodes, double needMb) {
    var open = [...nodes];
    var left = needMb;
    while (open.isNotEmpty && left > 0.5) {
      final speedSum = open.fold<double>(0, (a, p) => a + p.speed);
      if (speedSum <= 0) break;
      final capped = [
        for (final p in open)
          if (p.assignedMb + left * p.speed / speedSum >= p.capacityMb) p,
      ];
      if (capped.isEmpty) {
        for (final p in open) {
          p.assignedMb += left * p.speed / speedSum;
        }
        left = 0;
      } else {
        for (final p in capped) {
          left -= p.capacityMb - p.assignedMb;
          p.assignedMb = p.capacityMb;
        }
        open = open.where((p) => !capped.contains(p)).toList();
      }
    }
  }

  /// LiteRT models can't be split across devices (the cluster is llama.cpp).
  /// When this device is a master with workers, asks before loading one here
  /// alone. True to go ahead.
  Future<bool> confirmLiteRtRunsHere(String model) async {
    final context = Get.context;
    if (role != ClusterRole.master || workers.isEmpty || context == null) return true;
    final go = await showAppSheet<bool>(
      context,
      title: 'This model can\'t use your workers',
      subtitle: '${model.replaceAll(RegExp(r'\.(litertlm|task)$'), '')} is a LiteRT '
          'model, and only GGUF models can be shared across mesh devices. It will run '
          'on this device only. To use your workers, load a GGUF model instead.',
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PrimaryButton(
            label: 'Load on this device only',
            icon: Icons.devices_rounded,
            onPressed: () => Navigator.pop(ctx, true),
          ),
          const SizedBox(height: 10),
          TonalButton.neutral(ctx, label: 'Cancel', onTap: () => Navigator.pop(ctx, false)),
        ],
      ),
    );
    return go == true;
  }

  /// Reads where the model actually went after a cluster load. Workers'
  /// shares come from llama.cpp's per-device weight buffers; this device's
  /// share is the rest of the file, because its own buffers overlap (the
  /// mapped file and the CPU's repacked copy of the same weights).
  Future<void> refreshSplit(String modelPath) async {
    final buffers = await LlamaCluster.lastLoadBuffers();
    if (buffers.isEmpty && split.isNotEmpty) {
      // On Desktop, llama-server runs in a separate process and applyForNextLoad
      // already populated the exact split shares.
      return;
    }
    final remote = <String, double>{};
    for (final b in buffers) {
      final open = b.name.indexOf('[');
      if (open < 0) continue;
      final endpoint = b.name.substring(open + 1, b.name.lastIndexOf(']'));
      final name = workers.firstWhereOrNull((w) => w.endpoint == endpoint)?.model ?? endpoint;
      remote[name] = (remote[name] ?? 0) + b.mb;
    }
    final fileMb = await File(modelPath).length() / (1024 * 1024);
    final remoteMb = remote.values.fold<double>(0, (a, b) => a + b);
    split.assignAll([
      ClusterShare(deviceName.isEmpty ? 'This Device' : deviceName,
          math.max(0, fileMb - remoteMb), isThisPhone: true),
      for (final e in remote.entries) ClusterShare(e.key, e.value),
    ]);
  }

  /// Computes a proportional memory & model layer allocation across all active mesh devices
  /// (local coordinator + paired/discovered mesh peers) for a given model size in MB.
  /// Used by the Sci-Fi Mesh Allocation Visualizer to animate how any selected model
  /// fits into each device's memory pool.
  List<MeshDeviceSlice> computeMeshAllocation({
    required double modelSizeMb,
    int totalLayers = 32,
    double? localCapacityOverrideMb,
  }) {
    final devService = Get.isRegistered<DeviceInfoService>() ? Get.find<DeviceInfoService>() : null;
    final discovery = Get.isRegistered<MeshDiscoveryService>() ? Get.find<MeshDiscoveryService>() : null;

    final localFreeGb = devService?.availableRamGB.value ?? 8.0;
    final localCapMb = localCapacityOverrideMb ?? math.max(1024.0, localFreeGb * 1024 * 0.78);
    final localHw = devService != null && devService.gpuName.value.isNotEmpty
        ? '${devService.recommendedBackend.displayName} · ${devService.gpuName.value}'
        : (devService?.recommendedBackend.displayName ?? 'Local GPU/CPU');
    final localType = !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux) ? 'PC' : 'Phone';

    // Gather unique ONLINE peer nodes from paired workers + discovered active LAN nodes
    final onlineHosts = discovery != null
        ? {for (final m in discovery.onlinePeerNodes) m.host}
        : <String>{};
    final offlineByHost = discovery != null
        ? {for (final m in discovery.offlinePeerNodes) m.host: m}
        : <String, MeshNode>{};

    final peerWorkers = <ClusterWorker>[
      for (final w in workers)
        if (!offlineByHost.containsKey(w.host) || onlineHosts.contains(w.host)) w,
    ];
    if (discovery != null) {
      for (final m in discovery.onlinePeerNodes) {
        if (m.host == wifiAddress.value || m.host == '127.0.0.1') continue;
        if (_manuallyExcludedHosts.contains(m.host)) continue;
        final already = peerWorkers.any((w) => w.host == m.host || (w.id != null && w.id == m.id));
        if (!already) {
          peerWorkers.add(ClusterWorker(
            name: m.name,
            host: m.host,
            port: m.port,
            ramMb: (m.freeRamGB * 1024).round(),
            model: '${m.deviceType} ${m.gpuName.isNotEmpty ? "(${m.gpuName})" : ""}'.trim(),
            id: m.id,
            deviceType: m.deviceType,
            transportType: m.transportType,
            hardwareBackend: m.hardwareBackend,
            latencyMs: 6.0,
          ));
        }
      }
    }

    final masterAlloc = ClusterNodeAllocation(
      worker: null,
      capacityMb: localCapMb,
      speed: _localSpeed ?? 18.0,
      transportType: TransportType.unknown,
      latencyMs: 0.0,
    );

    final allocations = <ClusterNodeAllocation>[
      masterAlloc,
      if (enabled.value || peerWorkers.isNotEmpty)
        for (final w in peerWorkers)
          ClusterNodeAllocation(
            worker: w,
            capacityMb: math.max(512.0, (w.ramMb ?? 4096) * 0.78),
            speed: w.bandwidth ?? _unknownSpeed,
            transportType: TransportTypeExt.fromString(w.transportType),
            latencyMs: w.latencyMs ?? 8.0,
          ),
    ];

    final needMb = modelSizeMb * 1.1; // Include ~10% KV cache & compute buffer overhead
    final strategy = schedulerStrategy.value;
    switch (strategy) {
      case ClusterSchedulerStrategy.topologyLatency:
        _fillTopologyAware(allocations, needMb);
        break;
      case ClusterSchedulerStrategy.throughputWeighted:
        _splitBySpeed(allocations, needMb);
        break;
      case ClusterSchedulerStrategy.capacityBalanced:
        _fillFastestFirst(allocations, needMb);
        break;
    }

    final totalPoolMb = allocations.fold<double>(0.0, (sum, n) => sum + n.capacityMb);
    final totalAssignedMb = allocations.fold<double>(0.0, (sum, n) => sum + n.assignedMb);

    final slices = <MeshDeviceSlice>[];
    var currentLayer = 0;

    for (var i = 0; i < allocations.length; i++) {
      final node = allocations[i];
      final w = node.worker;
      final isLocal = w == null;
      final shareOfPool = totalPoolMb > 0 ? (node.capacityMb / totalPoolMb).clamp(0.05, 1.0) : 1.0;
      final shareOfModel = needMb > 0
          ? (node.assignedMb / needMb).clamp(0.0, 1.0)
          : (totalAssignedMb > 0 ? (node.assignedMb / totalAssignedMb).clamp(0.0, 1.0) : 0.0);
      final util = node.capacityMb > 0 ? (node.assignedMb / node.capacityMb).clamp(0.0, 1.0) : 0.0;

      int layerCount = 0;
      if (node.assignedMb > 0 && totalAssignedMb > 0) {
        layerCount = math.max(1, ((node.assignedMb / totalAssignedMb) * totalLayers).round());
      }
      final startLayer = currentLayer;
      final endLayer = node.assignedMb > 0 ? math.min(totalLayers, startLayer + layerCount) : startLayer;
      currentLayer = endLayer;

      final rawName = isLocal
          ? (deviceName.isNotEmpty ? deviceName : 'This Device')
          : w.name;
      final resolvedName = discovery != null
          ? discovery.resolveCustomName(
              isLocal ? discovery.localNodeId : (w.id ?? w.endpoint),
              host: isLocal ? wifiAddress.value : w.host,
              fallback: rawName,
            )
          : rawName;

      slices.add(MeshDeviceSlice(
        id: isLocal ? (discovery?.localNodeId ?? 'local') : (w.id ?? w.endpoint),
        name: resolvedName,
        host: isLocal ? wifiAddress.value : w.host,
        deviceType: isLocal ? localType : (w.deviceType ?? 'Phone'),
        hardwareBackend: isLocal ? localHw : (w.hardwareBackend ?? 'Auto'),
        transportType: isLocal ? TransportType.unknown : node.transportType,
        latencyMs: node.latencyMs,
        capacityMb: node.capacityMb,
        assignedModelMb: node.assignedMb,
        poolShareFraction: shareOfPool,
        modelFraction: shareOfModel,
        memoryUtilization: util,
        layerStart: startLayer,
        layerEnd: endLayer,
        isLocal: isLocal,
        isOffline: false,
      ));
    }

    // Append known offline/crashed mesh nodes so user can immediately see which named device went down
    if (discovery != null) {
      for (final offNode in discovery.offlinePeerNodes) {
        if (slices.any((s) => s.id == offNode.id || (s.host != null && s.host == offNode.host))) {
          continue;
        }
        final offCapMb = math.max(1024.0, offNode.freeRamGB * 1024 * 0.78);
        slices.add(MeshDeviceSlice(
          id: offNode.id,
          name: discovery.resolveCustomName(offNode.id, host: offNode.host, fallback: offNode.name),
          host: offNode.host,
          deviceType: offNode.deviceType,
          hardwareBackend: offNode.hardwareBackend,
          transportType: offNode.transport,
          latencyMs: 0.0,
          capacityMb: offCapMb,
          assignedModelMb: 0.0,
          poolShareFraction: totalPoolMb > 0 ? (offCapMb / totalPoolMb).clamp(0.08, 0.5) : 0.2,
          modelFraction: 0.0,
          memoryUtilization: 0.0,
          layerStart: 0,
          layerEnd: 0,
          isLocal: false,
          isOffline: true,
        ));
      }
    }

    return slices;
  }

  void clearSplit() => split.clear();

  static String _gb(double mb) => '${(mb / 1024).toStringAsFixed(1)} GB';
}
