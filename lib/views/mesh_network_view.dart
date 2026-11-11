import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;

import '../controllers/model_controller.dart';
import '../controllers/server_controller.dart';
import '../core/haptics.dart';
import '../core/ui.dart';
import '../models/hardware_acceleration.dart';
import '../models/transport_type.dart';
import '../services/adb_bridge_service.dart';
import '../services/cluster_service.dart';
import '../services/device_info_service.dart';
import '../services/inference_service.dart';
import '../services/mesh_benchmark_service.dart';
import '../services/mesh_distribution_service.dart';
import '../services/mesh_discovery_service.dart';
import '../services/mesh_telemetry_service.dart';
import '../widgets/mesh_allocation_visualizer.dart';
import '../widgets/mesh_ui_components.dart';
import '../widgets/option_info_sheet.dart';

enum MeshSubTab {
  nodes,
  modelSync,
  benchmark,
  server,
}

/// Mesh Network & Distributed Cluster View.
/// Combines real-time mesh device detection, live hardware telemetry (uptime, tokens,
/// wattage, tok/s), P2P model distribution, cluster benchmarking, and local API server controls.
class MeshNetworkView extends StatefulWidget {
  const MeshNetworkView({super.key});

  @override
  State<MeshNetworkView> createState() => _MeshNetworkViewState();
}

