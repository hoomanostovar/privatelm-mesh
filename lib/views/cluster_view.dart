import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/ui.dart';
import '../models/hardware_acceleration.dart';
import '../models/transport_type.dart';
import '../services/adb_bridge_service.dart';
import '../services/cluster_service.dart';
import '../services/device_info_service.dart';
import '../services/mesh_discovery_service.dart';
import '../widgets/option_info_sheet.dart';

/// Heterogeneous Device Cluster & Mesh Management Screen.
/// Allows live auditing of online mesh nodes, pooled cluster memory,
/// USB-C ADB auto-bridging, and topology-aware layer placement.
class ClusterView extends StatefulWidget {
  const ClusterView({super.key});

  @override
  State<ClusterView> createState() => _ClusterViewState();
}

class _ClusterViewState extends State<ClusterView> {
  final ClusterService cluster = Get.find<ClusterService>();
  final MeshDiscoveryService mesh = Get.find<MeshDiscoveryService>();
  final AdbBridgeService? adb =
      Get.isRegistered<AdbBridgeService>() ? Get.find<AdbBridgeService>() : null;
  final DeviceInfoService? dev =
      Get.isRegistered<DeviceInfoService>() ? Get.find<DeviceInfoService>() : null;

  Timer? _wifiTimer;

  @override
  void initState() {
    super.initState();
    cluster.refreshWorkerStatus();
    cluster.refreshWifiAddress();
    if (cluster.role == ClusterRole.master) cluster.relocateWorkers();
    _wifiTimer = Timer.periodic(
        const Duration(seconds: 3), (_) => cluster.refreshWifiAddress());
  }

  @override
  void dispose() {
    _wifiTimer?.cancel();
    super.dispose();
  }

  IconData _localDeviceIcon() {
    if (kIsWeb) return Icons.language_rounded;
    if (Platform.isWindows || Platform.isLinux) return Icons.desktop_windows_rounded;
    if (Platform.isMacOS) return Icons.laptop_mac_rounded;
    if (Platform.isAndroid || Platform.isIOS) return Icons.smartphone_rounded;
    return Icons.devices_rounded;
  }

  static IconData _nodeIcon(ClusterWorker w) {
    final s = '${w.name} ${w.model ?? ''}'.toLowerCase();
    if (s.contains('pc') ||
        s.contains('desktop') ||
        s.contains('windows') ||
        s.contains('win')) {
      return Icons.desktop_windows_rounded;
    }
    if (s.contains('mac') ||
        s.contains('macbook') ||
        s.contains('apple')) {
      return Icons.laptop_mac_rounded;
    }
    if (s.contains('tablet') || s.contains('pad')) {
      return Icons.tablet_android_rounded;
    }
    if (s.contains('linux') ||
        s.contains('ubuntu') ||
        s.contains('server')) {
      return Icons.terminal_rounded;
    }
    return Icons.smartphone_rounded;
  }

