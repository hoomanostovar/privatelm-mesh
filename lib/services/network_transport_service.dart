import 'dart:async';
import 'dart:io';
import '../models/transport_type.dart';

/// Service that classifies network transports and benchmarks endpoint latency.
class NetworkTransportService {
  static final NetworkTransportService instance = NetworkTransportService._();
  NetworkTransportService._();

  /// Returns true if [ip] is in the CGNAT / Tailscale / Overlay range (100.64.0.0/10)
  /// or ZeroTier / WireGuard overlay subnets, or is a public non-RFC1918 WAN IP.
  static bool isWanOrOverlayIp(String ip) {
    final clean = ip.trim().toLowerCase();
    if (clean.isEmpty || clean == '127.0.0.1' || clean == 'localhost') return false;
    final parts = clean.split('.');
    if (parts.length == 4) {
      final o1 = int.tryParse(parts[0]);
      final o2 = int.tryParse(parts[1]);
      if (o1 != null && o2 != null) {
        // 100.64.0.0/10 (Tailscale / Carrier-Grade NAT / Overlay VPN)
        if (o1 == 100 && o2 >= 64 && o2 <= 127) return true;
        // Private LAN RFC1918 ranges
        if (o1 == 10) return false;
        if (o1 == 192 && o2 == 168) return false;
        if (o1 == 172 && o2 >= 16 && o2 <= 31) return false;
        if (o1 == 169 && o2 == 254) return false;
        // Any other valid IPv4 is a public WAN IP!
        return true;
      }
    }
    // Domain name / DDNS hostname
    if (RegExp(r'[a-z]').hasMatch(clean)) return true;
    return false;
  }

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

    // Tailscale / CGNAT / Overlay VPN (100.64.0.0/10) or public WAN IP / hostname
    if (isWanOrOverlayIp(cleanHost)) {
      return TransportType.wan;
    }

    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );

      // Check if target IP falls within an interface's subnet
      for (final iface in interfaces) {
        final ifaceName = iface.name.toLowerCase();
        final hasWan = ifaceName.contains('tailscale') ||
            ifaceName.contains('wireguard') ||
            ifaceName.contains('wg') ||
            ifaceName.contains('zerotier') ||
            ifaceName.contains('zt') ||
            ifaceName.contains('tun') ||
            ifaceName.contains('utun') ||
            ifaceName.contains('rmnet') ||
            ifaceName.contains('ccmni') ||
            ifaceName.contains('pdp_ip') ||
            ifaceName.contains('cellular') ||
            ifaceName.contains('wwan');
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
          final lastDotA = addr.address.lastIndexOf('.');
          final lastDotB = cleanHost.lastIndexOf('.');
          if (lastDotA > 0 && lastDotB > 0) {
            final ifacePrefix = addr.address.substring(0, lastDotA);
            final targetPrefix = cleanHost.substring(0, lastDotB);
            if (ifacePrefix == targetPrefix) {
              if (hasWan) return TransportType.wan;
              if (hasUsb) return TransportType.usb;
              if (hasEth) return TransportType.ethernet;
              if (hasWifi) return TransportType.wifi;
            }
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