class _MeshNetworkViewState extends State<MeshNetworkView>
    with SingleTickerProviderStateMixin {
  final ClusterService cluster = Get.find<ClusterService>();
  final MeshDiscoveryService mesh = Get.find<MeshDiscoveryService>();
  final MeshTelemetryService telemetry = Get.find<MeshTelemetryService>();
  final MeshDistributionService distribution = Get.find<MeshDistributionService>();
  final MeshBenchmarkService benchmark = Get.find<MeshBenchmarkService>();
  final ServerController server = Get.find<ServerController>();
  final DeviceInfoService? dev =
      Get.isRegistered<DeviceInfoService>() ? Get.find<DeviceInfoService>() : null;
  final AdbBridgeService? adb =
      Get.isRegistered<AdbBridgeService>() ? Get.find<AdbBridgeService>() : null;

  MeshSubTab _currentTab = MeshSubTab.nodes;
  final Set<String> _selectedNodesForDistribution = <String>{};
  String? _selectedModelForDistribution;

  @override
  void initState() {
    super.initState();
    cluster.refreshWorkerStatus();
    cluster.refreshWifiAddress();
    if (cluster.role == ClusterRole.master) cluster.relocateWorkers();

    final loaded = Get.find<InferenceService>().loadedModelName.value;
    if (loaded.isNotEmpty) {
      _selectedModelForDistribution = loaded;
    }
  }

  IconData _deviceIcon(String deviceType) {
    final s = deviceType.toLowerCase();
    if (s.contains('pc') || s.contains('desktop') || s.contains('windows')) {
      return Icons.desktop_windows_rounded;
    }
    if (s.contains('mac') || s.contains('macbook') || s.contains('apple')) {
      return Icons.laptop_mac_rounded;
    }
    if (s.contains('tablet') || s.contains('pad')) {
      return Icons.tablet_android_rounded;
    }
    if (s.contains('linux') || s.contains('server')) {
      return Icons.terminal_rounded;
    }
    return Icons.smartphone_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);

    return Scaffold(
      backgroundColor: t.bg,
      appBar: AppBar(
        backgroundColor: t.bg,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: t.accent.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.hub_rounded, size: 20, color: t.accent),
            ),
            const SizedBox(width: 10),
            Text('Mesh Network', style: t.bodyStrong.copyWith(fontSize: 18)),
            const Spacer(),
            Obx(() {
              final count = mesh.peerNodes.length + 1;
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: t.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: t.hairline),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    StatusDot(t.green, size: 7),
                    const SizedBox(width: 6),
                    Text(
                      '$count Online',
                      style: t.caption.copyWith(fontWeight: FontWeight.w600, fontSize: 11),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
      body: Column(
        children: [
          // Sub-navigation tabs with 21st.dev micro-interactions
          _buildSubNavBar(t),
          const SizedBox(height: 4),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 240),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) {
                return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0.04, 0),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                );
              },
              child: KeyedSubtree(
                key: ValueKey(_currentTab),
                child: Obx(() {
                  switch (_currentTab) {
                    case MeshSubTab.nodes:
                      return _buildNodesSection(context);
                    case MeshSubTab.modelSync:
                      return _buildModelSyncSection(context);
                    case MeshSubTab.benchmark:
                      return _buildBenchmarkSection(context);
                    case MeshSubTab.server:
                      return _buildServerSection(context);
                  }
                }),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubNavBar(AppTokens t) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: t.hairline),
        ),
        child: Row(
          children: [
            _subTabButton(MeshSubTab.nodes, 'Nodes', Icons.devices_rounded),
            _subTabButton(MeshSubTab.modelSync, 'Sync', Icons.cloud_sync_rounded),
            _subTabButton(MeshSubTab.benchmark, 'Benchmark', Icons.speed_rounded),
            _subTabButton(MeshSubTab.server, 'Server', Icons.lan_rounded),
          ],
        ),
      ),
    );
  }

  Widget _subTabButton(MeshSubTab tab, String label, IconData icon) {
    final t = AppTokens.of(context);
    final selected = _currentTab == tab;

    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (_currentTab != tab) {
            Haptics.selectionClick();
            setState(() => _currentTab = tab);
          }
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 7),
          decoration: BoxDecoration(
            color: selected ? (t.isDark ? Colors.white.withValues(alpha: 0.12) : Colors.white) : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            boxShadow: selected && !t.isDark
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    )
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 15,
                color: selected ? t.accent : t.muted,
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: selected ? t.text : t.muted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 1. NODES & TELEMETRY SECTION ─────────────────────────────────────────

  Widget _buildNodesSection(BuildContext context) {
    final t = AppTokens.of(context);
    final peers = mesh.peerNodes;
    final totalNodes = peers.length + 1;
    final offered = distribution.meshOfferedModel.value;
    final incoming = distribution.incomingTransfer.value;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 80),
      children: [
        if (incoming != null) ...[
          _buildIncomingTransferBanner(context, incoming),
          const SizedBox(height: 12),
        ],
        if (offered != null) ...[
          _buildOfferedModelBanner(context, offered),
          const SizedBox(height: 12),
        ],

        // Sci-Fi Game HUD Mesh Memory & Model Allocation Visualizer
        MeshAllocationVisualizer(
          cluster: cluster,
          discovery: mesh,
        ),
        const SizedBox(height: 14),

        // 21st.dev Radar Scanner
        MeshRadarScanner(
          onlineCount: totalNodes,
          onScanTap: () {
            cluster.refreshWifiAddress();
            mesh.broadcastPresence(forceUnicastSweep: true);
            cluster.scanNearby();
            Haptics.lightImpact();
          },
        ),
        const SizedBox(height: 14),

        // Aggregate HUD Card
        MeshAggregateTelemetryCard(
          totalTokens: telemetry.meshTotalTokens,
          tokensPerSec: telemetry.meshTokensPerSecond,
          totalWattage: telemetry.meshTotalWattage,
          tokensPerWatt: telemetry.tokensPerWatt,
          uptime: telemetry.formattedLocalUptime,
        ),
        const SizedBox(height: 14),

        // Cluster Role & Transport Controls
        _buildClusterRoleAndControls(context),
        const SizedBox(height: 14),

        // Evaluated Capability Banner
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: t.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: t.hairline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      mesh.meshModelRecommendation,
                      style: t.bodyStrong.copyWith(fontSize: 13),
                    ),
                  ),
                  OptionInfoIcon(
                    onTap: () => showOptionHelpByKey(context, 'cluster_mesh_audit'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Cluster Memory Pool: ${mesh.totalMeshVramGB > 0 ? "${mesh.totalMeshVramGB.toStringAsFixed(1)} GB VRAM + " : ""}${mesh.totalMeshFreeRamGB.toStringAsFixed(1)} GB RAM available',
                style: t.caption.copyWith(color: t.muted),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        Row(
          children: [
            Text('Discovered Mesh Devices ($totalNodes)', style: t.label),
            const Spacer(),
            OptionInfoIcon(
              onTap: () => showOptionHelpByKey(context, 'cluster_workers'),
            ),
          ],
        ),
        const SizedBox(height: 8),

        // Local Device Node
        MeshNodeCard(
          icon: _deviceIcon(dev?.deviceNoun ?? 'PC'),
          title: '${cluster.deviceName.isEmpty ? "This Device" : cluster.deviceName} (Local Host)',
          subtitle: [
            dev?.recommendedBackend.displayName ?? 'Auto',
            if ((dev?.gpuVramGB.value ?? 0) > 0)
              '${dev!.gpuVramGB.value.toStringAsFixed(1)} GB VRAM',
            '${(dev?.availableRamGB.value ?? 4.0).toStringAsFixed(1)} GB free RAM',
          ].join(' · '),
          transportType: 'Local Bus',
          latencyMs: 0.01,
          uptime: telemetry.formattedLocalUptime,
          tokensGenerated: telemetry.localTokensGenerated.value,
          tokensPerSec: telemetry.localTokensPerSecond.value,
          wattage: telemetry.localWattage.value,
          status: telemetry.localStatus.value,
          isLocal: true,
        ),

        // Remote Mesh Nodes
        for (final peer in peers) ...[
          MeshNodeCard(
            icon: peer.icon,
            title: peer.name,
            subtitle: [
              peer.endpoint,
              peer.hardwareBackend,
              if (peer.gpuVramGB > 0) '${peer.gpuVramGB.toStringAsFixed(1)} GB VRAM',
              '${peer.freeRamGB.toStringAsFixed(1)} GB free RAM',
            ].join(' · '),
            transportType: peer.transportType,
            latencyMs: cluster.workers.firstWhereOrNull((w) => w.endpoint == peer.endpoint)?.latencyMs,
            uptime: telemetry.nodeTelemetryMap[peer.id]?.formattedUptime ?? 'Connected',
            tokensGenerated: telemetry.nodeTelemetryMap[peer.id]?.tokensGenerated ?? 0,
            tokensPerSec: telemetry.nodeTelemetryMap[peer.id]?.tokensPerSecond ?? 0.0,
            wattage: telemetry.nodeTelemetryMap[peer.id]?.wattage ?? 18.0,
            status: telemetry.nodeTelemetryMap[peer.id]?.status ?? 'ready',
            trailing: _buildPairTrailing(peer),
          ),
        ],
      ],
    );
  }

  Widget _buildOfferedModelBanner(BuildContext context, MeshModelOffer offer) {
    final t = AppTokens.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.accent.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.accent.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_download_rounded, color: t.accent, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Active Mesh Model: ${offer.modelName}',
                  style: t.bodyStrong.copyWith(fontSize: 13),
                ),
                const SizedBox(height: 2),
                Text(
                  'Hosted by ${offer.sourceNodeName} · Tap Join to sync model to this device',
                  style: t.caption,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          PillButton(
            label: 'Join & Sync',
            primary: true,
            onPressed: () async {
              showToast(
                'Joining Mesh Model',
                'Syncing ${offer.modelName} from ${offer.sourceNodeName}...',
                tone: ToastTone.info,
              );
              await distribution.syncOfferedModel(offer);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildIncomingTransferBanner(BuildContext context, PeerDistributionProgress incoming) {
    final t = AppTokens.of(context);
    final isDone = incoming.status.startsWith('completed');
    final isLoading = incoming.status == 'loading';
    final pct = (incoming.progress * 100).clamp(0, 100).round();

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: (isDone ? t.green : t.accent).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: (isDone ? t.green : t.accent).withValues(alpha: 0.45),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isDone
                    ? Icons.check_circle_rounded
                    : (isLoading ? Icons.memory_rounded : Icons.downloading_rounded),
                color: isDone ? t.green : t.accent,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isDone
                      ? 'Model Push Complete: ${incoming.modelName}'
                      : (isLoading
                          ? 'Loading Pushed Model: ${incoming.modelName}...'
                          : 'Receiving Model Push: ${incoming.modelName} ($pct%)'),
                  style: t.bodyStrong.copyWith(fontSize: 13),
                ),
              ),
              if (!isDone && incoming.speedMBps > 0)
                Text(
                  '${incoming.speedMBps.toStringAsFixed(1)} MB/s',
                  style: t.caption.copyWith(
                    color: t.accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            isDone
                ? '${incoming.peerName} · Ready & active in memory'
                : '${incoming.peerName} · Status: ${incoming.status.toUpperCase()}',
            style: t.caption,
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: isLoading ? null : incoming.progress.clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: t.surface,
              valueColor: AlwaysStoppedAnimation<Color>(isDone ? t.green : t.accent),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildClusterRoleAndControls(BuildContext context) {
    final t = AppTokens.of(context);
    final role = cluster.role;
    final strategy = cluster.schedulerStrategy.value;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.hub_rounded, size: 18, color: t.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Mesh Operating Mode (Instant Switch · No Restart)',
                      style: t.bodyStrong.copyWith(fontSize: 13.5),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      role == ClusterRole.master
                          ? 'Unified Peer-to-Peer Pool: All devices share memory automatically; interact from any device.'
                          : role == ClusterRole.worker
                              ? 'Passive Worker: Lending memory & compute to peers; tap any mode above to switch immediately.'
                              : 'Standalone Local: Running models on this device only.',
                      style: t.caption.copyWith(color: t.muted, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              OptionInfoIcon(
                onTap: () => showOptionHelpByKey(context, 'cluster_role'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          AppSegmented<ClusterRole>(
            selected: role,
            items: const [
              (ClusterRole.off, 'Local Only'),
              (ClusterRole.master, 'Unified Mesh Pool'),
              (ClusterRole.worker, 'Passive Worker'),
            ],
            onChanged: (r) => cluster.setRole(r),
          ),
          if (role == ClusterRole.worker || role == ClusterRole.master) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: t.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: t.hairline),
              ),
              child: Row(
                children: [
                  StatusDot(cluster.worker.value.running ? t.green : t.orange, size: 8),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      cluster.worker.value.running
                          ? (role == ClusterRole.master
                              ? 'Unified Mesh Active: Local RPC daemon sharing on ${cluster.wifiAddress.value ?? "0.0.0.0"}:50052 + Coordinating ${cluster.workers.length} peer(s)'
                              : 'Passive Worker RPC active on ${cluster.wifiAddress.value ?? "0.0.0.0"}:50052')
                          : 'Starting local RPC mesh daemon on port 50052...',
                      style: t.caption.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (role == ClusterRole.worker)
                    PillButton(
                      label: 'Exit Worker',
                      onPressed: () => cluster.setRole(ClusterRole.master),
                    ),
                ],
              ),
            ),
          ],
          if (role == ClusterRole.master) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text('Scheduler Strategy', style: t.caption.copyWith(fontWeight: FontWeight.w600)),
                ),
                OptionInfoIcon(
                  onTap: () => showOptionHelpByKey(context, 'cluster_scheduler'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            AppSegmented<ClusterSchedulerStrategy>(
              selected: strategy,
              items: const [
                (ClusterSchedulerStrategy.topologyLatency, 'Topology'),
                (ClusterSchedulerStrategy.throughputWeighted, 'Throughput'),
                (ClusterSchedulerStrategy.capacityBalanced, 'Capacity'),
              ],
              onChanged: (s) => cluster.setSchedulerStrategy(s),
            ),
            if (adb != null && (dev?.deviceNoun == 'PC' || dev?.deviceNoun == 'Mac')) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(Icons.usb_rounded, size: 16, color: t.accent),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'USB-C ADB Auto-Bridge (${adb!.usbDevices.length} connected)',
                      style: t.caption,
                    ),
                  ),
                  OptionInfoIcon(
                    onTap: () => showOptionHelpByKey(context, 'usb_adb_bridge'),
                  ),
                  const SizedBox(width: 6),
                  PillButton(
                    label: 'Bridge USB',
                    onPressed: () async {
                      final count = await cluster.autoBridgeUsbDevices();
                      showToast(
                        'USB-C Bridge',
                        count > 0
                            ? 'Bridged $count USB-C device(s) over low-latency tunnel.'
                            : 'No new USB-C debugging devices detected.',
                      );
                    },
                  ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildPairTrailing(MeshNode peer) {
    final isPaired = cluster.workers.any((w) => w.endpoint == peer.endpoint);
    final t = AppTokens.of(context);

    if (isPaired) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle_rounded, size: 16, color: t.green),
          const SizedBox(width: 4),
          Text(
            'Paired',
            style: t.caption.copyWith(color: t.green, fontWeight: FontWeight.bold),
          ),
          IconButton(
            icon: Icon(Icons.close_rounded, size: 16, color: t.muted),
            tooltip: 'Unpair',
            onPressed: () {
              final worker = cluster.workers.firstWhereOrNull((w) => w.endpoint == peer.endpoint);
              if (worker != null) cluster.remove(worker);
            },
          ),
        ],
      );
    }

    return PillButton(
      label: 'Pair',
      primary: true,
      onPressed: () async {
        final err = await cluster.addMeshNode(peer);
        if (err != null) {
          showToast('Pairing failed', err, tone: ToastTone.error);
        } else {
          showToast('Paired', '${peer.name} joined the active cluster.', tone: ToastTone.success);
        }
      },
    );
  }

  // ── 2. MODEL SYNC & DISTRIBUTION SECTION ─────────────────────────────────

  Widget _buildModelSyncSection(BuildContext context) {
    final t = AppTokens.of(context);
    final peers = mesh.peerNodes;
    final modelCtrl = Get.isRegistered<ModelController>() ? Get.find<ModelController>() : null;
    final downloadedFiles = modelCtrl?.downloadedFiles ?? <String>[];
    final activeTransfers = distribution.activeTransfers;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
      children: [
        // Auto-join banner
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.sync_rounded, color: t.accent, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('Auto-Join Mesh Model Sync', style: t.bodyStrong),
                  ),
                  Switch(
                    value: distribution.autoSyncOnJoin.value,
                    onChanged: (v) => distribution.setAutoSyncOnJoin(v),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'When enabled, newly connected devices on the mesh will automatically download or receive the active model without manual user intervention.',
                style: t.caption,
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // Model selector card
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Model to Distribute', style: t.bodyStrong),
              const SizedBox(height: 6),
              Text(
                'Select a local model to stream across local LAN / USB directly to mesh devices.',
                style: t.caption,
              ),
              const SizedBox(height: 12),
              if (downloadedFiles.isEmpty)
                Text(
                  'No models downloaded yet. Download a GGUF model in the Models tab first.',
                  style: t.caption.copyWith(color: t.orange),
                )
              else
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: t.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: t.hairline),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: _selectedModelForDistribution ?? downloadedFiles.first,
                      items: downloadedFiles.map((f) {
                        return DropdownMenuItem(
                          value: f,
                          child: Text(
                            f,
                            style: t.body.copyWith(fontSize: 13),
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      }).toList(),
                      onChanged: (v) {
                        setState(() => _selectedModelForDistribution = v);
                      },
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // Target Devices Checklist
        Row(
          children: [
            Text('Target Mesh Devices (${peers.length})', style: t.label),
            const Spacer(),
            TextButton(
              onPressed: () {
                setState(() {
                  if (_selectedNodesForDistribution.length == peers.length) {
                    _selectedNodesForDistribution.clear();
                  } else {
                    _selectedNodesForDistribution.addAll(peers.map((p) => p.id));
                  }
                });
              },
              child: Text(
                _selectedNodesForDistribution.length == peers.length ? 'Deselect All' : 'Select All',
                style: TextStyle(fontSize: 12, color: t.accent),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),

        if (peers.isEmpty)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: t.surface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: Text(
                'No other mesh devices online. Connect phones, tablets, or PCs to the same Wi-Fi or USB to distribute models.',
                style: t.caption,
                textAlign: TextAlign.center,
              ),
            ),
          )
        else
          AppGroup(
            children: [
              for (final peer in peers)
                CheckboxListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                  title: Text(peer.name, style: t.bodyStrong.copyWith(fontSize: 13)),
                  subtitle: Text(
                    '${peer.endpoint} · ${peer.freeRamGB.toStringAsFixed(1)} GB free · ${peer.transportType}',
                    style: t.caption.copyWith(fontSize: 11),
                  ),
                  secondary: Icon(peer.icon, color: t.text),
                  value: _selectedNodesForDistribution.contains(peer.id),
                  activeColor: t.accent,
                  onChanged: (checked) {
                    setState(() {
                      if (checked == true) {
                        _selectedNodesForDistribution.add(peer.id);
                      } else {
                        _selectedNodesForDistribution.remove(peer.id);
                      }
                    });
                  },
                ),
            ],
          ),

        const SizedBox(height: 16),

        // Distribute button
        PrimaryButton(
          label: 'Distribute Model to Marked Devices',
          icon: Icons.rocket_launch_rounded,
          onPressed: _selectedNodesForDistribution.isEmpty || _selectedModelForDistribution == null
              ? null
              : () async {
                  final filename = _selectedModelForDistribution!;
                  final targets = peers.where((p) => _selectedNodesForDistribution.contains(p.id)).toList();
                  try {
                    await distribution.distributeModelToNodes(
                      filename: filename,
                      sourceUrl: null,
                      targetNodes: targets,
                    );
                    showToast(
                      'Model Distribution Started',
                      'Streaming $filename to ${targets.length} device(s) over local mesh.',
                      tone: ToastTone.success,
                    );
                  } catch (e) {
                    showToast('Distribution Error', e.toString(), tone: ToastTone.error);
                  }
                },
        ),

        // Active Transfers Progress List
        if (activeTransfers.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text('Live Model Distribution Progress', style: t.label),
          const SizedBox(height: 8),
          for (final entry in activeTransfers.entries)
            _buildTransferProgressCard(t, entry.value),
        ],
      ],
    );
  }

  Widget _buildTransferProgressCard(AppTokens t, PeerDistributionProgress p) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: t.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.smartphone_rounded, size: 16, color: t.accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text('${p.peerName} (${p.filename})', style: t.bodyStrong.copyWith(fontSize: 12.5)),
              ),
              Text(
                '${(p.progress * 100).round()}%',
                style: t.bodyStrong.copyWith(fontSize: 12.5, color: t.accent),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: p.progress,
              backgroundColor: t.fill,
              valueColor: AlwaysStoppedAnimation(t.accent),
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text(
                p.status == 'completed'
                    ? 'Transferred successfully'
                    : p.status == 'failed'
                        ? (p.error != null ? 'Failed: ${p.error}' : 'Failed')
                        : '${p.speedMBps.toStringAsFixed(1)} MB/s · Local Mesh Stream',
                style: t.caption.copyWith(
                  fontSize: 11,
                  color: p.status == 'completed'
                      ? t.green
                      : p.status == 'failed'
                          ? t.red
                          : t.muted,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── 3. BENCHMARK SECTION ─────────────────────────────────────────────────

  Widget _buildBenchmarkSection(BuildContext context) {
    final t = AppTokens.of(context);
    final isRunning = benchmark.isRunning.value;
    final report = benchmark.lastReport.value;
    final profile = benchmark.currentProfile.value;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.speed_rounded, color: t.accent, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('Mesh Performance Benchmark', style: t.bodyStrong),
                  ),
                  OptionInfoIcon(
                    onTap: () => showOptionHelpByKey(context, 'cluster_scheduler'),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Maxes out the entire mesh cluster across selected power profiles to measure throughput (tok/s), latency, wattage, and tokens-per-watt efficiency.',
                style: t.caption,
              ),
              const SizedBox(height: 14),
              Text('Power Profile', style: t.label),
              const SizedBox(height: 8),
              AppSegmented<PowerProfile>(
                items: const [
                  (PowerProfile.eco, '🌿 Eco'),
                  (PowerProfile.balanced, '⚡ Balanced'),
                  (PowerProfile.turbo, '🚀 Turbo Max'),
                ],
                selected: profile,
                onChanged: (p) {
                  if (!isRunning) benchmark.setPowerProfile(p);
                },
              ),
              const SizedBox(height: 8),
              Text(
                profile.description,
                style: t.small.copyWith(color: t.muted),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Live Benchmark Dial / Progress HUD
        if (isRunning) ...[
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: t.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: t.accent.withValues(alpha: 0.5), width: 1.5),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                    const SizedBox(width: 10),
                    Text(benchmark.currentPhase.value, style: t.bodyStrong),
                  ],
                ),
                const SizedBox(height: 16),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: benchmark.progress.value,
                    minHeight: 8,
                    backgroundColor: t.fill,
                    valueColor: AlwaysStoppedAnimation(t.accent),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        children: [
                          Text(benchmark.liveTokPerSec.value.toStringAsFixed(1),
                              style: t.bodyStrong.copyWith(fontSize: 22, fontFamily: 'monospace')),
                          Text('Tokens / Sec', style: t.caption),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Column(
                        children: [
                          Text('${benchmark.liveWattage.value.toStringAsFixed(0)} W',
                              style: t.bodyStrong.copyWith(fontSize: 22, color: t.orange, fontFamily: 'monospace')),
                          Text('Cluster Power', style: t.caption),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],

        PrimaryButton(
          label: isRunning ? 'Benchmarking Cluster…' : 'Run Mesh Benchmark',
          icon: Icons.play_arrow_rounded,
          onPressed: isRunning ? null : () => benchmark.runBenchmark(),
        ),

        // Benchmark Report Card
        if (report != null) ...[
          const SizedBox(height: 20),
          Text('Latest Benchmark Results', style: t.label),
          const SizedBox(height: 8),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.workspace_premium_rounded, size: 20, color: t.green),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Score: ${report.generationTokensPerSec.toStringAsFixed(1)} tok/s · ${report.powerProfile.label}',
                        style: t.bodyStrong,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _metricBox(
                        context,
                        'Generation Speed',
                        '${report.generationTokensPerSec.toStringAsFixed(1)} tok/s',
                        Icons.bolt_rounded,
                        t.green,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _metricBox(
                        context,
                        'Prompt Processing',
                        '${report.promptTokensPerSec.toStringAsFixed(0)} tok/s',
                        Icons.speed_rounded,
                        t.accent,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _metricBox(
                        context,
                        'Peak Wattage',
                        '${report.peakWattage.toStringAsFixed(0)} W',
                        Icons.power_outlined,
                        t.orange,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _metricBox(
                        context,
                        'Energy Efficiency',
                        '${report.tokensPerWatt.toStringAsFixed(3)} t/J',
                        Icons.eco_rounded,
                        const Color(0xFF34C759),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text('Projected Generation Latency', style: t.label),
                const SizedBox(height: 6),
                _latencyProjectionRow(t, '250 tokens (short reply)', report.estimateSecondsForTokens(250)),
                _latencyProjectionRow(t, '500 tokens (detailed answer)', report.estimateSecondsForTokens(500)),
                _latencyProjectionRow(t, '1,000 tokens (article/code)', report.estimateSecondsForTokens(1000)),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _metricBox(BuildContext context, String label, String value, IconData icon, Color color) {
    final t = AppTokens.of(context);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: t.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
              Text(label, style: t.caption.copyWith(fontSize: 10.5)),
            ],
          ),
          const SizedBox(height: 4),
          Text(value, style: t.bodyStrong.copyWith(fontSize: 13.5, fontFamily: 'monospace')),
        ],
      ),
    );
  }

  Widget _latencyProjectionRow(AppTokens t, String label, double seconds) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(label, style: t.caption)),
          Text(
            '${seconds.toStringAsFixed(1)}s',
            style: t.bodyStrong.copyWith(fontSize: 12.5, fontFamily: 'monospace'),
          ),
        ],
      ),
    );
  }

  // ── 4. API SERVER & COMMUNICATIONS SECTION ───────────────────────────────

  Widget _buildServerSection(BuildContext context) {
    final t = AppTokens.of(context);
    final isRunning = server.isRunning.value;
    final isStarting = server.isStarting.value;
    final allowNetwork = server.allowNetwork.value;
    final hasKey = server.apiKey.value.trim().isNotEmpty;
    final error = server.lastError.value;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      children: [
        // Status Hero
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: isRunning ? t.green.withValues(alpha: 0.15) : t.fill,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      isRunning ? Icons.check_circle_rounded : Icons.power_settings_new_rounded,
                      color: isRunning ? t.green : t.muted,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isRunning ? 'API Server Running' : 'API Server Stopped',
                          style: t.bodyStrong,
                        ),
                        Text(
                          isRunning
                              ? 'Listening on ${server.localUrl.value ?? ""}'
                              : 'OpenAI-compatible HTTP endpoint (/v1/chat/completions)',
                          style: t.caption,
                        ),
                      ],
                    ),
                  ),
                  PillButton(
                    label: isStarting
                        ? 'Starting…'
                        : isRunning
                            ? 'Stop'
                            : 'Start',
                    primary: !isRunning,
                    onPressed: isStarting
                        ? null
                        : isRunning
                            ? server.stopServer
                            : server.startServer,
                  ),
                ],
              ),
            ],
          ),
        ),

        if (error != null) ...[
          const SizedBox(height: 12),
          AppNotice(error, icon: Icons.error_outline_rounded, color: t.red),
        ],

        const SectionHeader('Access & Security'),
        AppGroup(
          children: [
            AppRow(
              icon: Icons.lan_outlined,
              title: 'Allow network access',
              subtitle: allowNetwork
                  ? 'Reachable from other devices on your LAN'
                  : 'Only apps on this local device can connect',
              trailing: Switch(
                value: allowNetwork,
                onChanged: isStarting ? null : (v) => server.setAllowNetwork(v),
              ),
            ),
            AppRow(
              icon: Icons.key_outlined,
              title: 'Require API key',
              subtitle: allowNetwork
                  ? 'Always on while network access is enabled'
                  : 'Clients send Authorization: Bearer <key>',
              trailing: Switch(
                value: server.requiresApiKey,
                onChanged: allowNetwork ? null : (v) => server.setUseApiKey(v),
              ),
            ),
          ],
        ),

        const SizedBox(height: 12),
        AppField(
          label: 'API key',
          helper: server.requiresApiKey
              ? 'Required for every request.'
              : 'Optional. Checked when "Require API key" is on.',
          child: TextField(
            controller: server.apiKeyCtrl,
            onChanged: server.onApiKeyEdited,
            onSubmitted: (_) => server.saveSettings(),
            style: t.mono.copyWith(fontSize: 13.5),
            decoration: appInputDecoration(
              context,
              hint: server.requiresApiKey ? 'Required' : 'Optional',
              suffix: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Generate key',
                    onPressed: () {
                      Haptics.lightImpact();
                      server.generateApiKey();
                    },
                    icon: Icon(Icons.refresh_rounded, size: 19, color: t.muted),
                  ),
                  _CopyButton(
                    text: hasKey ? server.apiKey.value : null,
                    tooltip: 'Copy key',
                  ),
                ],
              ),
            ),
          ),
        ),

        if (isRunning) ...[
          const SectionHeader('Endpoints'),
          AppGroup(
            children: [
              _UrlRow(label: 'Base URL', url: server.localUrl.value),
              _UrlRow(
                label: 'OpenAI Base URL',
                url: server.localUrl.value == null ? null : server.openAiBaseUrl,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _HealthTest(baseUrl: server.localUrl.value),
          const SectionHeader('Usage Example (cURL)'),
          _CodeBlock(
            title: 'Chat Completion',
            lang: 'bash',
            code:
                'curl ${server.baseUrl}/v1/chat/completions \\\n  -H "Content-Type: application/json"${_authHeader()} \\\n  -d \'{"model":"${server.inference.loadedModelName.value}","messages":[{"role":"user","content":"Hello!"}]}\'',
          ),
        ],
      ],
    );
  }

  String _authHeader() {
    if (!server.requiresApiKey || server.apiKey.value.trim().isEmpty) return '';
    return ' \\\n  -H "Authorization: Bearer ${server.apiKey.value.trim()}"';
  }
}