  Widget _transportBadge(BuildContext context, String? type, [double? latency]) {
    final t = AppTokens.of(context);
    final transport = TransportTypeExt.fromString(type);
    final Color color;
    final String label;

    switch (transport) {
      case TransportType.usb:
        color = t.green;
        label = '⚡ USB${latency != null ? " · ${latency.toStringAsFixed(1)}ms" : ""}';
        break;
      case TransportType.ethernet:
        color = t.accent;
        label = '🌐 Ethernet${latency != null ? " · ${latency.toStringAsFixed(1)}ms" : ""}';
        break;
      case TransportType.wan:
        color = const Color(0xFFA855F7);
        label = '🌍 WAN / 5G${latency != null ? " · ${latency.toStringAsFixed(0)}ms" : ""}';
        break;
      case TransportType.wifi:
      case TransportType.unknown:
        color = t.muted;
        label = '📶 Wi-Fi${latency != null ? " · ${latency.toStringAsFixed(1)}ms" : ""}';
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }

  Widget _nodeTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    String? transport,
    Widget? badge,
    Widget? trailing,
  }) {
    final t = AppTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: t.hairline),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: t.fill,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 20, color: t.text),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        style: t.bodyStrong.copyWith(fontSize: 13),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (transport != null) ...[
                      const SizedBox(width: 6),
                      _transportBadge(context, transport),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(subtitle, style: t.caption.copyWith(fontSize: 11)),
              ],
            ),
          ),
          if (badge != null) badge,
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  Widget _peerNodeTile(BuildContext context, MeshNode peer) {
    final t = AppTokens.of(context);
    final isPaired = cluster.workers.any((w) => w.endpoint == peer.endpoint);

    return _nodeTile(
      context,
      icon: peer.icon,
      title: peer.name,
      subtitle: [
        peer.endpoint,
        if (peer.gpuVramGB > 0) '${peer.gpuVramGB.toStringAsFixed(1)} GB VRAM',
        '${peer.freeRamGB.toStringAsFixed(1)} GB free',
        peer.hardwareBackend,
      ].join(' · '),
      transport: peer.transportType,
      trailing: isPaired
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_circle_rounded, size: 16, color: t.green),
                const SizedBox(width: 4),
                Text('Paired', style: t.caption.copyWith(color: t.green, fontWeight: FontWeight.w600)),
              ],
            )
          : (cluster.role == ClusterRole.master
              ? PillButton(
                  label: 'Pair',
                  primary: true,
                  onPressed: () => _report(cluster.addMeshNode(peer)),
                )
              : null),
    );
  }

  Widget _meshInventoryCard(BuildContext context) {
    final t = AppTokens.of(context);
    final peers = mesh.peerNodes;
    final totalNodes = peers.length + 1;
    final totalVram = mesh.totalMeshVramGB;
    final totalFreeRam = mesh.totalMeshFreeRamGB;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.hub_rounded, size: 20, color: t.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Mesh Device Inventory & Audit', style: t.bodyStrong),
              ),
              OptionInfoIcon(
                onTap: () => showOptionHelpByKey(context, 'cluster_mesh_audit'),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: t.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    StatusDot(t.green, size: 7),
                    const SizedBox(width: 6),
                    Text(
                      '$totalNodes Online',
                      style: t.caption.copyWith(
                        color: t.accent,
                        fontWeight: FontWeight.w600,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Capability Banner
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: t.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: t.outline.withValues(alpha: 0.5)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  mesh.meshModelRecommendation,
                  style: t.bodyStrong.copyWith(fontSize: 13),
                ),
                const SizedBox(height: 4),
                Text(
                  'Pooled Capacity: ${totalVram > 0 ? "${totalVram.toStringAsFixed(1)} GB VRAM + " : ""}${totalFreeRam.toStringAsFixed(1)} GB RAM free',
                  style: t.caption.copyWith(color: t.muted),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Text('Active Mesh Nodes', style: t.label),
          const SizedBox(height: 8),
          // Local Node
          _nodeTile(
            context,
            icon: _localDeviceIcon(),
            title: '${cluster.deviceName.isEmpty ? "This Device" : cluster.deviceName} (Local)',
            subtitle: [
              dev?.recommendedBackend.displayName ?? 'Auto',
              if ((dev?.gpuVramGB.value ?? 0) > 0)
                '${dev!.gpuVramGB.value.toStringAsFixed(1)} GB VRAM',
              '${(dev?.availableRamGB.value ?? 4.0).toStringAsFixed(1)} GB free',
            ].join(' · '),
            badge: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: t.fill,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                cluster.role == ClusterRole.master ? 'Master' : 'Node',
                style: t.small.copyWith(fontSize: 10, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          // Peer Nodes
          for (final peer in peers) ...[
            const SizedBox(height: 6),
            _peerNodeTile(context, peer),
          ],
        ],
      ),
    );
  }

  Widget _usbBridgeCard(BuildContext context) {
    final t = AppTokens.of(context);
    final adbService = adb;
    final usbDevices = adbService?.usbDevices ?? <AdbUsbDevice>[];

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.usb_rounded, size: 20, color: t.green),
              const SizedBox(width: 8),
              Expanded(
                child: Text('USB-C Direct Cable (ADB Auto-Bridge)', style: t.bodyStrong),
              ),
              OptionInfoIcon(
                onTap: () => showOptionHelpByKey(context, 'transport_usb_bridge'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Connect Android phones via USB-C cables directly to this PC. Bypasses Wi-Fi for sub-millisecond (<0.3 ms) latency and up to 10 Gbps throughput.',
            style: t.caption,
          ),
          const SizedBox(height: 12),
          if (usbDevices.isNotEmpty) ...[
            Text('Detected USB Phones (${usbDevices.length})', style: t.label),
            const SizedBox(height: 6),
            for (final d in usbDevices)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Icon(Icons.smartphone_rounded, size: 16, color: t.green),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text('${d.model} (${d.serial})', style: t.caption),
                    ),
                    _transportBadge(context, 'usb', 0.3),
                  ],
                ),
              ),
            const SizedBox(height: 8),
          ],
          PillButton(
            label: 'Bridge USB-C Phones',
            icon: Icons.cable_rounded,
            primary: true,
            onPressed: () async {
              final count = await cluster.autoBridgeUsbDevices();
              showToast(
                'USB-C Phones Bridged',
                count > 0
                    ? 'Successfully bridged $count phone(s) over low-latency USB-C.'
                    : 'No new USB phones detected. Ensure USB Debugging is ON.',
                tone: count > 0 ? ToastTone.success : ToastTone.info,
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _schedulerCard(BuildContext context) {
    final t = AppTokens.of(context);
    final strategy = cluster.schedulerStrategy.value;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.alt_route_rounded, size: 20, color: t.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Cluster Scheduling Strategy', style: t.bodyStrong),
              ),
              OptionInfoIcon(
                onTap: () => showOptionHelpByKey(context, 'cluster_scheduler'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Optimizes model weight partitioning across your hardware topology.',
            style: t.caption,
          ),
          const SizedBox(height: 12),
          AppSegmented<ClusterSchedulerStrategy>(
            items: const [
              (ClusterSchedulerStrategy.topologyLatency, 'Latency & Topology'),
              (ClusterSchedulerStrategy.throughputWeighted, 'Throughput'),
              (ClusterSchedulerStrategy.capacityBalanced, 'Balanced'),
            ],
            selected: strategy,
            onChanged: cluster.setSchedulerStrategy,
          ),
          const SizedBox(height: 10),
          Text(
            strategy == ClusterSchedulerStrategy.topologyLatency
                ? '⭐ Recommended: Prioritizes Local GPU -> USB-C (<0.5ms) -> Ethernet (<1ms). Gates Wi-Fi nodes when the model fits within wired memory.'
                : strategy == ClusterSchedulerStrategy.throughputWeighted
                    ? 'Splits layers proportionally to measured bus and network transfer speeds (GB/s).'
                    : 'Evenly distributes layers across total free VRAM and RAM.',
            style: t.small.copyWith(color: t.muted),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      appBar: appScreenBar(context, title: 'Device Cluster', showBack: true),
      body: Obx(() {
        final role = cluster.role;
        return ListView(
          padding: kPagePadding,
          children: [
            const SizedBox(height: 8),
            Row(
              children: [
                Text('Cluster Role', style: t.bodyStrong),
                const SizedBox(width: 6),
                OptionInfoIcon(
                  onTap: () => showOptionHelpByKey(context, 'cluster_role'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            AppSegmented<ClusterRole>(
              items: [
                (ClusterRole.off, 'Off'),
                if (ClusterService.canBeMaster) (ClusterRole.master, 'Master'),
                (ClusterRole.worker, 'Worker'),
              ],
              selected: role,
              onChanged: cluster.setRole,
            ),
            const SizedBox(height: 16),
            if (role != ClusterRole.off && cluster.wifiAddress.value == null) ...[
              AppNotice(
                'Turn on Wi-Fi or connect via Ethernet/USB. Devices must share a network route.',
                icon: Icons.wifi_off_rounded,
                color: t.orange,
              ),
              const SizedBox(height: 16),
            ],
            _meshInventoryCard(context),
            const SizedBox(height: 16),
            ...switch (role) {
              ClusterRole.off => _offSection(),
              ClusterRole.master => _masterSection(context),
              ClusterRole.worker => _workerSection(context),
            },
          ],
        );
      }),
    );
  }

  List<Widget> _offSection() => [
        AppNotice(
          ClusterService.canBeMaster
              ? 'Run models too big for one computer or phone by pooling memory '
                  'and compute across PCs, Macs, Linux servers, and phones on your LAN.\n\n'
                  'Master: the device you chat on. Coordinates and evaluates the model.\n'
                  'Worker: a device that lends its GPU and RAM to the master.'
              : 'Lend this device\'s GPU and RAM to a master coordinator: '
                  'choose Worker, then pair it with your coordinator device.',
          icon: Icons.hub_outlined,
        ),
      ];

  // ── Worker ─────────────────────────────────────────────────────────────

  List<Widget> _workerSection(BuildContext context) {
    final t = AppTokens.of(context);
    final s = cluster.worker.value;
    final qr = cluster.workerQrData;

    final Widget body;
    if (s.state == 'error') {
      body = _centered(context, [
        Icon(Icons.error_outline_rounded, size: 40, color: t.red),
        const SizedBox(height: 12),
        Text('Worker stopped', style: t.bodyStrong),
        const SizedBox(height: 4),
        Text(s.error ?? 'Unknown error', style: t.caption, textAlign: TextAlign.center),
        const SizedBox(height: 16),
        PillButton(label: 'Try again', primary: true, onPressed: cluster.startWorker),
      ]);
    } else if (s.peer != null) {
      body = _centered(context, [
        _PulsingDot(color: t.green),
        const SizedBox(height: 14),
        Text('Sharing with master', style: t.bodyStrong.copyWith(fontSize: 18)),
        const SizedBox(height: 4),
        Text(s.peer!, style: t.caption),
        const SizedBox(height: 20),
        Row(children: [
          Expanded(child: _Stat(label: 'Holding', value: _gb(s.heldMb))),
          Expanded(child: _Stat(label: 'Free at start', value: _gb(s.ramMb))),
          Expanded(child: _Stat(label: 'Memory speed', value: '${s.bandwidth.toStringAsFixed(1)} GB/s')),
        ]),
      ]);
    } else if (!s.running || qr == null) {
      body = _centered(context, [
        const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5)),
        const SizedBox(height: 16),
        Text(s.running ? 'Waiting for network…' : 'Measuring this device…', style: t.caption),
      ]);
    } else {
      body = _centered(context, [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          child: QrImageView(data: qr, size: 220, padding: EdgeInsets.zero),
        ),
        const SizedBox(height: 16),
        Text('Scan this from the master device', style: t.bodyStrong),
        const SizedBox(height: 6),
        Row(mainAxisSize: MainAxisSize.min, children: [
          StatusDot(t.green, size: 8),
          const SizedBox(width: 6),
          Text('Ready · ${cluster.wifiAddress.value}', style: t.caption),
        ]),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: _Stat(label: 'Free memory', value: _gb(s.ramMb))),
          Expanded(child: _Stat(label: 'Memory speed', value: '${s.bandwidth.toStringAsFixed(1)} GB/s')),
        ]),
      ]);
    }

    return [
      if (s.throttled) ...[
        AppNotice(
          'Android is slowing this worker down (slow cores only), which slows '
          'the whole cluster. Set PrivateLM\'s battery use to Unrestricted, '
          'then turn Worker off and on.',
          icon: Icons.speed_rounded,
          color: t.orange,
        ),
        const SizedBox(height: 8),
        const Align(
          alignment: Alignment.centerLeft,
          child: PillButton(
            label: 'Set Unrestricted',
            primary: true,
            onPressed: LlamaCluster.requestBatteryUnrestricted,
          ),
        ),
        const SizedBox(height: 16),
      ],
      AppCard(padding: const EdgeInsets.fromLTRB(16, 24, 16, 20), child: body),
      SectionFootnote(ClusterService.workerStopsWithApp
          ? 'Keep this device plugged in, on the same network, with PrivateLM open: '
              'iOS pauses apps in the background. Close PrivateLM to stop sharing.'
          : 'Keep this device plugged in and on the same network, with PrivateLM '
              'open while sharing. Set Mesh Cluster to Off to stop.'),
    ];
  }

  Widget _centered(BuildContext context, List<Widget> children) =>
      Column(crossAxisAlignment: CrossAxisAlignment.center, children: children);

  // ── Master ─────────────────────────────────────────────────────────────

  List<Widget> _masterSection(BuildContext context) {
    final t = AppTokens.of(context);
    final isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    return [
      if (cluster.split.length > 1) ...[
        _SplitCard(shares: cluster.split),
        const SizedBox(height: 16),
      ],
      _schedulerCard(context),
      const SizedBox(height: 16),
      if (!isMobile) ...[
        _usbBridgeCard(context),
        const SizedBox(height: 16),
      ],
      if (isMobile)
        PrimaryButton(
          label: 'Scan a worker\'s QR code',
          icon: Icons.qr_code_scanner_rounded,
          onPressed: _scanQr,
        )
      else
        PrimaryButton(
          label: cluster.isScanning.value
              ? 'Searching LAN for workers…'
              : 'Find nearby workers (LAN)',
          icon: Icons.wifi_find_rounded,
          onPressed: cluster.isScanning.value ? null : cluster.scanNearby,
        ),
      const SizedBox(height: 16),
      Row(
        children: [
          Expanded(
            child: SectionHeader('Workers (${cluster.workers.length})'),
          ),
          OptionInfoIcon(
            onTap: () => showOptionHelpByKey(context, 'cluster_workers'),
          ),
        ],
      ),
      if (cluster.workers.isEmpty)
        const AppGroup(children: [
          EmptyState(
            icon: Icons.devices_other_rounded,
            title: 'No workers yet',
            message: 'Pair an active node from the Mesh Device Inventory above, '
                'open Device Cluster on another phone and choose Worker, '
                'or connect a phone via USB-C.',
          ),
        ])
      else
        AppGroup(dividerIndent: 60, children: [
          for (final w in cluster.workers)
            AppRow(
              icon: _nodeIcon(w),
              title: w.model ?? w.name,
              subtitle: [
                w.endpoint,
                if (w.ramMb != null) '${_gb(w.ramMb!)} free',
                if (w.bandwidth != null) '${w.bandwidth!.toStringAsFixed(1)} GB/s',
                if (w.latencyMs != null) '${w.latencyMs!.toStringAsFixed(1)} ms',
              ].join(' · '),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _transportBadge(context, w.transportType, w.latencyMs),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: Icon(Icons.close_rounded, color: t.muted),
                    tooltip: 'Remove',
                    onPressed: () => cluster.remove(w),
                  ),
                ],
              ),
            ),
        ]),
      const SectionFootnote(
        'Used the next time you load a GGUF model. If the model fits on this '
        'device you can keep it here, which is faster. If it doesn\'t, the '
        'fastest devices get the biggest share and devices that aren\'t needed '
        'are left out.',
      ),
      const SectionHeader('Other ways to add'),
      Row(children: [
        if (isMobile)
          PillButton(
            label: cluster.isScanning.value ? 'Searching…' : 'Find nearby',
            icon: Icons.wifi_find_rounded,
            onPressed: cluster.isScanning.value ? null : cluster.scanNearby,
          )
        else
          PillButton(
            label: 'Scan QR code',
            icon: Icons.qr_code_scanner_rounded,
            onPressed: _scanQr,
          ),
        const SizedBox(width: 10),
        PillButton(
          label: 'Enter IP',
          icon: Icons.keyboard_rounded,
          onPressed: () => _enterIp(context),
        ),
      ]),
      if (cluster.found.isNotEmpty) ...[
        const SizedBox(height: 12),
        AppGroup(dividerIndent: 60, children: [
          for (final w in cluster.found)
            AppRow(
              icon: _nodeIcon(w),
              title: w.model ?? w.name,
              subtitle: w.endpoint,
              trailing: PillButton(
                label: 'Add',
                primary: true,
                onPressed: () => _report(cluster.addFound(w)),
              ),
            ),
        ]),
      ],
    ];
  }

  Future<void> _scanQr() async {
    final code = await Get.to<String>(() => const _QrScanPage());
    if (code != null) await _report(cluster.addFromQr(code));
  }

  Future<void> _enterIp(BuildContext context) async {
    final ctrl = TextEditingController();
    final input = await showAppSheet<String>(
      context,
      title: 'Enter worker IP',
      subtitle: 'Shown under the worker\'s QR code',
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: appInputDecoration(ctx,
                hint: '192.168.1.20:${LlamaCluster.defaultPort}'),
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
          const SizedBox(height: 16),
          PrimaryButton(label: 'Add', onPressed: () => Navigator.pop(ctx, ctrl.text)),
        ],
      ),
    );
    ctrl.dispose();
    if (input != null) await _report(cluster.addManual(input));
  }

  Future<void> _report(Future<String?> adding) async {
    final error = await adding;
    if (error != null) {
      showToast('Couldn\'t add worker', error, tone: ToastTone.error);
    } else {
      showToast('Worker added', 'Used the next time you load a GGUF model.',
          tone: ToastTone.success);
    }
  }
}

