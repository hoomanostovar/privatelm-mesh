import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/model_controller.dart';
import '../core/haptics.dart';
import '../core/ui.dart';
import '../models/ai_model.dart';
import '../models/transport_type.dart';
import '../services/cluster_service.dart';
import '../services/inference_service.dart';
import '../services/mesh_discovery_service.dart';

/// Preset model profile used for interactive allocation previewing in the Mesh Visualizer.
class MeshModelPreviewOption {
  final String id;
  final String name;
  final double sizeMb;
  final int layers;
  final bool isLoaded;
  final bool isDownloaded;

  const MeshModelPreviewOption({
    required this.id,
    required this.name,
    required this.sizeMb,
    required this.layers,
    this.isLoaded = false,
    this.isDownloaded = false,
  });

  String get sizeLabel => '${(sizeMb / 1024).toStringAsFixed(1)} GB';
}

/// Device category used to draw the appropriate silhouette frame (PC Monitor, Tablet, Phone).
enum MeshDeviceSilhouetteType {
  pc,
  tablet,
  phone,
}

MeshDeviceSilhouetteType classifySilhouetteType(String deviceType, String name) {
  final combined = '${deviceType.toLowerCase()} ${name.toLowerCase()}';
  if (combined.contains('tablet') || combined.contains('ipad') || combined.contains('pad') || combined.contains('tab')) {
    return MeshDeviceSilhouetteType.tablet;
  }
  if (combined.contains('pc') ||
      combined.contains('desktop') ||
      combined.contains('windows') ||
      combined.contains('mac') ||
      combined.contains('linux') ||
      combined.contains('laptop')) {
    return MeshDeviceSilhouetteType.pc;
  }
  return MeshDeviceSilhouetteType.phone;
}

/// Shows a dialog to rename any mesh device (local or remote, online or offline)
/// and persists + syncs that name across all nodes on the mesh.
Future<void> showMeshDeviceRenameDialog({
  required BuildContext context,
  required MeshDiscoveryService discovery,
  required String nodeId,
  required String currentName,
  String? host,
}) async {
  final controller = TextEditingController(text: currentName);
  final result = await showAppSheet<String>(
    context,
    title: 'Rename Mesh Device',
    subtitle: 'This custom name is saved persistently across the mesh so you can immediately identify this device even if it turns off or crashes.',
    builder: (ctx) {
      final t = AppTokens.of(ctx);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: controller,
            autofocus: true,
            style: t.bodyStrong,
            decoration: InputDecoration(
              labelText: 'Device Name (e.g. Samsung S24 Kitchen, Gaming PC, iPad)',
              hintText: 'Enter a clear name for this device',
              filled: true,
              fillColor: t.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: t.hairline),
              ),
            ),
            onSubmitted: (val) => Navigator.pop(ctx, val.trim()),
          ),
          if (host != null && host.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Node ID: $nodeId  ·  Address: $host',
              style: t.caption.copyWith(color: t.muted),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: TonalButton.neutral(
                  ctx,
                  label: 'Cancel',
                  onTap: () => Navigator.pop(ctx),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: PrimaryButton(
                  label: 'Save Name Across Mesh',
                  icon: Icons.check_rounded,
                  onPressed: () => Navigator.pop(ctx, controller.text.trim()),
                ),
              ),
            ],
          ),
        ],
      );
    },
  );

  if (result != null && result.isNotEmpty && result != currentName) {
    await discovery.renameDevice(
      nodeId: nodeId,
      host: host,
      newName: result,
    );
    showToast(
      'Device Renamed',
      'Renamed to "$result" and synced across the mesh.',
      tone: ToastTone.success,
    );
  }
}

/// Device Silhouette & Layer Stack Pipeline Visualizer.
///
/// Renders each device in the mesh using its true form-factor silhouette:
/// - **PC / Mac / Linux**: Widescreen monitor frame with display stand & base
/// - **Tablet / iPad**: Wide-aspect rounded tablet frame with top camera dot
/// - **Phone**: Vertical smartphone frame with top earpiece slot
///
/// Inside each device silhouette, horizontal layer bars (`[════════]`) stack from top to bottom
/// showing how many transformer layers of the selected model fit in that device, connected
/// by directional pipeline arrows (`→`) between devices.
class MeshAllocationVisualizer extends StatefulWidget {
  final ClusterService cluster;
  final MeshDiscoveryService discovery;

  const MeshAllocationVisualizer({
    super.key,
    required this.cluster,
    required this.discovery,
  });

