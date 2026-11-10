import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

import 'package:llama_flutter_android/llama_flutter_android.dart';
import '../models/hardware_acceleration.dart';

/// Detected SoC family.
enum SocFamily {
  apple,
  snapdragon,
  mediatek,
  exynos,
  googleTensor,
  unisoc,
  rockchip,
  hisilicon,
  unknown,
}

extension SocFamilyExt on SocFamily {
  String get displayName {
    switch (this) {
      case SocFamily.apple:
        return 'Apple Silicon';
      case SocFamily.snapdragon:
        return 'Qualcomm Snapdragon';
      case SocFamily.mediatek:
        return 'MediaTek Dimensity';
      case SocFamily.exynos:
        return 'Samsung Exynos';
      case SocFamily.googleTensor:
        return 'Google Tensor';
      case SocFamily.unisoc:
        return 'Unisoc';
      case SocFamily.rockchip:
        return 'Rockchip';
      case SocFamily.hisilicon:
        return 'Huawei Kirin';
      case SocFamily.unknown:
        return 'Unknown';
    }
  }

  String get recommendedQuant {
    switch (this) {
      case SocFamily.apple:
        return 'Q4_K_M (safe default) · Q5_K_M for quality';
      case SocFamily.snapdragon:
        return 'Q4_K_M (recommended) · Q4_0_4_8 on X Elite';
      case SocFamily.mediatek:
        return 'Q4_K_M (recommended)';
      case SocFamily.exynos:
        return 'Q4_K_M (recommended)';
      case SocFamily.googleTensor:
        return 'Q4_0 or Q5_K_M · AVOID Q4_K_M';
      case SocFamily.unisoc:
        return 'Q4_K_M (recommended)';
      case SocFamily.rockchip:
        return 'Q4_K_M (recommended)';
      case SocFamily.hisilicon:
        return 'Q4_K_M (recommended)';
      case SocFamily.unknown:
        return 'Q4_K_M (universal default)';
    }
  }

  String? get quantWarning {
    switch (this) {
      case SocFamily.googleTensor:
        return 'Google Tensor has a known bug with Q4_K_M quantization that produces empty or garbled responses. Use Q4_0 or Q5_K_M models instead.';
      default:
        return null;
    }
  }
}

SocFamily _detectSocFamily(String cpuinfo, String hardware) {
  final lower = cpuinfo.toLowerCase();
  final hwLower = hardware.toLowerCase();

  // Google Tensor (Pixel 6/7/8/9)
  if (RegExp(r'gs\d{3}').hasMatch(hwLower) ||
      lower.contains('google tensor')) {
    return SocFamily.googleTensor;
  }

  // Qualcomm Snapdragon
  if (hwLower.contains('qcom') ||
      hwLower.contains('qualcomm') ||
      hwLower.contains('snapdragon') ||
      RegExp(r'\bsm\d{4,}').hasMatch(hwLower) ||
      lower.contains('snapdragon')) {
    return SocFamily.snapdragon;
  }

  // MediaTek Dimensity / Helio
  if (hwLower.contains('mt6') ||
      hwLower.contains('mt8') ||
      lower.contains('mediatek') ||
      lower.contains('dimensity') ||
      lower.contains('helio')) {
    return SocFamily.mediatek;
  }

  // Samsung Exynos
  if (hwLower.contains('exynos') || lower.contains('exynos')) {
    return SocFamily.exynos;
  }

  // Unisoc
  if (hwLower.contains('unisoc') ||
      hwLower.contains('spreadtrum') ||
      RegExp(r'\bsc\d{4}').hasMatch(hwLower)) {
    return SocFamily.unisoc;
  }

  // Rockchip
  if (hwLower.contains('rockchip') || RegExp(r'\brk\d').hasMatch(hwLower)) {
    return SocFamily.rockchip;
  }

  // Huawei Hisilicon / Kirin
  if (hwLower.contains('hisilicon') ||
      lower.contains('kirin') ||
      lower.contains('hisi')) {
    return SocFamily.hisilicon;
  }

  // Apple (iOS path doesn't hit this, but keep for completeness)
  if (lower.contains('apple')) {
    return SocFamily.apple;
  }

  return SocFamily.unknown;
}