String _gb(num mb) => '${(mb / 1024).toStringAsFixed(1)} GB';

/// How the loaded model is spread across phones: a stacked bar and legend.
class _SplitCard extends StatelessWidget {
  final List<ClusterShare> shares;
  const _SplitCard({required this.shares});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final colors = [t.accent, t.green, t.orange, const Color(0xFFAF52DE), t.red];
    final total = shares.fold<double>(0, (a, s) => a + s.mb);
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Loaded model', style: t.bodyStrong),
        const SizedBox(height: 2),
        Text('Running on ${shares.length} devices · ${_gb(total)}', style: t.caption),
        const SizedBox(height: 14),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: 12,
            child: Row(children: [
              for (var i = 0; i < shares.length; i++)
                Expanded(
                  flex: (shares[i].mb / total * 1000).round().clamp(1, 1000),
                  child: Container(
                    margin: EdgeInsets.only(right: i == shares.length - 1 ? 0 : 2),
                    color: colors[i % colors.length],
                  ),
                ),
            ]),
          ),
        ),
        const SizedBox(height: 14),
        for (var i = 0; i < shares.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              StatusDot(colors[i % colors.length], size: 10),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  shares[i].isThisPhone ? '${shares[i].name} (this device)' : shares[i].name,
                  style: t.body,
                ),
              ),
              Text('${(shares[i].mb / total * 100).round()}%', style: t.bodyStrong),
              const SizedBox(width: 10),
              SizedBox(
                width: 58,
                child: Text(_gb(shares[i].mb), textAlign: TextAlign.right, style: t.caption),
              ),
            ]),
          ),
      ]),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  const _Stat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Column(children: [
      Text(value, style: t.bodyStrong),
      const SizedBox(height: 2),
      Text(label, style: t.small, textAlign: TextAlign.center),
    ]);
  }
}

