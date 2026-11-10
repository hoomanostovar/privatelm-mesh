import 'package:flutter/material.dart';
import '../core/ui.dart';

/// Model describing two-tier explanation metadata.
class OptionHelpData {
  final String title;
  final String quickSummary;
  final String? recommended;
  final String powerUserDeepDive;
  final String? mathCalculation;
  final String? cliFlag;
  final String? configFile;

  const OptionHelpData({
    required this.title,
    required this.quickSummary,
    this.recommended,
    required this.powerUserDeepDive,
    this.mathCalculation,
    this.cliFlag,
    this.configFile,
  });
}

/// Central registry of option help documentation.
final Map<String, OptionHelpData> optionHelpRegistry = {
  'cluster_role': const OptionHelpData(
    title: 'Cluster Role (Master vs Worker vs Off)',
    quickSummary:
        'Select Master to chat and coordinate the AI model across connected devices. Select Worker to lend this device\'s GPU, memory, and processor to another coordinator. Select Off to disable clustering.',
    recommended:
        'Choose Master on the primary device you are using to chat. Choose Worker on auxiliary phones, tablets, or computers.',
    powerUserDeepDive:
        'Master runs the coordinator inference loop (llama-server / llama.cpp pipeline coordinator). Workers run ggml-rpc-server listening on TCP port 50052. The coordinator maps model layers across remote RPC backends via zero-copy buffer descriptors.',
    mathCalculation: r'T_{e2e} = \sum_{l=1}^{L} T_{compute}(l) + \sum_{h=1}^{H} T_{comm}(h)',
    cliFlag: '--rpc 192.168.1.50:50052,192.168.1.51:50052',
    configFile: 'HiveBox(\'settings\') -> keyClusterRole',
  ),
  'cluster_mesh_audit': const OptionHelpData(
    title: 'Mesh Device Inventory & Capability Audit',
    quickSummary:
        'Discovers all devices on your local network (PCs, Macs, iPhones, Android phones, tablets) running PrivateLM Mesh. Aggregates available GPU VRAM and system RAM to show what size AI model you can run together.',
    recommended:
        'Keep PrivateLM Mesh open on all devices connected to the same Wi-Fi, Ethernet switch, or USB-C hub.',
    powerUserDeepDive:
        'All nodes emit UDP broadcast heartbeats on port 50053 every 4 seconds containing device telemetry: GPU architecture, dedicated VRAM, available RAM, SIMD extensions, and network endpoints. The cluster aggregator pools memory M_pool = sum(VRAM_i + RAM_free_i) and verifies whether model parameter size S_model * 1.12 <= M_pool.',
    mathCalculation: r'M_{pool} = \sum_{i=1}^{N} (VRAM_i + RAM_{free, i}) \ge S_{model} \times 1.12',
    cliFlag: 'UDP Port 50053 (Magic Header: PLMESH_V1:)',
    configFile: 'MeshDiscoveryService -> onlineNodes',
  ),
  'cluster_scheduler': const OptionHelpData(
    title: 'Cluster Scheduling Strategy (Interconnect Latency Optimization)',
    quickSummary:
        'Controls how model layers are distributed across your devices. The Topology & Latency strategy assigns layers to fast local GPUs, USB cables, and Ethernet first, keeping slow Wi-Fi out of the critical path.',
    recommended:
        'Topology & Latency Optimized (Recommended) for mixed USB/Ethernet/Wi-Fi environments.',
    powerUserDeepDive:
        'Pipeline parallelism across heterogeneous networks is constrained by interconnect Round Trip Time (RTT). Passing activations across high-latency Wi-Fi (15-30 ms RTT) creates pipeline bubbles that degrade tokens/sec. The Topology scheduler enforces: Local (<0.01ms) -> USB-C ADB (<0.3ms) -> Ethernet (<1ms) -> Wi-Fi (>15ms). Wi-Fi nodes are gated whenever total model size fits in local and wired memory tiers.',
    mathCalculation: r'T_{comm} = \frac{2 \times d_{model} \times \text{sizeof(fp16)}}{\text{Bandwidth}} + \text{RTT}',
    cliFlag: 'ClusterSchedulerStrategy.topologyLatency',
    configFile: 'HiveBox(\'settings\') -> keyClusterSchedulerStrategy',
  ),
  'transport_usb_bridge': const OptionHelpData(
    title: 'USB-C Direct Cable (ADB Auto-Bridge)',
    quickSummary:
        'Connect Android phones directly to your PC or USB-C hub. The app automatically creates sub-millisecond local network bridges over the physical USB cable with zero Wi-Fi drops.',
    recommended:
        'Enable USB debugging on your Android phone and connect with a USB 3.0 / 3.2 Type-C cable.',
    powerUserDeepDive:
        'Utilizes Android Debug Bridge (adb forward tcp:50052 tcp:50052) socket multiplexing over the physical USB hardware layer. Eliminates 802.11 CSMA/CA RF channel contention and packet jitter, achieving RTT < 0.3 ms and up to 10 Gbps (USB 3.2 Gen 2) throughput compared to 50-300 Mbps over congested 2.4/5GHz Wi-Fi.',
    mathCalculation: r'Latency_{USB} \le 0.3 \text{ ms vs } Latency_{WiFi} \approx 15\text{--}35 \text{ ms}',
    cliFlag: 'adb forward tcp:50052 tcp:50052',
    configFile: 'HiveBox(\'settings\') -> keyAdbAutoBridge',
  ),
  'cluster_workers': const OptionHelpData(
    title: 'Cluster Workers & Layer Partitioning',
    quickSummary:
        'Shows all auxiliary devices currently recruited to run parts of the loaded AI model. Each worker displays its memory contribution, connection speed, and transport type.',
    recommended:
        'Ensure worker devices are plugged into wall power to prevent mobile OS battery throttling.',
    powerUserDeepDive:
        'Worker nodes host ggml-rpc-server instances. When loading a model, the master provisions remote tensor buffers across workers using GGML RPC. Interconnect latency and memory bandwidth determine tensor chunk boundaries and layer count assignments.',
    mathCalculation: r'Layer_{count}(i) \propto \frac{\text{Bandwidth}_i}{1 + \lambda \cdot \text{Latency}_i}',
    cliFlag: 'ggml-rpc-server -p 50052 -m 127.0.0.1',
    configFile: 'HiveBox(\'settings\') -> keyClusterWorkers',
  ),
};