class _UrlRow extends StatelessWidget {
  final String label;
  final String? url;
  const _UrlRow({required this.label, required this.url});

  @override
  Widget build(BuildContext context) {
    final value = url ?? 'Unavailable';
    return AppRow(
      icon: Icons.link_rounded,
      title: label,
      subtitle: value,
      trailing: _CopyButton(text: url, tooltip: 'Copy URL'),
    );
  }
}

class _CopyButton extends StatelessWidget {
  final String? text;
  final String tooltip;
  const _CopyButton({required this.text, required this.tooltip});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return IconButton(
      tooltip: tooltip,
      onPressed: text == null
          ? null
          : () {
              Clipboard.setData(ClipboardData(text: text!));
              Haptics.lightImpact();
              showToast('Copied to clipboard', text!, tone: ToastTone.info);
            },
      icon: Icon(Icons.copy_rounded, size: 17, color: t.muted),
    );
  }
}

class _HealthTest extends StatefulWidget {
  final String? baseUrl;
  const _HealthTest({required this.baseUrl});

  @override
  State<_HealthTest> createState() => _HealthTestState();
}

class _HealthTestState extends State<_HealthTest> {
  bool _busy = false;
  bool? _ok;
  String? _message;

  Future<void> _run() async {
    final baseUrl = widget.baseUrl;
    if (baseUrl == null) return;
    setState(() {
      _busy = true;
      _ok = null;
      _message = null;
    });
    try {
      final r = await http
          .get(Uri.parse('${baseUrl.replaceAll(RegExp(r'/$'), '')}/health'))
          .timeout(const Duration(seconds: 5));
      final ok = r.statusCode >= 200 && r.statusCode < 300;
      if (!mounted) return;
      setState(() {
        _ok = ok;
        _message = ok
            ? 'Server is healthy · HTTP ${r.statusCode}'
            : 'Health check returned HTTP ${r.statusCode}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _ok = false;
        _message = 'Health check failed: $e';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            PillButton(
              label: _busy ? 'Testing…' : 'Test connection',
              icon: Icons.network_check_rounded,
              onPressed: widget.baseUrl == null || _busy ? null : _run,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text('Calls GET /health', style: t.small),
            ),
          ],
        ),
        if (_message != null) ...[
          const SizedBox(height: 10),
          AppNotice(
            _message!,
            icon: _ok == true ? Icons.check_circle_outline_rounded : Icons.error_outline_rounded,
            color: _ok == true ? t.green : t.red,
          ),
        ],
      ],
    );
  }
}

class _CodeBlock extends StatelessWidget {
  final String title;
  final String lang;
  final String code;
  const _CodeBlock({required this.title, required this.lang, required this.code});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Container(
      decoration: BoxDecoration(
        color: t.isDark ? const Color(0xFF0E0E10) : const Color(0xFFF0F0F2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.hairline, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 4, 0),
            child: Row(
              children: [
                Flexible(
                  child: Text(title, style: t.label.copyWith(color: t.text)),
                ),
                const SizedBox(width: 8),
                AppTag(lang),
                const Spacer(),
                _CopyButton(text: code, tooltip: 'Copy snippet'),
              ],
            ),
          ),
          Container(height: 0.5, color: t.hairline),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: Text(code, style: t.mono.copyWith(height: 1.5)),
          ),
        ],
      ),
    );
  }
}

