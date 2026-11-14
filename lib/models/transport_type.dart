import 'package:flutter/material.dart' show Color, Colors, IconData, Icons;

/// Physical and logical network transport type for cluster nodes.
enum TransportType {
  /// USB-C / USB 3.x / USB 2.0 direct connection, ADB port-forwarding, or USB tethering (RNDIS/NCM).
  /// Ultra-low latency (<0.5 ms), high bandwidth (480 Mbps to 10 Gbps).
  usb,

  /// Wired Gigabit / Multi-Gigabit Ethernet connection via router or switch.
  /// Very low latency (<1.0 ms), high throughput (1 Gbps to 10 Gbps).
  ethernet,

  /// Wireless local area network (802.11 Wi-Fi 5/6/6E/7).
  /// Moderate latency (5 to 25 ms), subject to jitter and airtime contention.
  wifi,

  /// Wide Area Network / Mobile Data (5G/4G/LTE) / Overlay Mesh VPN (Tailscale, WireGuard, ZeroTier).
  /// Higher latency (25 to 120 ms) across internet/cellular links; scheduled as a contiguous
  /// Away Sub-Cluster so activation tensors cross the internet link only once per token.
  wan,

  /// Unknown or default network transport.
  unknown,
}

extension TransportTypeExt on TransportType {
  String get id {
    switch (this) {
      case TransportType.usb:
        return 'usb';
      case TransportType.ethernet:
        return 'ethernet';
      case TransportType.wifi:
        return 'wifi';
      case TransportType.wan:
        return 'wan';
      case TransportType.unknown:
        return 'unknown';
    }
  }

  String get displayName {
    switch (this) {
      case TransportType.usb:
        return 'USB ⚡ (Direct Cable)';
      case TransportType.ethernet:
        return 'Ethernet 🌐 (Wired LAN)';
      case TransportType.wifi:
        return 'Wi-Fi 📶 (Home Wireless)';
      case TransportType.wan:
        return 'WAN / 5G 🌍 (Mobile / Overlay)';
      case TransportType.unknown:
        return 'Network';
    }
  }

  String get badgeLabel {
    switch (this) {
      case TransportType.usb:
        return 'USB ⚡';
      case TransportType.ethernet:
        return 'Ethernet 🌐';
      case TransportType.wifi:
        return 'Wi-Fi 📶';
      case TransportType.wan:
        return 'WAN / 5G 🌍';
      case TransportType.unknown:
        return 'LAN';
    }
  }

  IconData get icon {
    switch (this) {
      case TransportType.usb:
        return Icons.usb_rounded;
      case TransportType.ethernet:
        return Icons.settings_ethernet_rounded;
      case TransportType.wifi:
        return Icons.wifi_rounded;
      case TransportType.wan:
        return Icons.public_rounded;
      case TransportType.unknown:
        return Icons.device_hub_rounded;
    }
  }

  Color get color {
    switch (this) {
      case TransportType.usb:
        return const Color(0xFF10B981); // Emerald / Green
      case TransportType.ethernet:
        return const Color(0xFF3B82F6); // Blue
      case TransportType.wifi:
        return const Color(0xFFF59E0B); // Amber / Orange
      case TransportType.wan:
        return const Color(0xFFA855F7); // Plasma Violet (WAN / Mobile)
      case TransportType.unknown:
        return Colors.grey;
    }
  }

  /// Priority tier: 0 (local), 1 (USB), 2 (Ethernet), 3 (Wi-Fi), 4 (WAN / Mobile).
  int get priorityTier {
    switch (this) {
      case TransportType.usb:
        return 1;
      case TransportType.ethernet:
        return 2;
      case TransportType.wifi:
        return 3;
      case TransportType.wan:
        return 4;
      case TransportType.unknown:
        return 5;
    }
  }