/// Helper to trigger help by registry key.
Future<void> showOptionHelpByKey(BuildContext context, String key) {
  final item = optionHelpRegistry[key];
  if (item == null) return Future.value();
  return showOptionHelpSheet(
    context,
    title: item.title,
    quickSummary: item.quickSummary,
    recommended: item.recommended,
    powerUserDeepDive: item.powerUserDeepDive,
    mathCalculation: item.mathCalculation,
    cliFlag: item.cliFlag,
    configFile: item.configFile,
  );
}

/// Modal bottom sheet providing two-tier explanation:
/// 1. Simple explanation for beginners.
/// 2. In-depth technical breakdown, math formulas, config references, and CLI flags for power users.
Future<void> showOptionHelpSheet(
  BuildContext context, {
  required String title,
  required String quickSummary,
  String? recommended,
  required String powerUserDeepDive,
  String? mathCalculation,
  String? cliFlag,
  String? configFile,
}) {
  final t = AppTokens.of(context);

  return showAppSheet(
    context,
    title: title,
    scrollable: true,
    builder: (ctx) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 1. Everyday User Guide ──
            Text('Quick Guide', style: t.bodyStrong.copyWith(color: t.accent)),
            const SizedBox(height: 6),
            Text(
              quickSummary,
              style: t.body.copyWith(height: 1.45),
            ),
            if (recommended != null && recommended.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: t.accent.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: t.accent.withValues(alpha: 0.2)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.lightbulb_outline_rounded, color: t.accent, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        recommended,
                        style: t.small.copyWith(
                          color: t.text,
                          fontWeight: FontWeight.w500,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 20),
            Divider(color: t.hairline, height: 1),
            const SizedBox(height: 16),

            // ── 2. Power User & Deep Dive ──
            Row(
              children: [
                Icon(Icons.terminal_rounded, size: 18, color: t.orange),
                const SizedBox(width: 6),
                Text(
                  'Power User & Architecture Deep Dive',
                  style: t.bodyStrong.copyWith(color: t.orange),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              powerUserDeepDive,
              style: t.caption.copyWith(color: t.text, height: 1.45),
            ),

            if (mathCalculation != null && mathCalculation.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Formula & Calculation', style: t.label),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: t.fill,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: t.outline),
                ),
                child: Text(
                  mathCalculation,
                  style: t.mono.copyWith(fontSize: 12, height: 1.4),
                ),
              ),
            ],

            if (cliFlag != null && cliFlag.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('llama.cpp CLI Flag', style: t.label),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: t.fill,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(cliFlag, style: t.mono.copyWith(fontSize: 12)),
              ),
            ],

            if (configFile != null && configFile.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Config Reference', style: t.label),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: t.fill,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(configFile, style: t.mono.copyWith(fontSize: 12)),
              ),
            ],

            const SizedBox(height: 20),
            Center(
              child: PillButton(
                label: 'Got it',
                primary: true,
                onPressed: () => Navigator.pop(ctx),
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// A small circular info icon button to embed directly next to labels.
class OptionInfoIcon extends StatelessWidget {
  final VoidCallback onTap;
  final Color? color;
  final double size;

  const OptionInfoIcon({
    super.key,
    required this.onTap,
    this.color,
    this.size = 17,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Semantics(
      button: true,
      label: 'More information',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(4.0),
          child: Icon(
            Icons.info_outline_rounded,
            size: size,
            color: color ?? t.muted.withValues(alpha: 0.8),
          ),
        ),
      ),
    );
  }
}
