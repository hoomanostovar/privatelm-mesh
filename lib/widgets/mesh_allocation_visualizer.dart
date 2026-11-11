import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/model_controller.dart';
import '../core/haptics.dart';
import '../models/ai_model.dart';
import '../models/transport_type.dart';
import '../services/cluster_service.dart';
import '../services/inference_service.dart';
import '../services/mesh_discovery_service.dart';

/// Preset model profile used for interactive allocation previewing in the Sci-Fi Mesh Visualizer.
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

/// Sci-Fi Game HUD Visualizer for Mesh Memory Pooling & Model Layer Allocation.
///
/// Shows:
/// 1. Interactive model selector (loaded model, downloaded GGUF models, and size presets)
///    that animates the allocation transitions smoothly when switching models.
/// 2. Proportional Multi-Node Reactor Bar where each device's width is proportional to its
///    share of the total mesh memory pool, and the inner glowing energy bar animates how much
///    of the selected model fits inside that device.
/// 3. Per-device Tactical Core Cards showing exact GB used vs. capacity, % of model, and
///    assigned transformer layer range (e.g. L00–L22).
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
    Color(0xFF00F0FF), // Cyber Cyan (Local Primary)
    Color(0xFF10B981), // Matrix Emerald
    Color(0xFFA855F7), // Plasma Violet
    Color(0xFFF59E0B), // Solar Amber
    Color(0xFFEC4899), // Neon Magenta
    Color(0xFF3B82F6), // Ion Blue
  ];

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
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
      // Synthesize a realistic 2-node heterogeneous mesh preview when user toggles simulation on a solo PC
      final local = baseSlices.first;
      const peerCapMb = 6144.0; // 6 GB peer node
      final totalPool = local.capacityMb + peerCapMb;
      final needMb = selected.sizeMb * 1.1;
      final localAssigned = math.min(local.capacityMb, needMb);
      final peerAssigned = math.max(0.0, math.min(peerCapMb, needMb - localAssigned));
      final totalAssigned = math.max(1.0, localAssigned + peerAssigned);

      final localLayers = localAssigned > 0
          ? math.max(1, ((localAssigned / totalAssigned) * selected.layers).round())
          : 0;

      return [
        MeshDeviceSlice(
          id: local.id,
          name: local.name,
          deviceType: local.deviceType,
          hardwareBackend: local.hardwareBackend,
          transportType: local.transportType,
          latencyMs: 0.0,
          capacityMb: local.capacityMb,
          assignedModelMb: localAssigned,
          poolShareFraction: local.capacityMb / totalPool,
          modelFraction: needMb > 0 ? (localAssigned / needMb).clamp(0.0, 1.0) : 0.0,
          memoryUtilization: (localAssigned / local.capacityMb).clamp(0.0, 1.0),
          layerStart: 0,
          layerEnd: localLayers,
          isLocal: true,
        ),
        MeshDeviceSlice(
          id: 'sim_peer_1',
          name: 'Simulated Mesh Peer (6 GB Node)',
          deviceType: 'Phone',
          hardwareBackend: 'Vulkan GPU · Snapdragon',
          transportType: TransportType.wifi,
          latencyMs: 4.2,
          capacityMb: peerCapMb,
          assignedModelMb: peerAssigned,
          poolShareFraction: peerCapMb / totalPool,
          modelFraction: needMb > 0 ? (peerAssigned / needMb).clamp(0.0, 1.0) : 0.0,
          memoryUtilization: (peerAssigned / peerCapMb).clamp(0.0, 1.0),
          layerStart: localLayers,
          layerEnd: peerAssigned > 0 ? selected.layers : localLayers,
          isLocal: false,
        ),
      ];
    }

    return baseSlices;
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      // Touch reactive dependencies so visualizer updates live when nodes join/leave or models load
      widget.cluster.workers.length;
      widget.cluster.enabled.value;
      widget.cluster.schedulerStrategy.value;
      widget.discovery.onlineNodes.length;

      final options = _buildOptions();
      final activeOption = options.firstWhere(
        (o) => o.id == _selectedOptionId,
        orElse: () => options.firstWhere(
          (o) => o.isLoaded,
          orElse: () => options.first,
        ),
      );

      final slices = _computeSlices(activeOption);
      final totalPoolMb = slices.fold<double>(0, (s, d) => s + d.capacityMb);
      final needMb = activeOption.sizeMb * 1.1; // Model + 10% KV cache
      final totalAssignedMb = slices.fold<double>(0, (s, d) => s + d.assignedModelMb);
      final fitsInMesh = needMb <= totalPoolMb + 1.0;
      final fitPercentage = needMb > 0 ? ((totalAssignedMb / needMb) * 100).clamp(0.0, 100.0) : 100.0;

      return Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF090D16),
              Color(0xFF0F172A),
              Color(0xFF0B1120),
            ],
          ),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: fitsInMesh
                ? const Color(0xFF00F0FF).withValues(alpha: 0.32)
                : _dangerColor.withValues(alpha: 0.55),
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
              // Subtle sci-fi tactical grid background
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
                      slices: slices,
                      totalPoolMb: totalPoolMb,
                      needMb: needMb,
                      fitsInMesh: fitsInMesh,
                      fitPercentage: fitPercentage,
                    ),
                    const SizedBox(height: 14),
                    _buildModelSelectorStrip(options, activeOption),
                    const SizedBox(height: 16),
                    _buildProportionalReactorBar(
                      slices: slices,
                      totalPoolMb: totalPoolMb,
                      needMb: needMb,
                      fitsInMesh: fitsInMesh,
                    ),
                    const SizedBox(height: 16),
                    _buildDeviceSliceCards(slices, activeOption, needMb),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  Widget _buildHudHeader({
    required MeshModelPreviewOption activeOption,
    required List<MeshDeviceSlice> slices,
    required double totalPoolMb,
    required double needMb,
    required bool fitsInMesh,
    required double fitPercentage,
  }) {
    final realNodeCount = widget.cluster.workers.length + 1;

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
                boxShadow: [
                  BoxShadow(
                    color: statusColor.withValues(alpha: glow * 0.4),
                    blurRadius: 12,
                  ),
                ],
              ),
              child: Icon(
                fitsInMesh ? Icons.blur_on_rounded : Icons.warning_amber_rounded,
                color: statusColor,
                size: 22,
              ),
            );
          },
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text(
                    'NEURAL MESH ALLOCATION CORE',
                    style: TextStyle(
                      fontFamily: _fontMono,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.4,
                      color: Color(0xFF00F0FF),
                    ),
                  ),
                  const SizedBox(width: 8),
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
                    'Model Footprint: ${animatedNeedGb.toStringAsFixed(1)} GB (incl. KV)  ·  '
                    'Total Mesh Pool: ${(totalPoolMb / 1024).toStringAsFixed(1)} GB across ${slices.length} ${slices.length == 1 ? "Node" : "Nodes"}',
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
            message: 'Preview how models split across multiple devices when a second node joins',
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
                      _simulatePeerWhenSolo ? 'Simulating +1 Peer' : 'Simulate +1 Peer',
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
          'SELECT MODEL TO ANIMATE MESH MEMORY DISTRIBUTION:',
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
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: cyan.withValues(alpha: 0.22),
                    blurRadius: 10,
                  ),
                ]
              : null,
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

  /// Proportional Multi-Node Reactor Bar:
  /// Each device's horizontal chamber is sized proportionally to its memory capacity (`poolShareFraction`),
  /// and its internal animated fill shows how much of that device's memory is occupied by the model.
  Widget _buildProportionalReactorBar({
    required List<MeshDeviceSlice> slices,
    required double totalPoolMb,
    required double needMb,
    required bool fitsInMesh,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'PROPORTIONAL DEVICE MEMORY CHAMBERS & MODEL LOAD',
              style: TextStyle(
                fontFamily: _fontMono,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.9,
                color: Color(0xFF94A3B8),
              ),
            ),
            Text(
              '${((needMb / math.max(1.0, totalPoolMb)) * 100).clamp(0.0, 999.0).toStringAsFixed(0)}% Pool Load',
              style: TextStyle(
                fontFamily: _fontMono,
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: fitsInMesh ? const Color(0xFF00F0FF) : _dangerColor,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          height: 54,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: const Color(0xFF050811),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.12),
            ),
          ),
          child: Row(
            children: [
              for (var i = 0; i < slices.length; i++) ...[
                if (i > 0) const SizedBox(width: 4),
                Expanded(
                  flex: math.max(8, (slices[i].poolShareFraction * 1000).round()),
                  child: _buildChamberSegment(
                    slice: slices[i],
                    color: _nodePalette[i % _nodePalette.length],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildChamberSegment({
    required MeshDeviceSlice slice,
    required Color color,
  }) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0.0, end: slice.memoryUtilization.clamp(0.0, 1.0)),
      duration: const Duration(milliseconds: 650),
      curve: Curves.easeOutCubic,
      builder: (context, animatedFill, _) {
        final pctPool = (slice.poolShareFraction * 100).round();
        final pctUsed = (animatedFill * 100).round();

        return Container(
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: color.withValues(alpha: slice.assignedModelMb > 0 ? 0.55 : 0.20),
              width: 1.0,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(7),
            child: Stack(
              children: [
                // Animated Sci-Fi scanline fill proportional to how full this device's RAM is
                FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: animatedFill,
                  heightFactor: 1.0,
                  child: AnimatedBuilder(
                    animation: _pulseController,
                    builder: (context, _) {
                      return CustomPaint(
                        painter: _SciFiCoreFillPainter(
                          color: color,
                          pulse: _pulseController.value,
                        ),
                      );
                    },
                  ),
                ),
                // Overlay telemetry text inside chamber
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              slice.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                                shadows: [
                                  Shadow(color: Colors.black, blurRadius: 4),
                                ],
                              ),
                            ),
                          ),
                          Text(
                            '$pctPool% Pool',
                            style: TextStyle(
                              fontFamily: _fontMono,
                              fontSize: 9.5,
                              fontWeight: FontWeight.w700,
                              color: color,
                              shadows: const [
                                Shadow(color: Colors.black, blurRadius: 4),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        slice.assignedModelMb > 0
                            ? '${(slice.assignedModelMb / 1024).toStringAsFixed(1)} / ${(slice.capacityMb / 1024).toStringAsFixed(1)} GB ($pctUsed% Full)'
                            : 'STANDBY · ${(slice.capacityMb / 1024).toStringAsFixed(1)} GB Free',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: _fontMono,
                          fontSize: 9.5,
                          color: Color(0xFFE2E8F0),
                          shadows: [
                            Shadow(color: Colors.black, blurRadius: 4),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildDeviceSliceCards(
    List<MeshDeviceSlice> slices,
    MeshModelPreviewOption activeOption,
    double needMb,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'ACTIVE MESH NODES · LAYER & TENSOR SPLIT TELEMETRY',
          style: TextStyle(
            fontFamily: _fontMono,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.9,
            color: Color(0xFF94A3B8),
          ),
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < slices.length; i++)
          Padding(
            padding: EdgeInsets.only(bottom: i == slices.length - 1 ? 0 : 8),
            child: _buildTacticalNodeCard(
              slice: slices[i],
              color: _nodePalette[i % _nodePalette.length],
              totalLayers: activeOption.layers,
            ),
          ),
      ],
    );
  }

  Widget _buildTacticalNodeCard({
    required MeshDeviceSlice slice,
    required Color color,
    required int totalLayers,
  }) {
    final isUsed = slice.assignedModelMb > 0;
    final linkLabel = slice.isLocal
        ? 'LOCAL BUS · 0ms'
        : '${slice.transportType.displayName.toUpperCase()} · ${slice.latencyMs.toStringAsFixed(0)}ms';

    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0.0, end: slice.modelFraction.clamp(0.0, 1.0)),
      duration: const Duration(milliseconds: 650),
      curve: Curves.easeOutCubic,
      builder: (context, animatedModelShare, _) {
        final modelPct = (animatedModelShare * 100).round();

        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF0B1325).withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isUsed
                  ? color.withValues(alpha: 0.42)
                  : Colors.white.withValues(alpha: 0.08),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: color.withValues(alpha: 0.45)),
                    ),
                    child: Icon(
                      slice.deviceType.toLowerCase().contains('phone')
                          ? Icons.smartphone_rounded
                          : Icons.developer_board_rounded,
                      size: 17,
                      color: color,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                slice.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                              decoration: BoxDecoration(
                                color: color.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                linkLabel,
                                style: TextStyle(
                                  fontFamily: _fontMono,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w700,
                                  color: color,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${slice.hardwareBackend}  ·  Pool Share: ${(slice.poolShareFraction * 100).round()}% (${(slice.capacityMb / 1024).toStringAsFixed(1)} GB Allocatable)',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFF94A3B8),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        isUsed ? '$modelPct% OF MODEL' : '0% (IDLE)',
                        style: TextStyle(
                          fontFamily: _fontMono,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                          color: isUsed ? color : const Color(0xFF64748B),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        isUsed
                            ? 'Layers L${slice.layerStart.toString().padLeft(2, '0')}–L${slice.layerEnd.toString().padLeft(2, '0')} / $totalLayers'
                            : 'Reserve Capacity',
                        style: const TextStyle(
                          fontFamily: _fontMono,
                          fontSize: 10,
                          color: Color(0xFF94A3B8),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // Segmented Layer Block Visualizer
              SizedBox(
                height: 10,
                child: CustomPaint(
                  size: const Size(double.infinity, 10),
                  painter: _LayerBlockBarPainter(
                    fillFraction: slice.memoryUtilization.clamp(0.0, 1.0),
                    color: color,
                    segments: 24,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
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

/// Renders a glowing neon fill with diagonal sci-fi energy scanlines inside each device chamber.
class _SciFiCoreFillPainter extends CustomPainter {
  final Color color;
  final double pulse;

  _SciFiCoreFillPainter({
    required this.color,
    required this.pulse,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final rect = Offset.zero & size;
    final gradient = LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: [
        color.withValues(alpha: 0.32 + pulse * 0.12),
        color.withValues(alpha: 0.62 + pulse * 0.18),
      ],
    );

    canvas.drawRect(rect, Paint()..shader = gradient.createShader(rect));

    // Diagonal tactical stripes
    final stripePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.10)
      ..strokeWidth = 2.0;

    const spacing = 12.0;
    for (double x = -size.height; x < size.width + size.height; x += spacing) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + size.height, 0),
        stripePaint,
      );
    }

    // Glowing leading edge bar
    final edgePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.75)
      ..strokeWidth = 2.0;
    canvas.drawLine(
      Offset(size.width - 1, 0),
      Offset(size.width - 1, size.height),
      edgePaint,
    );
  }

  @override
  bool shouldRepaint(covariant _SciFiCoreFillPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.pulse != pulse;
}

/// Draws a segmented sci-fi block gauge representing memory cells on a device.
class _LayerBlockBarPainter extends CustomPainter {
  final double fillFraction;
  final Color color;
  final int segments;

  _LayerBlockBarPainter({
    required this.fillFraction,
    required this.color,
    this.segments = 24,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const gap = 3.0;
    final totalGap = gap * (segments - 1);
    final segWidth = math.max(2.0, (size.width - totalGap) / segments);
    final activeSegments = (fillFraction * segments).ceil();

    for (var i = 0; i < segments; i++) {
      final left = i * (segWidth + gap);
      final rrect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, 0, segWidth, size.height),
        const Radius.circular(2.5),
      );
      final isFilled = i < activeSegments && fillFraction > 0;
      final paint = Paint()
        ..color = isFilled
            ? color.withValues(alpha: 0.85)
            : Colors.white.withValues(alpha: 0.08);
      canvas.drawRRect(rrect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _LayerBlockBarPainter oldDelegate) =>
      oldDelegate.fillFraction != fillFraction || oldDelegate.color != color;
}