  /// Estimated baseline latency in milliseconds.
  double get estimatedLatencyMs {
    switch (this) {
      case TransportType.usb:
        return 0.3;
      case TransportType.ethernet:
        return 0.8;
      case TransportType.wifi:
        return 12.0;
      case TransportType.wan:
        return 42.0;
      case TransportType.unknown:
        return 10.0;
    }
  }

  /// Whether this node is an Away / Mobile / WAN node (either classified as WAN/VPN
  /// or measured with internet/cellular round-trip latency >= 24 ms).
  bool isAwayTransport([double? latencyMs]) {
    if (this == TransportType.wan) return true;
    if (this == TransportType.usb || this == TransportType.ethernet) return false;
    return latencyMs != null && latencyMs >= 24.0;
  }

  static TransportType fromString(String? val) {
    if (val == null) return TransportType.unknown;
    final lower = val.toLowerCase();
    if (lower.contains('usb') || lower.contains('adb') || lower.contains('rndis')) {
      return TransportType.usb;
    }
    if (lower.contains('ethernet') || lower.contains('eth') || lower.contains('lan')) {
      return TransportType.ethernet;
    }
    if (lower.contains('wan') ||
        lower.contains('5g') ||
        lower.contains('4g') ||
        lower.contains('lte') ||
        lower.contains('mobile') ||
        lower.contains('tailscale') ||
        lower.contains('vpn') ||
        lower.contains('wireguard') ||
        lower.contains('zerotier') ||
        lower.contains('internet') ||
        lower.contains('away')) {
      return TransportType.wan;
    }
    if (lower.contains('wi-fi') || lower.contains('wifi') || lower.contains('wlan')) {
      return TransportType.wifi;
    }
    return TransportType.unknown;
  }
}

/// Cluster scheduling strategy modes.
enum ClusterSchedulerStrategy {
  /// Topology & Latency Optimized: Prioritizes local GPU, then USB, then Ethernet,
  /// allocating contiguous layer blocks and gating Wi-Fi nodes unless extra RAM is strictly required.
  topologyLatency,

  /// Bandwidth Weighted: Splits layers proportionally based on benchmarked memory & link bandwidth.
  throughputWeighted,

  /// Capacity Balanced: Splits layers purely based on available free VRAM / RAM across all nodes.
  capacityBalanced,
}

extension ClusterSchedulerStrategyExt on ClusterSchedulerStrategy {
  String get id {
    switch (this) {
      case ClusterSchedulerStrategy.topologyLatency:
        return 'topology_latency';
      case ClusterSchedulerStrategy.throughputWeighted:
        return 'throughput_weighted';
      case ClusterSchedulerStrategy.capacityBalanced:
        return 'capacity_balanced';
    }
  }

  String get displayName {
    switch (this) {
      case ClusterSchedulerStrategy.topologyLatency:
        return 'Topology & Latency Optimized (Recommended)';
      case ClusterSchedulerStrategy.throughputWeighted:
        return 'Bandwidth & Throughput Weighted';
      case ClusterSchedulerStrategy.capacityBalanced:
        return 'Capacity Balanced';
    }
  }

  String get description {
    switch (this) {
      case ClusterSchedulerStrategy.topologyLatency:
        return 'Packs layers on local GPU and fast USB/Ethernet links first. Minimizes tensor boundary hops and skips Wi-Fi latency penalties when model fits in fast tiers.';
      case ClusterSchedulerStrategy.throughputWeighted:
        return 'Divides model weights based on raw benchmarked memory bandwidth (GB/s) across all active nodes.';
      case ClusterSchedulerStrategy.capacityBalanced:
        return 'Evenly distributes layers proportional to free VRAM/RAM capacity without link penalization.';
    }
  }

  static ClusterSchedulerStrategy fromString(String? val) {
    if (val == null) return ClusterSchedulerStrategy.topologyLatency;
    for (final s in ClusterSchedulerStrategy.values) {
      if (s.id == val || s.name == val) return s;
    }
    return ClusterSchedulerStrategy.topologyLatency;
  }
}
