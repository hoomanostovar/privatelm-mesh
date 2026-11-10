import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' show IconData, Icons;
import 'package:get/get.dart';

import '../models/hardware_acceleration.dart';
import 'device_info_native.dart' if (dart.library.html) 'device_info_web.dart'
    as platform_info;

/// Device capability detection — reads RAM and GPU to set safe inference limits.
/// Cross-platform: works on Windows, macOS, Linux, Android, iOS, and Web.
class DeviceInfoService extends GetxService {
  final totalRamGB = 0.0.obs;
  final availableRamGB = 0.0.obs;
  final deviceTier = ''.obs; // 'low', 'mid', 'high', 'ultra'
  final isTensorSoC = false.obs;
  final socFamily = platform_info.SocFamily.unknown.obs;
  final socHardware = ''.obs;
  final gpuName = ''.obs;
  final gpuVramGB = 0.0.obs;
  final deviceType = 'PC'.obs;

  /// All detected video cards on the system (e.g. discrete RTX + integrated Iris/Radeon).
  final gpus = <GpuDeviceInfo>[].obs;

  /// Detected CPU architecture and instruction set acceleration features.
  final cpuInfo = Rxn<CpuDeviceInfo>();

  /// Optimal compute backend calculated for this machine's hardware.
  ComputeBackend get recommendedBackend {
    if (kIsWeb) return ComputeBackend.auto;
    if (Platform.isMacOS || Platform.isIOS) return ComputeBackend.metal;
    if (Platform.isAndroid) return ComputeBackend.vulkan;

    // Check detected discrete GPUs
    for (final gpu in gpus) {
      if (gpu.vendor == GpuVendor.nvidia) {
        return ComputeBackend.cuda;
      }
      if (gpu.vendor == GpuVendor.amd && gpu.isDiscrete) {
        return ComputeBackend.rocm;
      }
    }

    // Check for any GPU with Vulkan/DirectML support
    if (gpus.isNotEmpty) {
      if (Platform.isWindows) {
        return ComputeBackend.directml;
      }
      return ComputeBackend.vulkan;
    }

    // Fall back to CPU SIMD
    final cpu = cpuInfo.value;
    if (cpu != null) {
      return cpu.optimalCpuBackend;
    }
    return ComputeBackend.cpuAvx2;
  }

  IconData get deviceIcon {
    if (kIsWeb) return Icons.language_rounded;
    if (Platform.isWindows) return Icons.desktop_windows_rounded;
    if (Platform.isMacOS) return Icons.laptop_mac_rounded;
    if (Platform.isLinux) return Icons.terminal_rounded;
    return Icons.smartphone_rounded;
  }

  String get deviceNoun {
    if (kIsWeb) return 'browser';
    if (Platform.isWindows) return 'PC';
    if (Platform.isMacOS) return 'Mac';
    if (Platform.isLinux) return 'Linux';
    return 'phone';
  }

  // Recommended limits based on device RAM
  int get recommendedContextSize => _tierConfig['contextSize']!;
  int get recommendedMaxTokens => _tierConfig['maxTokens']!;
  int get maxSafeContextSize => _tierConfig['maxContextSize']!;
  int get maxSafeTokens => _tierConfig['maxSafeTokens']!;

  Map<String, int> get _tierConfig {
    final ram = totalRamGB.value;
    if (ram <= 4) {
      return {
        'contextSize': 1024,
        'maxTokens': 256,
        'maxContextSize': 2048,
        'maxSafeTokens': 512,
      };
    } else if (ram <= 6) {
      return {
        'contextSize': 2048,
        'maxTokens': 512,
        'maxContextSize': 4096,
        'maxSafeTokens': 1024,
      };
    } else if (ram <= 8) {
      return {
        'contextSize': 4096,
        'maxTokens': 1024,
        'maxContextSize': 8192,
        'maxSafeTokens': 2048,
      };
    } else if (ram <= 12) {
      return {
        'contextSize': 4096,
        'maxTokens': 2048,
        'maxContextSize': 8192,
        'maxSafeTokens': 4096,
      };
    } else {
      return {
        'contextSize': 8192,
        'maxTokens': 4096,
        'maxContextSize': 16384,
        'maxSafeTokens': 4096,
      };
    }
  }

