import 'package:flutter/material.dart' show IconData, Icons;

/// Hardware acceleration compute backend options.
enum ComputeBackend {
  /// Automatic best backend based on detected hardware.
  auto,

  /// NVIDIA CUDA (MSVC / Clang with CUDA, Tensor Cores, Flash Attention).
  cuda,

  /// AMD ROCm / HIP (Windows & Linux, Matrix Cores, RDNA/CDNA).
  rocm,

  /// Khronos Vulkan 1.3 (Cross-Vendor GPU: NVIDIA, AMD Radeon, Intel Arc, Adreno, Mali).
  vulkan,

  /// Microsoft DirectX 12 DirectML (Universal Windows GPU: AMD, Intel, NVIDIA).
  directml,

  /// Apple Metal (Clang with Metal, unified memory zero-copy).
  metal,

  /// CPU with AVX-512 / Intel AMX matrix vectorization.
  cpuAvx512,

  /// CPU with AVX2 / FMA vectorization (Universal x86_64).
  cpuAvx2,

  /// CPU with ARM NEON / FP16 vectorization (Universal ARM64).
  cpuNeon,
}

extension ComputeBackendExt on ComputeBackend {
  String get id {
    switch (this) {
      case ComputeBackend.auto:
        return 'auto';
      case ComputeBackend.cuda:
        return 'cuda';
      case ComputeBackend.rocm:
        return 'rocm';
      case ComputeBackend.vulkan:
        return 'vulkan';
      case ComputeBackend.directml:
        return 'directml';
      case ComputeBackend.metal:
        return 'metal';
      case ComputeBackend.cpuAvx512:
        return 'cpu_avx512';
      case ComputeBackend.cpuAvx2:
        return 'cpu_avx2';
      case ComputeBackend.cpuNeon:
        return 'cpu_neon';
    }
  }

  String get displayName {
    switch (this) {
      case ComputeBackend.auto:
        return 'Auto (Fastest Detected)';
      case ComputeBackend.cuda:
        return 'NVIDIA CUDA';
      case ComputeBackend.rocm:
        return 'AMD ROCm / HIP';
      case ComputeBackend.vulkan:
        return 'Vulkan 1.3 (Universal GPU)';
      case ComputeBackend.directml:
        return 'DirectX 12 DirectML';
      case ComputeBackend.metal:
        return 'Apple Metal (Unified Memory)';
      case ComputeBackend.cpuAvx512:
        return 'CPU AVX-512 / AMX';
      case ComputeBackend.cpuAvx2:
        return 'CPU AVX2 / FMA';
      case ComputeBackend.cpuNeon:
        return 'CPU ARM NEON';
    }
  }

  String get description {
    switch (this) {
      case ComputeBackend.auto:
        return 'Automatically selects the most performant GPU or vector engine available.';
      case ComputeBackend.cuda:
        return 'MSVC / Clang with CUDA for NVIDIA GeForce, RTX, and Quadro GPUs.';
      case ComputeBackend.rocm:
        return 'ROCm / HIP acceleration for AMD Radeon and Instinct GPUs on Windows & Linux.';
      case ComputeBackend.vulkan:
        return 'Cross-platform Khronos Vulkan 1.3 for AMD, Intel Arc, NVIDIA, Adreno & Mali.';
      case ComputeBackend.directml:
        return 'Microsoft DirectML universal GPU acceleration across AMD, Intel, and NVIDIA.';
      case ComputeBackend.metal:
        return 'Clang with Metal for Apple Silicon M-series integrated GPU and unified memory.';
      case ComputeBackend.cpuAvx512:
        return '512-bit SIMD & AMX matrix tile acceleration for modern Intel & AMD CPUs.';
      case ComputeBackend.cpuAvx2:
        return '256-bit SIMD vectorization for standard x86_64 desktop and laptop CPUs.';
      case ComputeBackend.cpuNeon:
        return '128-bit ARM NEON vectorization for Snapdragon, Apple Silicon, and ARM64 SoCs.';
    }
  }

  IconData get icon {
    switch (this) {
      case ComputeBackend.auto:
        return Icons.auto_awesome_rounded;
      case ComputeBackend.cuda:
        return Icons.bolt_rounded;
      case ComputeBackend.rocm:
        return Icons.developer_board_rounded;
      case ComputeBackend.vulkan:
        return Icons.local_fire_department_rounded;
      case ComputeBackend.directml:
        return Icons.window_rounded;
      case ComputeBackend.metal:
        return Icons.apple_rounded;
      case ComputeBackend.cpuAvx512:
      case ComputeBackend.cpuAvx2:
      case ComputeBackend.cpuNeon:
        return Icons.memory_rounded;
    }
  }

