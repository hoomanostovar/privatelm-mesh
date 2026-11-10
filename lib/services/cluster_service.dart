import 'dart:async';
import 'dart:io' show File, InternetAddressType, NetworkInterface, Platform;
import 'dart:math' as math;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';

import '../core/constants.dart';
import '../core/ui.dart';
import '../models/transport_type.dart';
import 'adb_bridge_service.dart';
import 'app_log_service.dart';
import 'hive_service.dart';
import 'mesh_discovery_service.dart';
import 'network_transport_service.dart';

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

  /// iOS and desktop apps stop the worker when closed unless run as an external daemon.
  static bool get workerStopsWithApp => !kIsWeb && (Platform.isIOS || Platform.isMacOS || Platform.isWindows);

  /// QR codes a worker shows: privatelm://worker?host=…&port=…
  static const _qrScheme = 'privatelm';

  /// Speed assumed for workers paired before they reported one (GB/s).
  static const _unknownSpeed = 4.0;

  /// Workers the master can use on its next GGUF load.
  final workers = <ClusterWorker>[].obs;

  /// Master mode: use [workers] when loading GGUF models.
  final enabled = false.obs;

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

  ClusterRole get role => _workerRequested.value || worker.value.running
      ? ClusterRole.worker
      : enabled.value
          ? ClusterRole.master
          : ClusterRole.off;

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
      if (Platform.isIOS) {
        DeviceInfoPlugin().iosInfo.then((info) => deviceName = info.modelName);
      } else if (Platform.isAndroid) {
        DeviceInfoPlugin().androidInfo.then((info) => deviceName = info.model);
      } else if (Platform.isWindows) {
        DeviceInfoPlugin().windowsInfo.then((info) => deviceName = info.computerName);
      } else if (Platform.isMacOS) {
        DeviceInfoPlugin().macOsInfo.then((info) => deviceName = info.computerName);
      } else if (Platform.isLinux) {
        DeviceInfoPlugin().linuxInfo.then((info) => deviceName = info.name);
      }
      refreshWorkerStatus().then((_) {
        if (worker.value.running) _watchWorker();
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
    if (next != ClusterRole.worker && role == ClusterRole.worker) {
      if (workerStopsWithApp) {
        showToast('Still sharing', 'Close PrivateLM to stop sharing this device.');
        return;
      }
      await stopWorker();
    }
    await _setEnabled(next == ClusterRole.master);
    if (next == ClusterRole.worker) await startWorker();
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
    if (text.isEmpty) return 'Enter the worker phone\'s IP address';
    final host = text.contains(':') ? text.substring(0, text.lastIndexOf(':')) : text;
    final port = text.contains(':')
        ? int.tryParse(text.substring(text.lastIndexOf(':') + 1))
        : LlamaCluster.defaultPort;
    if (host.isEmpty || port == null) return 'Use the form 192.168.1.20:50052';
    return _add(ClusterWorker(name: host, host: host, port: port));
  }

  Future<String?> addFound(ClusterWorker w) => _add(w);

  /// Adds a peer node discovered via Mesh UDP Beacon.
  Future<String?> addMeshNode(MeshNode node) async {
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
    workers.removeWhere((s) => s.endpoint == w.endpoint);
    await _save();
  }

  bool isAdded(ClusterWorker w) => workers.any((s) => s.endpoint == w.endpoint);

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

  /// LiteRT models can't be split across phones (the cluster is llama.cpp).
  /// When this phone is a master with workers, asks before loading one here
  /// alone. True to go ahead.
  Future<bool> confirmLiteRtRunsHere(String model) async {
    final context = Get.context;
    if (role != ClusterRole.master || workers.isEmpty || context == null) return true;
    final go = await showAppSheet<bool>(
      context,
      title: 'This model can\'t use your workers',
      subtitle: '${model.replaceAll(RegExp(r'\.(litertlm|task)$'), '')} is a LiteRT '
          'model, and only GGUF models can be shared across phones. It will run '
          'on this phone only. To use your workers, load a GGUF model instead.',
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PrimaryButton(
            label: 'Load on this phone only',
            icon: Icons.smartphone_rounded,
            onPressed: () => Navigator.pop(ctx, true),
          ),
          const SizedBox(height: 10),
          TonalButton.neutral(ctx, label: 'Cancel', onTap: () => Navigator.pop(ctx, false)),
        ],
      ),
    );
    return go == true;
  }

  /// "Fits on this phone" sheet. True to share with workers anyway.
  Future<bool> _askFitsHere(String model, double modelMb, int workerCount) async {
    final context = Get.context;
    if (context == null) return false;
    final share = await showAppSheet<bool>(
      context,
      title: 'This model fits on this phone',
      subtitle: '${model.replaceAll(RegExp(r'\.gguf$'), '')} needs about '
          '${_gb(modelMb)}, and this phone has room for it. Running it here '
          'is faster, because sharing sends every word over Wi-Fi. Share it '
          'to free up memory on this phone.',
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PrimaryButton(
            label: 'Load on this phone only',
            icon: Icons.smartphone_rounded,
            onPressed: () => Navigator.pop(ctx, false),
          ),
          const SizedBox(height: 10),
          TonalButton.neutral(
            ctx,
            label: 'Share with $workerCount worker${workerCount == 1 ? '' : 's'}',
            onTap: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    return share == true;
  }

  /// Reads where the model actually went after a cluster load. Workers'
  /// shares come from llama.cpp's per-device weight buffers; this phone's
  /// share is the rest of the file, because its own buffers overlap (the
  /// mapped file and the CPU's repacked copy of the same weights).
  Future<void> refreshSplit(String modelPath) async {
    final buffers = await LlamaCluster.lastLoadBuffers();
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
      ClusterShare(deviceName.isEmpty ? 'This phone' : deviceName,
          math.max(0, fileMb - remoteMb), isThisPhone: true),
      for (final e in remote.entries) ClusterShare(e.key, e.value),
    ]);
  }

  void clearSplit() => split.clear();

  static String _gb(double mb) => '${(mb / 1024).toStringAsFixed(1)} GB';
}