  Future<DeviceInfoService> init() async {
    await refreshMemoryInfo();

    // Classify device tier
    final ram = totalRamGB.value;
    if (ram <= 4) {
      deviceTier.value = 'low';
    } else if (ram <= 6) {
      deviceTier.value = 'mid';
    } else if (ram <= 8) {
      deviceTier.value = 'high';
    } else {
      deviceTier.value = 'ultra';
    }

    print('[DeviceInfo] RAM: ${totalRamGB.value.toStringAsFixed(1)}GB total, '
        '${availableRamGB.value.toStringAsFixed(1)}GB available, '
        'tier: ${deviceTier.value}, tensor: ${isTensorSoC.value}');
    return this;
  }

  Future<void> refreshMemoryInfo() async {
    final info = await platform_info.getDeviceInfo();
    totalRamGB.value = (info['totalRamGB'] as num).toDouble();
    availableRamGB.value = (info['availableRamGB'] as num).toDouble();
    isTensorSoC.value = (info['isTensorSoC'] as num? ?? 0.0) > 0.5;
    final rawIndex = (info['socFamily'] as num? ?? 8).toInt();
    final clamped = rawIndex < 0 ? 0 : (rawIndex > 8 ? 8 : rawIndex);
    socFamily.value = platform_info.SocFamily.values[clamped];
    socHardware.value = (info['socHardware'] as String?) ?? '';
    gpuName.value = (info['gpuName'] as String?) ?? '';
    gpuVramGB.value = ((info['gpuVramGB'] as num?) ?? 0.0).toDouble();
    deviceType.value = (info['deviceType'] as String?) ?? (kIsWeb ? 'Web' : Platform.isWindows ? 'PC' : 'Phone');

    // Populate all discovered GPUs
    final rawGpus = info['gpus'] as List?;
    if (rawGpus != null && rawGpus.isNotEmpty) {
      gpus.assignAll(rawGpus.whereType<Map>().map(GpuDeviceInfo.fromMap));
    } else if (gpuName.value.isNotEmpty) {
      var vendor = GpuVendor.other;
      final lower = gpuName.value.toLowerCase();
      if (lower.contains('nvidia') || lower.contains('geforce') || lower.contains('rtx')) {
        vendor = GpuVendor.nvidia;
      } else if (lower.contains('amd') || lower.contains('radeon')) {
        vendor = GpuVendor.amd;
      } else if (lower.contains('intel')) {
        vendor = GpuVendor.intel;
      } else if (lower.contains('apple')) {
        vendor = GpuVendor.apple;
      }
      gpus.assignAll([
        GpuDeviceInfo(
          name: gpuName.value,
          vendor: vendor,
          vramGB: gpuVramGB.value,
          supportedBackends: vendor.supportedBackends,
        ),
      ]);
    }

    // Populate CPU info
    final rawCpu = info['cpuInfo'] as Map?;
    if (rawCpu != null) {
      cpuInfo.value = CpuDeviceInfo(
        name: (rawCpu['name'] as String?) ?? 'CPU',
        cores: (rawCpu['cores'] as num?)?.toInt() ?? Platform.numberOfProcessors,
        threads: (rawCpu['threads'] as num?)?.toInt() ?? Platform.numberOfProcessors,
        hasAvx2: (rawCpu['hasAvx2'] as bool?) ?? true,
        hasAvx512: (rawCpu['hasAvx512'] as bool?) ?? false,
        hasAmx: (rawCpu['hasAmx'] as bool?) ?? false,
        hasNeon: (rawCpu['hasNeon'] as bool?) ?? false,
      );
    }
  }

  String get tierDescription {
    final noun = deviceNoun;
    final gpuSuffix = gpuName.value.isNotEmpty ? ' · GPU: ${gpuName.value}' : '';
    switch (deviceTier.value) {
      case 'low':
        return '⚠️ Low RAM (${totalRamGB.value.toStringAsFixed(1)}GB) — Use small models only$gpuSuffix';
      case 'mid':
        return '⚡ Mid-range (${totalRamGB.value.toStringAsFixed(1)}GB) — Good for 1-3B models$gpuSuffix';
      case 'high':
        return '💪 High-end (${totalRamGB.value.toStringAsFixed(1)}GB) — Can run 3-7B models$gpuSuffix';
      case 'ultra':
        return '🚀 Ultra $noun (${totalRamGB.value.toStringAsFixed(1)}GB) — Full performance mode$gpuSuffix';
      default:
        return '💻 ${totalRamGB.value.toStringAsFixed(1)}GB RAM detected$gpuSuffix';
    }
  }
}
