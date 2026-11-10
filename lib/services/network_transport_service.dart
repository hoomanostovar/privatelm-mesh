import 'dart:async';
import 'dart:io';
import '../models/transport_type.dart';

/// Service that classifies network transports and benchmarks endpoint latency.
class NetworkTransportService {
  static final NetworkTransportService instance = NetworkTransportService._();
  NetworkTransportService._();

  /// Determine the [TransportType] of an endpoint based on host and system interfaces.
  Future<TransportType> classifyEndpoint(String host) async {
    final cleanHost = host.trim().toLowerCase();

    // Localhost / Loopback tunnels (e.g. ADB reverse or forward port tunnels) are USB
    if (cleanHost == '127.0.0.1' || cleanHost == 'localhost') {
      return TransportType.usb;
    }

    // Common USB Tethering / RNDIS / NCM subnets
    if (cleanHost.startsWith('192.168.42.') ||
        cleanHost.startsWith('192.168.137.') ||
        cleanHost.startsWith('172.20.10.') ||
        cleanHost.startsWith('169.254.')) {
      return TransportType.usb;
    }

    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );

      // Check if target IP falls within an interface's subnet
      for (final iface in interfaces) {
        final ifaceName = iface.name.toLowerCase();
        final hasUsb = ifaceName.contains('usb') ||
            ifaceName.contains('rndis') ||
            ifaceName.contains('ncm') ||
            ifaceName.contains('remote ndis') ||
            ifaceName.contains('apple mobile');
        final hasEth = ifaceName.contains('ethernet') ||
            ifaceName.contains('eth') ||
            ifaceName.contains('enp') ||
            ifaceName.contains('pcie gbe') ||
            ifaceName.contains('802.3') ||
            ifaceName.contains('lan');
        final hasWifi = ifaceName.contains('wi-fi') ||
            ifaceName.contains('wifi') ||
            ifaceName.contains('wlan') ||
            ifaceName.contains('wireless') ||
            ifaceName.contains('802.11');

        for (final addr in iface.addresses) {
          // Same /24 subnet match
          final ifacePrefix = addr.address.substring(0, addr.address.lastIndexOf('.'));
          final targetPrefix = cleanHost.substring(0, cleanHost.lastIndexOf('.'));
          if (ifacePrefix == targetPrefix) {
            if (hasUsb) return TransportType.usb;
            if (hasEth) return TransportType.ethernet;
            if (hasWifi) return TransportType.wifi;
          }
        }
      }
    } catch (_) {}

    return TransportType.unknown;
  }

  /// Measure network round-trip latency in milliseconds to a given TCP endpoint.
  Future<double?> measureLatency(String host, int port, {int timeoutMs = 1500}) async {
    final sw = Stopwatch()..start();
    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: Duration(milliseconds: timeoutMs),
      );
      sw.stop();
      await socket.close();
      final ms = sw.elapsedMicroseconds / 1000.0;
      return ms < 0.1 ? 0.1 : ms;
    } catch (_) {
      return null;
    }
  }

  /// Check active network interfaces and categorize them.
  Future<Map<String, List<String>>> getActiveInterfaces() async {
    final map = <String, List<String>>{
      'ethernet': [],
      'usb': [],
      'wifi': [],
      'other': [],
    };

    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );

      for (final iface in interfaces) {
        final name = iface.name.toLowerCase();
        final ips = iface.addresses.map((a) => a.address).join(', ');
        final desc = '${iface.name} ($ips)';

        if (name.contains('usb') || name.contains('rndis') || name.contains('ncm')) {
          map['usb']!.add(desc);
        } else if (name.contains('ethernet') || name.contains('eth') || name.contains('gbe')) {
          map['ethernet']!.add(desc);
        } else if (name.contains('wi-fi') || name.contains('wifi') || name.contains('wlan')) {
          map['wifi']!.add(desc);
        } else {
          map['other']!.add(desc);
        }
      }
    } catch (_) {}

    return map;
  }
}