  @override
  State<MeshAllocationVisualizer> createState() => _MeshAllocationVisualizerState();
}

class _MeshAllocationVisualizerState extends State<MeshAllocationVisualizer>
    with SingleTickerProviderStateMixin {
  static const String _fontMono = 'Consolas';
  static const Color _dangerColor = Color(0xFFEF4444);
  static const Color _successColor = Color(0xFF10B981);

  late final AnimationController _pulseController;
  String? _selectedOptionId;
  bool _simulatePeerWhenSolo = false;

  static const List<MeshModelPreviewOption> _presets = [
    MeshModelPreviewOption(
      id: 'preset_1b',
      name: '1.5B Compact (Q4_K_M)',
      sizeMb: 1120,
      layers: 24,
    ),
    MeshModelPreviewOption(
      id: 'preset_7b',
      name: '7B–8B Standard (Q4_K_M)',
      sizeMb: 4780,
      layers: 32,
    ),
    MeshModelPreviewOption(
      id: 'preset_14b',
      name: '14B Reasoning (Q4_K_M)',
      sizeMb: 9200,
      layers: 40,
    ),
    MeshModelPreviewOption(
      id: 'preset_32b',
      name: '32B Heavy Coder (Q4_K_M)',
      sizeMb: 19800,
      layers: 64,
    ),
    MeshModelPreviewOption(
      id: 'preset_70b',
      name: '70B Frontier (Q4_K_M)',
      sizeMb: 42500,
      layers: 80,
    ),
  ];

  static const List<Color> _nodePalette = [
    Color(0xFF00F0FF), // Cyber Cyan (Node 1)
    Color(0xFF10B981), // Matrix Emerald (Node 2)
    Color(0xFFA855F7), // Plasma Violet (Node 3)
    Color(0xFFF59E0B), // Solar Amber (Node 4)
    Color(0xFFEC4899), // Neon Magenta (Node 5)
    Color(0xFF3B82F6), // Ion Blue (Node 6)
  ];

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  double _parseModelSizeMb(AiModel m, ModelController ctrl) {
    final fileBytes = ctrl.fileSizes[m.filename] ?? 0;
    if (fileBytes > 0) return math.max(350.0, fileBytes / (1024 * 1024));
    final match = RegExp(r'([\d.]+)\s*(GB|MB)', caseSensitive: false).firstMatch(m.size);
    if (match != null) {
      final val = double.tryParse(match.group(1) ?? '') ?? 1.5;
      final unit = (match.group(2) ?? 'GB').toUpperCase();
      return unit == 'GB' ? val * 1024 : val;
    }
    return 1800.0;
  }

  List<MeshModelPreviewOption> _buildOptions() {
    final options = <MeshModelPreviewOption>[];
    final inf = Get.isRegistered<InferenceService>() ? Get.find<InferenceService>() : null;
    final modelCtrl = Get.isRegistered<ModelController>() ? Get.find<ModelController>() : null;

    final loadedName = inf?.loadedModelName.value ?? '';

    if (modelCtrl != null) {
      final ggufModels = modelCtrl.availableModels
          .where((m) => m.runtime == AiModel.runtimeLlama)
          .toList();
      final downloaded = ggufModels.where((m) => modelCtrl.isDownloaded(m.filename)).toList();

      for (final m in downloaded) {
        final isLoaded = loadedName.isNotEmpty &&
            (loadedName.toLowerCase().contains(m.name.toLowerCase()) ||
                m.name.toLowerCase().contains(loadedName.toLowerCase()));
        final mb = _parseModelSizeMb(m, modelCtrl);
        options.add(MeshModelPreviewOption(
          id: 'model_${m.filename}',
          name: isLoaded ? '⚡ ${m.name} (Active)' : '📦 ${m.name}',
          sizeMb: mb,
          layers: _estimateLayers(mb),
          isLoaded: isLoaded,
          isDownloaded: true,
        ));
      }
    }

    if (loadedName.isNotEmpty && !options.any((o) => o.isLoaded)) {
      options.insert(
        0,
        MeshModelPreviewOption(
          id: 'loaded_active',
          name: '⚡ $loadedName (Active)',
          sizeMb: 2400,
          layers: 32,
          isLoaded: true,
          isDownloaded: true,
        ),
      );
    }

    options.addAll(_presets);
    return options;
  }

  int _estimateLayers(double sizeMb) {
    if (sizeMb < 1800) return 24;
    if (sizeMb < 6000) return 32;
    if (sizeMb < 12000) return 40;
    if (sizeMb < 25000) return 64;
    return 80;
  }

  List<MeshDeviceSlice> _computeSlices(MeshModelPreviewOption selected) {
    final baseSlices = widget.cluster.computeMeshAllocation(
      modelSizeMb: selected.sizeMb,
      totalLayers: selected.layers,
    );

    if (baseSlices.length == 1 && _simulatePeerWhenSolo) {
      // Synthesize a realistic 4-device heterogeneous mesh (PC + Tablet + 2 Phones)
      // matching the multi-device layer pipeline diagram!
      final local = baseSlices.first;
      final simCapacities = <({String id, String name, String type, String hw, double capMb, TransportType trans, double lat})>[
        (
          id: local.id,
          name: local.name,
          type: local.deviceType,
          hw: local.hardwareBackend,
          capMb: local.capacityMb,
          trans: local.transportType,
          lat: 0.0,
        ),
        (
          id: 'sim_tablet',
          name: widget.discovery.resolveCustomName('sim_tablet', fallback: 'iPad Pro Tablet'),
          type: 'Tablet',
          hw: 'Metal GPU · M2',
          capMb: 6144.0,
          trans: TransportType.wifi,
          lat: 2.8,
        ),
        (
          id: 'sim_phone_samsung',
          name: widget.discovery.resolveCustomName('sim_phone_samsung', fallback: 'Samsung Galaxy S24'),
          type: 'Phone',
          hw: 'Vulkan · Snapdragon',
          capMb: 4608.0,
          trans: TransportType.usb,
          lat: 1.4,
        ),
        (
          id: 'sim_phone_pixel',
          name: widget.discovery.resolveCustomName('sim_phone_pixel', fallback: 'Pixel 8 Phone'),
          type: 'Phone',
          hw: 'Vulkan · Tensor G3',
          capMb: 3584.0,
          trans: TransportType.wifi,
          lat: 4.5,
        ),
      ];

      final totalPool = simCapacities.fold<double>(0, (s, n) => s + n.capMb);
      final needMb = selected.sizeMb * 1.1;
      var leftMb = needMb;
      final assignedList = <double>[];
      for (final n in simCapacities) {
        final a = math.max(0.0, math.min(n.capMb, leftMb));
        assignedList.add(a);
        leftMb -= a;
      }
      final totalAssigned = math.max(1.0, assignedList.fold<double>(0, (s, a) => s + a));

      var curLayer = 0;
      final result = <MeshDeviceSlice>[];
      for (var i = 0; i < simCapacities.length; i++) {
        final n = simCapacities[i];
        final assigned = assignedList[i];
        final lCount = assigned > 0
            ? math.max(1, ((assigned / totalAssigned) * selected.layers).round())
            : 0;
        final startL = curLayer;
        final endL = assigned > 0 ? math.min(selected.layers, startL + lCount) : startL;
        curLayer = endL;

        result.add(MeshDeviceSlice(
          id: n.id,
          name: n.name,
          deviceType: n.type,
          hardwareBackend: n.hw,
          transportType: n.trans,
          latencyMs: n.lat,
          capacityMb: n.capMb,
          assignedModelMb: assigned,
          poolShareFraction: n.capMb / totalPool,
          modelFraction: needMb > 0 ? (assigned / needMb).clamp(0.0, 1.0) : 0.0,
          memoryUtilization: (assigned / n.capMb).clamp(0.0, 1.0),
          layerStart: startL,
          layerEnd: endL,
          isLocal: i == 0,
          isOffline: false,
        ));
      }
      return result;
    }

    return baseSlices;
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      // Touch reactive observables so UI updates on node join/leave/rename or model switch
      widget.cluster.workers.length;
      widget.cluster.enabled.value;
      widget.cluster.schedulerStrategy.value;
      widget.discovery.onlineNodes.length;
      widget.discovery.deviceAliases.length;
      widget.discovery.localCustomName.value;

      final options = _buildOptions();
      final activeOption = options.firstWhere(
        (o) => o.id == _selectedOptionId,
        orElse: () => options.firstWhere(
          (o) => o.isLoaded,
          orElse: () => options.first,
        ),
      );

      final slices = _computeSlices(activeOption);
      final onlineSlices = slices.where((s) => !s.isOffline).toList();
      final offlineSlices = slices.where((s) => s.isOffline).toList();
      final totalPoolMb = onlineSlices.fold<double>(0, (s, d) => s + d.capacityMb);
      final needMb = activeOption.sizeMb * 1.1; // Model + 10% KV cache
      final totalAssignedMb = onlineSlices.fold<double>(0, (s, d) => s + d.assignedModelMb);
      final fitsInMesh = needMb <= totalPoolMb + 1.0;
      final fitPercentage = needMb > 0 ? ((totalAssignedMb / needMb) * 100).clamp(0.0, 100.0) : 100.0;

      return Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF0A0F1D),
              Color(0xFF0F172A),
              Color(0xFF0B1120),
            ],
          ),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: offlineSlices.isNotEmpty
                ? const Color(0xFFF59E0B).withValues(alpha: 0.65)
                : (fitsInMesh
                    ? const Color(0xFF00F0FF).withValues(alpha: 0.32)
                    : _dangerColor.withValues(alpha: 0.55)),
            width: 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: (fitsInMesh ? const Color(0xFF00F0FF) : _dangerColor)
                  .withValues(alpha: 0.08),
              blurRadius: 24,
              spreadRadius: 1,
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _SciFiHudGridPainter(
                    accentColor: fitsInMesh ? const Color(0xFF00F0FF) : _dangerColor,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHudHeader(
                      activeOption: activeOption,
                      onlineSlices: onlineSlices,
                      offlineSlices: offlineSlices,
                      totalPoolMb: totalPoolMb,
                      needMb: needMb,
                      fitsInMesh: fitsInMesh,
                      fitPercentage: fitPercentage,
                    ),
                    if (offlineSlices.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      _buildOfflineAlertBanner(context, offlineSlices),
                    ],
                    const SizedBox(height: 14),
                    _buildModelSelectorStrip(options, activeOption),
                    const SizedBox(height: 18),
                    _buildDeviceSilhouettePipeline(
                      context: context,
                      slices: slices,
                      totalLayers: activeOption.layers,
                    ),
                    const SizedBox(height: 14),
                    _buildProportionalPoolLegend(
                      slices: onlineSlices,
                      totalPoolMb: totalPoolMb,
                      needMb: needMb,
                      fitsInMesh: fitsInMesh,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  Widget _buildOfflineAlertBanner(BuildContext context, List<MeshDeviceSlice> offlineSlices) {
    final names = offlineSlices.map((s) => '${s.name} (${s.deviceType})').join(', ');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: _dangerColor.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _dangerColor.withValues(alpha: 0.55)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: _dangerColor, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'OFFLINE / UNREACHABLE DEVICE: $names — Check power or Wi-Fi on that device.',
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: Color(0xFFFCA5A5),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHudHeader({
    required MeshModelPreviewOption activeOption,
    required List<MeshDeviceSlice> onlineSlices,
    required List<MeshDeviceSlice> offlineSlices,
    required double totalPoolMb,
    required double needMb,
    required bool fitsInMesh,
    required double fitPercentage,
  }) {
    final realNodeCount = widget.discovery.peerNodes.length + 1;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AnimatedBuilder(
          animation: _pulseController,
          builder: (context, _) {
            final glow = 0.35 + (_pulseController.value * 0.45);
            final statusColor = fitsInMesh ? const Color(0xFF00F0FF) : _dangerColor;
            return Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(11),
                border: Border.all(
                  color: statusColor.withValues(alpha: glow),
                  width: 1.4,
                ),
              ),
              child: Icon(
                fitsInMesh ? Icons.devices_other_rounded : Icons.warning_amber_rounded,
                color: statusColor,
                size: 21,
              ),
            );
          },
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text(
                    'MESH DEVICE LAYER PIPELINE',
                    style: TextStyle(
                      fontFamily: _fontMono,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                      color: Color(0xFF00F0FF),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: (fitsInMesh ? _successColor : _dangerColor)
                          .withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(
                        color: (fitsInMesh ? _successColor : _dangerColor)
                            .withValues(alpha: 0.45),
                      ),
                    ),
                    child: Text(
                      fitsInMesh
                          ? '100% FITS IN POOL'
                          : 'OVERFLOW (${fitPercentage.toStringAsFixed(0)}% FITS)',
                      style: TextStyle(
                        fontFamily: _fontMono,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w700,
                        color: fitsInMesh ? _successColor : _dangerColor,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0, end: needMb / 1024),
                duration: const Duration(milliseconds: 550),
                curve: Curves.easeOutCubic,
                builder: (context, animatedNeedGb, _) {
                  return Text(
                    'Model: ${animatedNeedGb.toStringAsFixed(1)} GB (${activeOption.layers} Layers)  ·  '
                    'Pool: ${(totalPoolMb / 1024).toStringAsFixed(1)} GB (${onlineSlices.length} Online${offlineSlices.isNotEmpty ? ", ${offlineSlices.length} Offline" : ""})',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF94A3B8),
                      fontWeight: FontWeight.w500,
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        if (realNodeCount == 1)
          Tooltip(
            message: 'Preview PC + Tablet + Phones layer pipeline when solo',
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () {
                Haptics.selectionClick();
                setState(() => _simulatePeerWhenSolo = !_simulatePeerWhenSolo);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                decoration: BoxDecoration(
                  color: _simulatePeerWhenSolo
                      ? const Color(0xFFA855F7).withValues(alpha: 0.2)
                      : Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _simulatePeerWhenSolo
                        ? const Color(0xFFA855F7)
                        : Colors.white.withValues(alpha: 0.14),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.science_rounded,
                      size: 13,
                      color: _simulatePeerWhenSolo
                          ? const Color(0xFFD8B4FE)
                          : const Color(0xFF94A3B8),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      _simulatePeerWhenSolo ? 'Preview: 4 Devices' : 'Preview Multi-Device',
                      style: TextStyle(
                        fontFamily: _fontMono,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: _simulatePeerWhenSolo
                            ? const Color(0xFFD8B4FE)
                            : const Color(0xFF94A3B8),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildModelSelectorStrip(
    List<MeshModelPreviewOption> options,
    MeshModelPreviewOption activeOption,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'SELECT MODEL TO ANIMATE LAYER STACK ACROSS DEVICES:',
          style: TextStyle(
            fontFamily: _fontMono,
            fontSize: 10,
            letterSpacing: 0.9,
            fontWeight: FontWeight.w600,
            color: Color(0xFF64748B),
          ),
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final opt in options)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _buildModelChip(opt, opt.id == activeOption.id),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildModelChip(MeshModelPreviewOption option, bool isSelected) {
    const cyan = Color(0xFF00F0FF);
    return GestureDetector(
      onTap: () {
        Haptics.selectionClick();
        setState(() => _selectedOptionId = option.id);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: isSelected
              ? cyan.withValues(alpha: 0.16)
              : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: isSelected
                ? cyan.withValues(alpha: 0.85)
                : Colors.white.withValues(alpha: 0.10),
            width: isSelected ? 1.3 : 1.0,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              option.name,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                color: isSelected ? Colors.white : const Color(0xFFCBD5E1),
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
              decoration: BoxDecoration(
                color: isSelected
                    ? cyan.withValues(alpha: 0.24)
                    : Colors.white.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                option.sizeLabel,
                style: TextStyle(
                  fontFamily: _fontMono,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: isSelected ? cyan : const Color(0xFF94A3B8),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Renders the horizontal row of Device Silhouettes (PC, Tablet, Phone)
  /// with stacked horizontal layer bars inside each device and directional arrows (`→`)
  /// connecting each device in the pipeline — matching the reference diagram!
  Widget _buildDeviceSilhouettePipeline({
    required BuildContext context,
    required List<MeshDeviceSlice> slices,
    required int totalLayers,
  }) {
    final maxCapMb = slices.fold<double>(1024.0, (m, s) => math.max(m, s.capacityMb));

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF060A14),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            for (var i = 0; i < slices.length; i++) ...[
              if (i > 0)
                _buildPipelineArrow(
                  active: !slices[i].isOffline && slices[i].assignedModelMb > 0,
                  isOffline: slices[i].isOffline,
                  color: _nodePalette[i % _nodePalette.length],
                ),
              _buildSingleDeviceSilhouetteColumn(
                context: context,
                slice: slices[i],
                index: i,
                maxCapacityMb: maxCapMb,
                totalLayers: totalLayers,
                color: slices[i].isOffline
                    ? _dangerColor
                    : _nodePalette[i % _nodePalette.length],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPipelineArrow({
    required bool active,
    required bool isOffline,
    required Color color,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isOffline ? Icons.link_off_rounded : Icons.arrow_forward_rounded,
            size: 22,
            color: isOffline
                ? _dangerColor.withValues(alpha: 0.85)
                : (active ? color : Colors.white.withValues(alpha: 0.22)),
          ),
          const SizedBox(height: 2),
          Text(
            isOffline ? 'OFFLINE' : (active ? 'RPC' : 'IDLE'),
            style: TextStyle(
              fontFamily: _fontMono,
              fontSize: 8.5,
              fontWeight: FontWeight.w700,
              color: isOffline
                  ? _dangerColor
                  : (active ? color : const Color(0xFF64748B)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSingleDeviceSilhouetteColumn({
    required BuildContext context,
    required MeshDeviceSlice slice,
    required int index,
    required double maxCapacityMb,
    required int totalLayers,
    required Color color,
  }) {
    final silhouetteType = classifySilhouetteType(slice.deviceType, slice.name);

    // Width & height tailored per device symbol (PC monitor vs Tablet vs Phone)
    final double frameWidth = switch (silhouetteType) {
      MeshDeviceSilhouetteType.pc => 152.0,
      MeshDeviceSilhouetteType.tablet => 132.0,
      MeshDeviceSilhouetteType.phone => 112.0,
    };
    const double frameHeight = 204.0;

    // Total layer capacity slots inside this device's screen proportional to its memory capacity
    final int maxSlots = (6 + ((slice.capacityMb / maxCapacityMb) * 8).round()).clamp(6, 14);

    return TweenAnimationBuilder<double>(
      tween: Tween<double>(
        begin: 0.0,
        end: slice.isOffline ? 0.0 : slice.memoryUtilization.clamp(0.0, 1.0),
      ),
      duration: const Duration(milliseconds: 650),
      curve: Curves.easeOutCubic,
      builder: (context, animatedFill, _) {
        final filledSlots = slice.assignedModelMb > 0
            ? math.max(1, (animatedFill * maxSlots).round())
            : 0;
        final modelPct = (slice.modelFraction * 100).round();

        return SizedBox(
          width: frameWidth + 14,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Top badge: Device Type Symbol + Editable Persistent Name
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => showMeshDeviceRenameDialog(
                  context: context,
                  discovery: widget.discovery,
                  nodeId: slice.id,
                  currentName: slice.name,
                  host: slice.host,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        switch (silhouetteType) {
                          MeshDeviceSilhouetteType.pc => Icons.desktop_windows_rounded,
                          MeshDeviceSilhouetteType.tablet => Icons.tablet_mac_rounded,
                          MeshDeviceSilhouetteType.phone => Icons.smartphone_rounded,
                        },
                        size: 13,
                        color: color,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          slice.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: slice.isOffline ? const Color(0xFFFCA5A5) : Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(width: 3),
                      Icon(
                        Icons.edit_rounded,
                        size: 11,
                        color: Colors.white.withValues(alpha: 0.45),
                      ),
                    ],
                  ),
                ),
              ),
              Text(
                slice.isOffline
                    ? 'OFFLINE · ${slice.host ?? "Unreachable"}'
                    : '${slice.deviceType.toUpperCase()} · ${(slice.capacityMb / 1024).toStringAsFixed(1)} GB Pool',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: _fontMono,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w600,
                  color: slice.isOffline ? _dangerColor : const Color(0xFF94A3B8),
                ),
              ),
              const SizedBox(height: 8),

              // Device Silhouette Frame (Phone / Tablet / PC Monitor) with Stacked Layer Bars
              SizedBox(
                width: frameWidth,
                height: frameHeight,
                child: AnimatedBuilder(
                  animation: _pulseController,
                  builder: (context, _) {
                    return CustomPaint(
                      painter: _DeviceSilhouetteLayerStackPainter(
                        silhouetteType: silhouetteType,
                        totalSlots: maxSlots,
                        filledSlots: filledSlots,
                        fillFraction: animatedFill,
                        color: color,
                        pulse: _pulseController.value,
                        isOffline: slice.isOffline,
                      ),
                      child: slice.isOffline
                          ? Center(
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.78),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: _dangerColor),
                                ),
                                child: const Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.power_off_rounded, color: _dangerColor, size: 22),
                                    SizedBox(height: 4),
                                    Text(
                                      'OFFLINE',
                                      style: TextStyle(
                                        fontFamily: _fontMono,
                                        fontSize: 10,
                                        fontWeight: FontWeight.w800,
                                        color: _dangerColor,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          : null,
                    );
                  },
                ),
              ),

              const SizedBox(height: 8),
              // Bottom Layer & Memory Allocation Readout
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: color.withValues(alpha: 0.38)),
                ),
                child: Text(
                  slice.isOffline
                      ? 'TURNED OFF / CRASHED'
                      : (slice.assignedModelMb > 0
                          ? '$modelPct% Model · ${(slice.assignedModelMb / 1024).toStringAsFixed(1)} GB'
                          : '0% · Standby Reserve'),
                  style: TextStyle(
                    fontFamily: _fontMono,
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                    color: slice.isOffline ? _dangerColor : color,
                  ),
                ),
              ),
              const SizedBox(height: 3),
              Text(
                slice.isOffline
                    ? 'Tap name above to rename'
                    : (slice.assignedModelMb > 0
                        ? 'Layers L${slice.layerStart.toString().padLeft(2, '0')}–L${slice.layerEnd.toString().padLeft(2, '0')} ($filledSlots/$maxSlots Slots)'
                        : 'No layers assigned'),
                style: const TextStyle(
                  fontFamily: _fontMono,
                  fontSize: 9,
                  color: Color(0xFF94A3B8),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Compact proportional pool summary bar below the silhouette pipeline.
  Widget _buildProportionalPoolLegend({
    required List<MeshDeviceSlice> slices,
    required double totalPoolMb,
    required double needMb,
    required bool fitsInMesh,
  }) {
    if (slices.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'PROPORTIONAL MEMORY POOL SHARE  ·  TAP ANY DEVICE NAME ABOVE TO RENAME',
              style: TextStyle(
                fontFamily: _fontMono,
                fontSize: 9.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: Color(0xFF94A3B8),
              ),
            ),
            Text(
              '${((needMb / math.max(1.0, totalPoolMb)) * 100).clamp(0.0, 999.0).toStringAsFixed(0)}% Pool Used',
              style: TextStyle(
                fontFamily: _fontMono,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: fitsInMesh ? const Color(0xFF00F0FF) : _dangerColor,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          height: 16,
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: const Color(0xFF050811),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          ),
          child: Row(
            children: [
              for (var i = 0; i < slices.length; i++) ...[
                if (i > 0) const SizedBox(width: 3),
                Expanded(
                  flex: math.max(8, (slices[i].poolShareFraction * 1000).round()),
                  child: TweenAnimationBuilder<double>(
                    tween: Tween<double>(
                      begin: 0.0,
                      end: slices[i].memoryUtilization.clamp(0.0, 1.0),
                    ),
                    duration: const Duration(milliseconds: 600),
                    curve: Curves.easeOutCubic,
                    builder: (context, fill, _) {
                      final c = _nodePalette[i % _nodePalette.length];
                      return Container(
                        decoration: BoxDecoration(
                          color: c.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: fill,
                          heightFactor: 1.0,
                          child: Container(
                            decoration: BoxDecoration(
                              color: c,
                              borderRadius: BorderRadius.circular(5),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// CustomPainter that draws:
/// 1. The hardware silhouette for the device category:
///    - **Phone**: Vertical rounded chassis + top speaker/earpiece pill + bottom home indicator
///    - **Tablet**: Wider rounded tablet chassis + top camera dot + side bezel frame
///    - **PC**: Desktop monitor screen frame + bottom neck & stand base
/// 2. The vertical stack of horizontal model layer bars (`[════════]`) from top to bottom
///    inside the device's screen area (matching the uploaded reference diagram).
class _DeviceSilhouetteLayerStackPainter extends CustomPainter {
  final MeshDeviceSilhouetteType silhouetteType;
  final int totalSlots;
  final int filledSlots;
  final double fillFraction;
  final Color color;
  final double pulse;
  final bool isOffline;

  _DeviceSilhouetteLayerStackPainter({
    required this.silhouetteType,
    required this.totalSlots,
    required this.filledSlots,
    required this.fillFraction,
    required this.color,
    required this.pulse,
    required this.isOffline,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..color = isOffline
          ? color.withValues(alpha: 0.55)
          : (filledSlots > 0
              ? color.withValues(alpha: 0.75 + pulse * 0.20)
              : Colors.white.withValues(alpha: 0.28));

    final bodyFillPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = const Color(0xFF0E1628);

    late Rect screenRect;

    if (silhouetteType == MeshDeviceSilhouetteType.pc) {
      // PC Monitor Frame + Neck + Base Stand
      final monitorHeight = size.height - 24.0;
      final monitorRRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(2, 2, size.width - 4, monitorHeight),
        const Radius.circular(12),
      );
      canvas.drawRRect(monitorRRect, bodyFillPaint);
      canvas.drawRRect(monitorRRect, borderPaint);

      // Monitor top webcam dot
      canvas.drawCircle(
        Offset(size.width / 2, 9),
        2.2,
        Paint()..color = color.withValues(alpha: 0.6),
      );

      // Monitor Neck
      final neckRect = Rect.fromLTWH(size.width / 2 - 10, monitorHeight + 2, 20, 12);
      canvas.drawRect(neckRect, bodyFillPaint);
      canvas.drawRect(neckRect, borderPaint);

      // Monitor Stand Base
      final baseRRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(size.width * 0.22, size.height - 10, size.width * 0.56, 7),
        const Radius.circular(3.5),
      );
      canvas.drawRRect(baseRRect, bodyFillPaint);
      canvas.drawRRect(baseRRect, borderPaint);

      screenRect = Rect.fromLTWH(12, 18, size.width - 24, monitorHeight - 28);
    } else if (silhouetteType == MeshDeviceSilhouetteType.tablet) {
      // Tablet Frame (wide rounded frame with top camera dot & bottom bar)
      final tabletRRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(2, 2, size.width - 4, size.height - 4),
        const Radius.circular(18),
      );
      canvas.drawRRect(tabletRRect, bodyFillPaint);
      canvas.drawRRect(tabletRRect, borderPaint);

      // Tablet top camera lens
      canvas.drawCircle(
        Offset(size.width / 2, 12),
        2.8,
        Paint()..color = Colors.white.withValues(alpha: 0.45),
      );

      screenRect = Rect.fromLTWH(13, 24, size.width - 26, size.height - 40);
    } else {
      // Phone Frame (rounded vertical chassis with top earpiece pill, matching reference image)
      final phoneRRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(2, 2, size.width - 4, size.height - 4),
        const Radius.circular(22),
      );
      canvas.drawRRect(phoneRRect, bodyFillPaint);
      canvas.drawRRect(phoneRRect, borderPaint);

      // Top speaker/earpiece slot pill (just like the reference image!)
      final notchRRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(size.width * 0.34, 11, size.width * 0.32, 4.5),
        const Radius.circular(3),
      );
      canvas.drawRRect(
        notchRRect,
        Paint()..color = Colors.white.withValues(alpha: 0.55),
      );

      screenRect = Rect.fromLTWH(13, 24, size.width - 26, size.height - 40);
    }

    // Draw stacked horizontal layer bars from top to bottom inside screenRect!
    const double barGap = 3.5;
    final double barHeight = math.min(
      10.5,
      math.max(5.0, (screenRect.height - (totalSlots - 1) * barGap) / totalSlots),
    );

    for (var i = 0; i < totalSlots; i++) {
      final top = screenRect.top + i * (barHeight + barGap);
      if (top + barHeight > screenRect.bottom + 2) break;

      final barRRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(screenRect.left, top, screenRect.width, barHeight),
        const Radius.circular(2.5),
      );

      final isFilled = !isOffline && i < filledSlots;
      if (isFilled) {
        final fillPaint = Paint()
          ..style = PaintingStyle.fill
          ..color = color.withValues(alpha: 0.65 + pulse * 0.20);
        final strokePaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0
          ..color = Colors.white.withValues(alpha: 0.55);

        canvas.drawRRect(barRRect, fillPaint);
        canvas.drawRRect(barRRect, strokePaint);
      } else {
        // Empty capacity slot outline
        final emptyFill = Paint()
          ..style = PaintingStyle.fill
          ..color = Colors.white.withValues(alpha: 0.03);
        final emptyStroke = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8
          ..color = Colors.white.withValues(alpha: 0.11);

        canvas.drawRRect(barRRect, emptyFill);
        canvas.drawRRect(barRRect, emptyStroke);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DeviceSilhouetteLayerStackPainter oldDelegate) =>
      oldDelegate.silhouetteType != silhouetteType ||
      oldDelegate.totalSlots != totalSlots ||
      oldDelegate.filledSlots != filledSlots ||
      oldDelegate.fillFraction != fillFraction ||
      oldDelegate.color != color ||
      oldDelegate.pulse != pulse ||
      oldDelegate.isOffline != isOffline;
}

/// Renders a subtle sci-fi tactical coordinate grid behind the visualizer.
class _SciFiHudGridPainter extends CustomPainter {
  final Color accentColor;

  _SciFiHudGridPainter({required this.accentColor});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = accentColor.withValues(alpha: 0.035)
      ..strokeWidth = 1.0;

    const step = 24.0;
    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SciFiHudGridPainter oldDelegate) =>
      oldDelegate.accentColor != accentColor;
}
