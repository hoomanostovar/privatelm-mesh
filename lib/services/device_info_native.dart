import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

import 'package:llama_flutter_android/llama_flutter_android.dart';

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

      // Query native Windows GPU via registry (instant, ~5ms)
      try {
        for (var i = 0; i < 4; i++) {
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
              if (candidate.isNotEmpty && !candidate.toLowerCase().contains('virtual') && !candidate.toLowerCase().contains('basic render')) {
                gpuName = candidate;
                // Query VRAM
                final vramResult = Process.runSync('reg', [
                  'query',
                  'HKLM\\SYSTEM\\CurrentControlSet\\Control\\Class\\{4d36e968-e325-11ce-bfc1-08002be10318}\\$idx',
                  '/v',
                  'HardwareInformation.MemorySize',
                ]);
                if (vramResult.exitCode == 0) {
                  final vramMatch = RegExp(r'HardwareInformation\.MemorySize\s+REG_DWORD\s+0x([0-9a-fA-F]+)')
                      .firstMatch(vramResult.stdout.toString());
                  if (vramMatch != null) {
                    final bytes = int.tryParse(vramMatch.group(1)!, radix: 16) ?? 0;
                    gpuVramGB = bytes / (1024 * 1024 * 1024);
                  }
                }
                break;
              }
            }
          }
        }
      } catch (_) {}

      // Fallback to CIM if registry wasn't resolved
      if (gpuName.isEmpty) {
        try {
          final res = Process.runSync('powershell', [
            '-NoProfile',
            '-Command',
            '(Get-CimInstance Win32_VideoController | Select-Object -First 1).Name'
          ]);
          if (res.exitCode == 0 && res.stdout.toString().trim().isNotEmpty) {
            gpuName = res.stdout.toString().trim();
          }
        } catch (_) {}
      }
      socFamily = SocFamily.unknown;
    } else if (Platform.isMacOS) {
      deviceType = 'Mac';
      totalRam = 16.0;
      availableRam = 8.0;
      socFamily = SocFamily.apple;
      try {
        final res = Process.runSync('sysctl', ['-n', 'machdep.cpu.brand_string']);
        if (res.exitCode == 0) hardware = res.stdout.toString().trim();
      } catch (_) {}
      try {
        final res = Process.runSync('system_profiler', ['SPDisplaysDataType']);
        final match = RegExp(r'Chipset Model:\s+(.+)').firstMatch(res.stdout.toString());
        gpuName = match != null ? match.group(1)!.trim() : 'Apple Metal GPU';
      } catch (_) {
        gpuName = 'Apple Metal GPU';
      }
      gpuVramGB = totalRam;
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
        final res = Process.runSync('lspci', []);
        for (final line in res.stdout.toString().split('\n')) {
          if (line.toLowerCase().contains('vga compatible controller') ||
              line.toLowerCase().contains('3d controller')) {
            gpuName = line.split(':').last.trim();
            break;
          }
        }
      } catch (_) {}
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
    } else if (Platform.isIOS) {
      deviceType = 'iPhone';
      final plugin = LlamaHostApi();
      final gpuInfo = await plugin.detectGpu();
      totalRam = gpuInfo.deviceLocalMemoryBytes / (1024 * 1024 * 1024);
      availableRam = gpuInfo.freeRamBytes / (1024 * 1024 * 1024);
      gpuName = gpuInfo.gpuName;
      gpuVramGB = gpuInfo.deviceLocalMemoryBytes / (1024 * 1024 * 1024);
      socFamily = SocFamily.apple;
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
  };
}