  bool get isGpu =>
      this == ComputeBackend.cuda ||
      this == ComputeBackend.rocm ||
      this == ComputeBackend.vulkan ||
      this == ComputeBackend.directml ||
      this == ComputeBackend.metal;

  static ComputeBackend fromString(String? val) {
    if (val == null) return ComputeBackend.auto;
    for (final b in ComputeBackend.values) {
      if (b.id == val || b.name == val) return b;
    }
    return ComputeBackend.auto;
  }
}

/// GPU Vendor Classification.
enum GpuVendor {
  nvidia,
  amd,
  intel,
  apple,
  qualcomm,
  arm,
  other,
}

extension GpuVendorExt on GpuVendor {
  String get displayName {
    switch (this) {
      case GpuVendor.nvidia:
        return 'NVIDIA';
      case GpuVendor.amd:
        return 'AMD Radeon';
      case GpuVendor.intel:
        return 'Intel';
      case GpuVendor.apple:
        return 'Apple';
      case GpuVendor.qualcomm:
        return 'Qualcomm Adreno';
      case GpuVendor.arm:
        return 'ARM Mali';
      case GpuVendor.other:
        return 'Generic GPU';
    }
  }

  List<ComputeBackend> get supportedBackends {
    switch (this) {
      case GpuVendor.nvidia:
        return [ComputeBackend.cuda, ComputeBackend.vulkan, ComputeBackend.directml];
      case GpuVendor.amd:
        return [ComputeBackend.rocm, ComputeBackend.vulkan, ComputeBackend.directml];
      case GpuVendor.intel:
        return [ComputeBackend.vulkan, ComputeBackend.directml];
      case GpuVendor.apple:
        return [ComputeBackend.metal];
      case GpuVendor.qualcomm:
      case GpuVendor.arm:
        return [ComputeBackend.vulkan];
      case GpuVendor.other:
        return [ComputeBackend.vulkan, ComputeBackend.directml];
    }
  }
}

/// Discovered GPU Device Information.
class GpuDeviceInfo {
  final String name;
  final GpuVendor vendor;
  final double vramGB;
  final String driverVersion;
  final bool isDiscrete;
  final List<ComputeBackend> supportedBackends;

  const GpuDeviceInfo({
    required this.name,
    required this.vendor,
    required this.vramGB,
    this.driverVersion = '',
    this.isDiscrete = true,
    this.supportedBackends = const [],
  });

  Map<String, dynamic> toMap() => {
        'name': name,
        'vendor': vendor.name,
        'vramGB': vramGB,
        'driverVersion': driverVersion,
        'isDiscrete': isDiscrete,
        'supportedBackends': supportedBackends.map((b) => b.id).toList(),
      };

  factory GpuDeviceInfo.fromMap(Map<dynamic, dynamic> map) {
    final vStr = map['vendor'] as String? ?? 'other';
    final vendor = GpuVendor.values.firstWhere(
      (v) => v.name == vStr,
      orElse: () => GpuVendor.other,
    );
    final rawBackends = (map['supportedBackends'] as List?)?.cast<String>() ?? [];
    return GpuDeviceInfo(
      name: map['name'] as String? ?? 'Unknown GPU',
      vendor: vendor,
      vramGB: ((map['vramGB'] as num?) ?? 0.0).toDouble(),
      driverVersion: map['driverVersion'] as String? ?? '',
      isDiscrete: map['isDiscrete'] as bool? ?? true,
      supportedBackends: rawBackends.map(ComputeBackendExt.fromString).toList(),
    );
  }
}

/// Discovered CPU Acceleration Information.
class CpuDeviceInfo {
  final String name;
  final int cores;
  final int threads;
  final bool hasAvx2;
  final bool hasAvx512;
  final bool hasAmx;
  final bool hasNeon;

  const CpuDeviceInfo({
    required this.name,
    required this.cores,
    required this.threads,
    this.hasAvx2 = true,
    this.hasAvx512 = false,
    this.hasAmx = false,
    this.hasNeon = false,
  });

  ComputeBackend get optimalCpuBackend {
    if (hasNeon) return ComputeBackend.cpuNeon;
    if (hasAvx512) return ComputeBackend.cpuAvx512;
    if (hasAvx2) return ComputeBackend.cpuAvx2;
    return ComputeBackend.cpuAvx2;
  }

  String get simdSummary {
    final flags = <String>[];
    if (hasAmx) flags.add('AMX');
    if (hasAvx512) flags.add('AVX-512');
    if (hasAvx2) flags.add('AVX2');
    if (hasNeon) flags.add('ARM NEON');
    if (flags.isEmpty) flags.add('Standard SIMD');
    return flags.join(' · ');
  }
}