/// Live indicator for an active connection.
class _PulsingDot extends StatefulWidget {
  final Color color;
  const _PulsingDot({required this.color});

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))
        ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 56,
      height: 56,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) => Stack(alignment: Alignment.center, children: [
          Container(
            width: 24 + 32 * _c.value,
            height: 24 + 32 * _c.value,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.color.withValues(alpha: 0.35 * (1 - _c.value)),
            ),
          ),
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color),
            child: const Icon(Icons.hub_rounded, size: 14, color: Colors.white),
          ),
        ]),
      ),
    );
  }
}

/// Full-screen camera that returns the first QR code it reads.
class _QrScanPage extends StatefulWidget {
  const _QrScanPage();

  @override
  State<_QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<_QrScanPage> {
  final MobileScannerController _controller =
      MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    final value = capture.barcodes
        .map((b) => b.rawValue ?? '')
        .firstWhere((v) => v.isNotEmpty, orElse: () => '');
    if (value.isEmpty) return;
    _done = true;
    Get.back(result: value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Scan worker QR code'),
      ),
      body: Stack(children: [
        MobileScanner(controller: _controller, onDetect: _onDetect),
        Center(
          child: Container(
            width: 240,
            height: 240,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white, width: 2),
              borderRadius: BorderRadius.circular(20),
            ),
          ),
        ),
        const Positioned(
          left: 24,
          right: 24,
          bottom: 48,
          child: Text(
            'Point at the QR code on the worker phone',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white, fontSize: 15),
          ),
        ),
      ]),
    );
  }
}
