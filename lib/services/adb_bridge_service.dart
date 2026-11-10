import 'dart:async';
import 'dart:io';
import 'package:get/get.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';

/// Information about a physical USB-connected Android device via ADB.
class AdbUsbDevice {
  final String serial;
  final String model;
  final String product;
  final String device;
  final String state;
  final int localPort;
  final bool isForwarded;

  const AdbUsbDevice({
    required this.serial,
    required this.model,
    required this.product,
    required this.device,
    required this.state,
    this.localPort = 50052,
    this.isForwarded = false,
  });

  String get displayName => model.isNotEmpty ? model.replaceAll('_', ' ') : serial;

  AdbUsbDevice copyWith({int? localPort, bool? isForwarded}) => AdbUsbDevice(
        serial: serial,
        model: model,
        product: product,
        device: device,
        state: state,
        localPort: localPort ?? this.localPort,
        isForwarded: isForwarded ?? this.isForwarded,
      );
}

/// Service that automates USB clustering via Android Debug Bridge (ADB).
///
/// When an Android phone is connected to the PC via USB-C cable (directly or
/// through a USB hub), ADB reverse or forward port forwarding creates an
/// ultra-low-latency (<0.5ms) and high-throughput (480 Mbps to 10 Gbps)
/// transport tunnel, bypassing Wi-Fi jitter completely.
class AdbBridgeService extends GetxService {
  final isAdbAvailable = false.obs;
  final usbDevices = <AdbUsbDevice>[].obs;
  final isScanning = false.obs;
  String _adbPath = 'adb';

  static const int basePort = 50052;

  @override
  void onInit() {
    super.onInit();
    if (!Platform.isAndroid && !Platform.isIOS) {
      _checkAdbAvailable().then((available) {
        if (available) {
          scanUsbDevices();
        }
      });
    }
  }

  /// Check whether `adb` is present in PATH or standard SDK locations.
  Future<bool> _checkAdbAvailable() async {
    final candidatePaths = [
      'adb',
      if (Platform.isWindows) ...[
        '${Platform.environment['LOCALAPPDATA']}\\Android\\Sdk\\platform-tools\\adb.exe',
        'C:\\Android\\platform-tools\\adb.exe',
        'C:\\platform-tools\\adb.exe',
      ] else ...[
        '${Platform.environment['HOME']}/Library/Android/sdk/platform-tools/adb',
        '${Platform.environment['HOME']}/Android/Sdk/platform-tools/adb',
        '/usr/bin/adb',
        '/usr/local/bin/adb',
      ],
    ];

    for (final path in candidatePaths) {
      try {
        final result = await Process.run(path, ['version']).timeout(
          const Duration(seconds: 2),
          onTimeout: () => ProcessResult(-1, -1, '', 'timeout'),
        );
        if (result.exitCode == 0) {
          _adbPath = path;
          isAdbAvailable.value = true;
          return true;
        }
      } catch (_) {}
    }

    isAdbAvailable.value = false;
    return false;
  }

  /// Enumerate USB-connected devices using `adb devices -l`.
  Future<List<AdbUsbDevice>> scanUsbDevices() async {
    if (!isAdbAvailable.value) {
      final found = await _checkAdbAvailable();
      if (!found) return const [];
    }

    isScanning.value = true;
    try {
      final res = await Process.run(_adbPath, ['devices', '-l']).timeout(
        const Duration(seconds: 4),
        onTimeout: () => ProcessResult(-1, -1, '', 'timeout'),
      );
      if (res.exitCode != 0) return const [];

      final lines = res.stdout.toString().split('\n');
      final list = <AdbUsbDevice>[];
      var portOffset = 0;

      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty ||
            trimmed.startsWith('List of devices attached') ||
            trimmed.startsWith('* daemon')) {
          continue;
        }

        // Format: <serial> <state> product:<prod> model:<model> device:<dev>
        final parts = trimmed.split(RegExp(r'\s+'));
        if (parts.length < 2) continue;

        final serial = parts[0];
        final state = parts[1];
        if (state != 'device') continue;

        // Skip network ADB connections (e.g. 192.168.x.x:5555) to focus on USB
        if (serial.contains(':') && !serial.startsWith('usb')) {
          // IP-based wireless ADB, not direct USB
          continue;
        }

        var model = '';
        var product = '';
        var device = '';

        for (final p in parts.skip(2)) {
          if (p.startsWith('model:')) model = p.substring(6);
          if (p.startsWith('product:')) product = p.substring(8);
          if (p.startsWith('device:')) device = p.substring(7);
        }

        final assignedPort = basePort + portOffset;
        portOffset++;

        list.add(AdbUsbDevice(
          serial: serial,
          model: model.isNotEmpty ? model : serial,
          product: product,
          device: device,
          state: state,
          localPort: assignedPort,
          isForwarded: false,
        ));
      }

      usbDevices.assignAll(list);
      return list;
    } catch (_) {
      return const [];
    } finally {
      isScanning.value = false;
    }
  }

  /// Forward local TCP port to the remote phone's cluster worker port over USB cable.
  Future<bool> forwardDevicePort(AdbUsbDevice device, {int remotePort = 50052}) async {
    if (!isAdbAvailable.value) return false;

    try {
      final res = await Process.run(_adbPath, [
        '-s',
        device.serial,
        'forward',
        'tcp:${device.localPort}',
        'tcp:$remotePort',
      ]);

      if (res.exitCode == 0) {
        final idx = usbDevices.indexWhere((d) => d.serial == device.serial);
        if (idx >= 0) {
          usbDevices[idx] = usbDevices[idx].copyWith(isForwarded: true);
        }
        print('[AdbBridge] Port forwarded: localhost:${device.localPort} -> ${device.displayName}:$remotePort (USB ⚡)');
        return true;
      }
    } catch (e) {
      print('[AdbBridge] Failed to forward port for ${device.serial}: $e');
    }
    return false;
  }

  /// Remove port forwarding for a device.
  Future<void> removeForward(AdbUsbDevice device) async {
    if (!isAdbAvailable.value) return;
    try {
      await Process.run(_adbPath, [
        '-s',
        device.serial,
        'forward',
        '--remove',
        'tcp:${device.localPort}',
      ]);
      final idx = usbDevices.indexWhere((d) => d.serial == device.serial);
      if (idx >= 0) {
        usbDevices[idx] = usbDevices[idx].copyWith(isForwarded: false);
      }
    } catch (_) {}
  }

  /// Create a `ClusterWorker` object for an active USB-forwarded phone.
  ClusterWorker toClusterWorker(AdbUsbDevice device) {
    return ClusterWorker(
      name: '${device.displayName} (USB ⚡)',
      host: '127.0.0.1',
      port: device.localPort,
      ramMb: 8000, // Safe default estimated RAM for mobile cluster worker
      bandwidth: 12.0, // Sub-millisecond latency USB 3.x throughput estimate (GB/s equivalent)
      model: device.model,
      id: 'usb_${device.serial}',
    );
  }
}