/// Native (Windows/macOS/Linux/Android/iOS) device info implementation.
Future<Map<String, dynamic>> getDeviceInfo() async {
  double totalRam = 4.0;
  double availableRam = 2.0;
  SocFamily socFamily = SocFamily.unknown;
  String hardware = '';
  String gpuName = '';
  double gpuVramGB = 0.0;
  String deviceType = 'Phone';
  final List<Map<String, dynamic>> gpus = [];
  Map<String, dynamic> cpuInfo = {
    'name': 'CPU',
    'cores': Platform.numberOfProcessors,
    'threads': Platform.numberOfProcessors,
    'hasAvx2': true,
    'hasAvx512': false,
    'hasAmx': false,
    'hasNeon': Platform.isMacOS || Platform.isAndroid || Platform.isIOS,
  };

  try {
    if (Platform.isWindows) {
      deviceType = 'PC';
      try {
        final kernel32 = DynamicLibrary.open('kernel32.dll');
        final globalMemoryStatusEx = kernel32.lookupFunction<
            Int32 Function(Pointer<Uint8>),
            int Function(Pointer<Uint8>)>('GlobalMemoryStatusEx');
        final buffer = calloc<Uint8>(64);
        buffer.cast<Uint32>().value = 64; // dwLength
        if (globalMemoryStatusEx(buffer) != 0) {
          final totalPhysBytes = (buffer + 8).cast<Uint64>().value;
          final availPhysBytes = (buffer + 16).cast<Uint64>().value;
          totalRam = totalPhysBytes / (1024 * 1024 * 1024);
          availableRam = availPhysBytes / (1024 * 1024 * 1024);
        }
        calloc.free(buffer);
      } catch (_) {
        totalRam = 16.0;
        availableRam = 8.0;
      }

      // Query Windows CIM for all video controllers
      try {
        final res = Process.runSync('powershell', [
          '-NoProfile',
          '-Command',
          'Get-CimInstance Win32_VideoController | Select-Object Name, AdapterRAM, DriverVersion, PNPDeviceID | ConvertTo-Json -Compress'
        ]);
        if (res.exitCode == 0 && res.stdout.toString().trim().isNotEmpty) {
          final out = res.stdout.toString().trim();
          final List<dynamic> items = out.startsWith('[')
              ? jsonDecode(out)
              : [jsonDecode(out)];

          for (final item in items) {
            final name = (item['Name'] as String?)?.trim() ?? '';
            if (name.isEmpty ||
                name.toLowerCase().contains('virtual') ||
                name.toLowerCase().contains('basic render')) {
              continue;
            }

            final pnp = (item['PNPDeviceID'] as String?)?.toUpperCase() ?? '';
            final rawBytes = (item['AdapterRAM'] as num?)?.toDouble() ?? 0.0;
            // Handle signed 32-bit overflow in AdapterRAM (e.g. 4GB becomes negative or 0)
            final vram = rawBytes > 0 ? rawBytes / (1024 * 1024 * 1024) : 4.0;
            final driver = (item['DriverVersion'] as String?) ?? '';

            var vendor = GpuVendor.other;
            if (pnp.contains('VEN_10DE') || name.toLowerCase().contains('nvidia')) {
              vendor = GpuVendor.nvidia;
            } else if (pnp.contains('VEN_1002') || name.toLowerCase().contains('amd') || name.toLowerCase().contains('radeon')) {
              vendor = GpuVendor.amd;
            } else if (pnp.contains('VEN_8086') || name.toLowerCase().contains('intel')) {
              vendor = GpuVendor.intel;
            }

            final gpuObj = GpuDeviceInfo(
              name: name,
              vendor: vendor,
              vramGB: vram,
              driverVersion: driver,
              isDiscrete: vendor == GpuVendor.nvidia || (vendor == GpuVendor.amd && !name.toLowerCase().contains('graphics')),
              supportedBackends: vendor.supportedBackends,
            );
            gpus.add(gpuObj.toMap());
          }
        }
      } catch (_) {}

      // Fallback to registry if CIM was empty
      if (gpus.isEmpty) {
        try {
          for (var i = 0; i < 6; i++) {
            final idx = i.toString().padLeft(4, '0');
            final regResult = Process.runSync('reg', [
              'query',
              'HKLM\\SYSTEM\\CurrentControlSet\\Control\\Class\\{4d36e968-e325-11ce-bfc1-08002be10318}\\$idx',
              '/v',
              'DriverDesc',
            ]);
            if (regResult.exitCode == 0) {
              final match = RegExp(r'DriverDesc\s+REG_SZ\s+(.+)')
                  .firstMatch(regResult.stdout.toString());
              if (match != null) {
                final candidate = match.group(1)!.trim();
                if (candidate.isNotEmpty &&
                    !candidate.toLowerCase().contains('virtual') &&
                    !candidate.toLowerCase().contains('basic render')) {
                  var vendor = GpuVendor.other;
                  if (candidate.toLowerCase().contains('nvidia')) {
                    vendor = GpuVendor.nvidia;
                  } else if (candidate.toLowerCase().contains('amd') || candidate.toLowerCase().contains('radeon')) {
                    vendor = GpuVendor.amd;
                  } else if (candidate.toLowerCase().contains('intel')) {
                    vendor = GpuVendor.intel;
                  }

                  gpus.add(GpuDeviceInfo(
                    name: candidate,
                    vendor: vendor,
                    vramGB: 4.0,
                    supportedBackends: vendor.supportedBackends,
                  ).toMap());
                }
              }
            }
          }
        } catch (_) {}
      }

      // Check CPU info on Windows
      try {
        final cpuRes = Process.runSync('powershell', [
          '-NoProfile',
          '-Command',
          '(Get-CimInstance Win32_Processor | Select-Object -First 1).Name'
        ]);
        if (cpuRes.exitCode == 0 && cpuRes.stdout.toString().trim().isNotEmpty) {
          final cpuName = cpuRes.stdout.toString().trim();
          cpuInfo['name'] = cpuName;
          final lower = cpuName.toLowerCase();
          // AVX-512 detection (Intel 11th+ Gen i7/i9, Xeon, AMD Zen 4/5)
          if (lower.contains('xeon') ||
              lower.contains('zen 4') ||
              lower.contains('zen 5') ||
              RegExp(r'ryzen [79] 7\d{3}').hasMatch(lower) ||
              RegExp(r'ryzen [79] 8\d{3}').hasMatch(lower) ||
              RegExp(r'ryzen [79] 9\d{3}').hasMatch(lower) ||
              RegExp(r'i[79]-1[1234]\d{3}').hasMatch(lower)) {
            cpuInfo['hasAvx512'] = true;
          }
        }
      } catch (_) {}

      // Select primary GPU (prefer discrete NVIDIA / AMD first)
      if (gpus.isNotEmpty) {
        final discrete = gpus.firstWhere(
          (g) => (g['vendor'] == 'nvidia' || g['vendor'] == 'amd') && (g['isDiscrete'] == true),
          orElse: () => gpus.first,
        );
        gpuName = discrete['name'] as String;
        gpuVramGB = (discrete['vramGB'] as num).toDouble();
      }

      socFamily = SocFamily.unknown;
    } else if (Platform.isMacOS) {
      deviceType = 'Mac';
      totalRam = 16.0;
      availableRam = 8.0;
      socFamily = SocFamily.apple;
      var appleGpuName = 'Apple Metal GPU';
      try {
        final res = Process.runSync('sysctl', ['-n', 'machdep.cpu.brand_string']);
        if (res.exitCode == 0) {
          hardware = res.stdout.toString().trim();
          cpuInfo['name'] = hardware;
        }
      } catch (_) {}
      try {
        final res = Process.runSync('system_profiler', ['SPDisplaysDataType']);
        final match = RegExp(r'Chipset Model:\s+(.+)').firstMatch(res.stdout.toString());
        if (match != null) appleGpuName = match.group(1)!.trim();
      } catch (_) {}
      gpuName = appleGpuName;
      gpuVramGB = totalRam;
      gpus.add(GpuDeviceInfo(
        name: appleGpuName,
        vendor: GpuVendor.apple,
        vramGB: totalRam,
        isDiscrete: true,
        supportedBackends: const [ComputeBackend.metal],
      ).toMap());
      cpuInfo['hasNeon'] = true;
    } else if (Platform.isLinux) {
      deviceType = 'Linux PC';
      final meminfo = await File('/proc/meminfo').readAsString();
      final totalMatch = RegExp(r'MemTotal:\s+(\d+)').firstMatch(meminfo);
      if (totalMatch != null) {
        totalRam = int.parse(totalMatch.group(1)!) / 1024 / 1024;
      }
      final availMatch = RegExp(r'MemAvailable:\s+(\d+)').firstMatch(meminfo);
      if (availMatch != null) {
        availableRam = int.parse(availMatch.group(1)!) / 1024 / 1024;
      }

      try {
        final cpuinfo = await File('/proc/cpuinfo').readAsString();
        final modelMatch = RegExp(r'model name\s*:\s*(.+)').firstMatch(cpuinfo);
        if (modelMatch != null) cpuInfo['name'] = modelMatch.group(1)!.trim();
        cpuInfo['hasAvx2'] = cpuinfo.contains('avx2');
        cpuInfo['hasAvx512'] = cpuinfo.contains('avx512f');
        cpuInfo['hasAmx'] = cpuinfo.contains('amx_tile');
        cpuInfo['hasNeon'] = cpuinfo.contains('asimd') || cpuinfo.contains('neon');
      } catch (_) {}

      try {
        final res = Process.runSync('lspci', []);
        for (final line in res.stdout.toString().split('\n')) {
          final lower = line.toLowerCase();
          if (lower.contains('vga compatible controller') || lower.contains('3d controller')) {
            final name = line.split(':').last.trim();
            var vendor = GpuVendor.other;
            if (lower.contains('nvidia')) {
              vendor = GpuVendor.nvidia;
            } else if (lower.contains('amd') || lower.contains('radeon')) {
              vendor = GpuVendor.amd;
            } else if (lower.contains('intel')) {
              vendor = GpuVendor.intel;
            }
            gpus.add(GpuDeviceInfo(
              name: name,
              vendor: vendor,
              vramGB: 8.0,
              isDiscrete: vendor != GpuVendor.intel,
              supportedBackends: vendor.supportedBackends,
            ).toMap());
          }
        }
      } catch (_) {}

      if (gpus.isNotEmpty) {
        gpuName = gpus.first['name'] as String;
        gpuVramGB = (gpus.first['vramGB'] as num).toDouble();
      }
    } else if (Platform.isAndroid) {
      deviceType = 'Android Phone';
      final meminfo = await File('/proc/meminfo').readAsString();
      final totalMatch = RegExp(r'MemTotal:\s+(\d+)').firstMatch(meminfo);
      if (totalMatch != null) {
        totalRam = int.parse(totalMatch.group(1)!) / 1024 / 1024;
      }
      final availMatch = RegExp(r'MemAvailable:\s+(\d+)').firstMatch(meminfo);
      if (availMatch != null) {
        availableRam = int.parse(availMatch.group(1)!) / 1024 / 1024;
      }
      try {
        final cpuinfo = await File('/proc/cpuinfo').readAsString();
        hardware = RegExp(r'Hardware\s*:\s*(.+)', caseSensitive: false)
                .firstMatch(cpuinfo)
                ?.group(1)
                ?.trim() ??
            '';
        socFamily = _detectSocFamily(cpuinfo, hardware);
      } catch (_) {}
      gpuName = socFamily == SocFamily.snapdragon
          ? 'Qualcomm Adreno GPU'
          : socFamily == SocFamily.mediatek
              ? 'ARM Mali / Immortalis GPU'
              : 'Mobile GPU';
      gpuVramGB = totalRam * 0.5;
      gpus.add(GpuDeviceInfo(
        name: gpuName,
        vendor: socFamily == SocFamily.snapdragon ? GpuVendor.qualcomm : GpuVendor.arm,
        vramGB: gpuVramGB,
        isDiscrete: false,
        supportedBackends: const [ComputeBackend.vulkan],
      ).toMap());
      cpuInfo['hasNeon'] = true;
    } else if (Platform.isIOS) {
      deviceType = 'iPhone';
      final plugin = LlamaHostApi();
      final gpuInfo = await plugin.detectGpu();
      totalRam = gpuInfo.deviceLocalMemoryBytes / (1024 * 1024 * 1024);
      availableRam = gpuInfo.freeRamBytes / (1024 * 1024 * 1024);
      gpuName = gpuInfo.gpuName;
      gpuVramGB = gpuInfo.deviceLocalMemoryBytes / (1024 * 1024 * 1024);
      socFamily = SocFamily.apple;
      gpus.add(GpuDeviceInfo(
        name: gpuName,
        vendor: GpuVendor.apple,
        vramGB: gpuVramGB,
        isDiscrete: true,
        supportedBackends: const [ComputeBackend.metal],
      ).toMap());
      cpuInfo['hasNeon'] = true;
    }
  } catch (e) {
    print('[DeviceInfo] Failed to read device info: $e');
  }

  return {
    'totalRamGB': totalRam,
    'availableRamGB': availableRam,
    'isTensorSoC': socFamily == SocFamily.googleTensor ? 1.0 : 0.0,
    'socFamily': socFamily.index,
    'socHardware': hardware,
    'gpuName': gpuName,
    'gpuVramGB': gpuVramGB,
    'deviceType': deviceType,
    'gpus': gpus,
    'cpuInfo': cpuInfo,
  };
}
