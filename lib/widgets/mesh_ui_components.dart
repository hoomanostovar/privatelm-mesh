import 'package:flutter/material.dart';
import '../core/ui.dart';
import '../models/transport_type.dart';

/// 21st.dev Inspired Radar Scanner:
/// Concentric animated expanding ripples visualizing continuous local mesh discovery.
class MeshRadarScanner extends StatefulWidget {
  final int onlineCount;
  final VoidCallback? onScanTap;

  const MeshRadarScanner({
    super.key,
    required this.onlineCount,
    this.onScanTap,
  });

  @override
  State<MeshRadarScanner> createState() => _MeshRadarScannerState();
}

class _MeshRadarScannerState extends State<MeshRadarScanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);

    return InkWell(
      onTap: widget.onScanTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        height: 110,
        width: double.infinity,
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: t.hairline),
        ),
        clipBehavior: Clip.antiAlias,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final progress = _controller.value;
            return Stack(
              alignment: Alignment.center,
              children: [
                // Expanding ripple 1
                _rippleCircle(t.accent, (progress * 130).clamp(0, 130), 1.0 - progress),
                // Expanding ripple 2
                _rippleCircle(
                  t.accent,
                  (((progress + 0.5) % 1.0) * 130).clamp(0, 130),
                  1.0 - ((progress + 0.5) % 1.0),
                ),
                // Center Coordinator Orb
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: [t.accent, t.accent.withValues(alpha: 0.7)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: t.accent.withValues(alpha: 0.35),
                        blurRadius: 16,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: const Icon(Icons.hub_rounded, color: Colors.white, size: 22),
                ),
                // Overlay text
                Positioned(
                  bottom: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      color: t.bg.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: t.hairline),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        StatusDot(t.green, size: 6),
                        const SizedBox(width: 6),
                        Text(
                          '${widget.onlineCount} Mesh Node${widget.onlineCount == 1 ? '' : 's'} Active · Scanning',
                          style: t.caption.copyWith(fontSize: 11, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _rippleCircle(Color color, double diameter, double opacity) {
    return Container(
      width: diameter,
      height: diameter,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: color.withValues(alpha: (opacity * 0.45).clamp(0.0, 1.0)),
          width: 1.5,
        ),
      ),
    );
  }
}

/// Dynamic Animated Node Card with Telemetry Badges.
class MeshNodeCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String? transportType;
  final double? latencyMs;
  final String uptime;
  final int tokensGenerated;
  final double tokensPerSec;
  final double wattage;
  final String status;
  final Widget? trailing;
  final bool isLocal;

  const MeshNodeCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.transportType,
    this.latencyMs,
    required this.uptime,
    required this.tokensGenerated,
    required this.tokensPerSec,
    required this.wattage,
    required this.status,
    this.trailing,
    this.isLocal = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final statusColor = _statusColor(t);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: status == 'communicating'
              ? t.accent.withValues(alpha: 0.6)
              : status == 'benchmarking'
                  ? Colors.purple.withValues(alpha: 0.6)
                  : t.hairline,
          width: status == 'communicating' || status == 'benchmarking' ? 1.5 : 1.0,
        ),
        boxShadow: status == 'communicating'
            ? [
                BoxShadow(
                  color: t.accent.withValues(alpha: 0.12),
                  blurRadius: 10,
                  spreadRadius: 1,
                )
              ]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: t.fill,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 20, color: t.text),
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
                            title,
                            style: t.bodyStrong.copyWith(fontSize: 13.5),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isLocal) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: t.accent.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              'Coordinator',
                              style: TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.bold,
                                color: t.accent,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(subtitle, style: t.caption.copyWith(fontSize: 11)),
                  ],
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 12),
          // Telemetry Row
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              // Transport Badge
              if (transportType != null) _transportPill(context),
              // Status Pill
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: statusColor.withValues(alpha: 0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    StatusDot(statusColor, size: 6),
                    const SizedBox(width: 4),
                    Text(
                      status.toUpperCase(),
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: statusColor,
                      ),
                    ),
                  ],
                ),
              ),
              // Uptime
              _telemetryPill(t, Icons.timer_outlined, uptime),
              // Tokens Generated
              _telemetryPill(t, Icons.bolt_rounded, '$tokensGenerated tok'),
              // Tokens per Sec
              if (tokensPerSec > 0.1)
                _telemetryPill(t, Icons.speed_rounded, '${tokensPerSec.toStringAsFixed(1)} t/s', highlight: true),
              // Wattage
              _telemetryPill(t, Icons.power_outlined, '${wattage.toStringAsFixed(0)} W'),
            ],
          ),
        ],
      ),
    );
  }

  Color _statusColor(AppTokens t) {
    switch (status) {
      case 'communicating':
        return t.accent;
      case 'loading':
      case 'unloading':
        return t.orange;
      case 'benchmarking':
        return Colors.purple;
      case 'ready':
      default:
        return t.green;
    }
  }

  Widget _transportPill(BuildContext context) {
    final t = AppTokens.of(context);
    final transport = TransportTypeExt.fromString(transportType);
    final Color color;
    final String label;

    switch (transport) {
      case TransportType.usb:
        color = t.green;
        label = '⚡ USB${latencyMs != null ? " · ${latencyMs!.toStringAsFixed(1)}ms" : ""}';
        break;
      case TransportType.ethernet:
        color = t.accent;
        label = '🌐 LAN${latencyMs != null ? " · ${latencyMs!.toStringAsFixed(1)}ms" : ""}';
        break;
      case TransportType.wifi:
      case TransportType.unknown:
        color = t.muted;
        label = '📶 Wi-Fi${latencyMs != null ? " · ${latencyMs!.toStringAsFixed(1)}ms" : ""}';
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }

  Widget _telemetryPill(AppTokens t, IconData icon, String text, {bool highlight = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: highlight ? t.accent.withValues(alpha: 0.12) : t.fill,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: highlight ? t.accent.withValues(alpha: 0.3) : t.hairline,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: highlight ? t.accent : t.muted),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w500,
              color: highlight ? t.accent : t.text,
            ),
          ),
        ],
      ),
    );
  }
}

/// Mesh Aggregate Telemetry HUD Card.
class MeshAggregateTelemetryCard extends StatelessWidget {
  final int totalTokens;
  final double tokensPerSec;
  final double totalWattage;
  final double tokensPerWatt;
  final String uptime;

  const MeshAggregateTelemetryCard({
    super.key,
    required this.totalTokens,
    required this.tokensPerSec,
    required this.totalWattage,
    required this.tokensPerWatt,
    required this.uptime,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.insights_rounded, size: 18, color: t.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Cluster Telemetry & Power HUD', style: t.bodyStrong),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: t.fill,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text('Live', style: t.small.copyWith(fontSize: 10, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _statBox(
                  context,
                  label: 'Mesh Tokens',
                  value: '$totalTokens',
                  icon: Icons.bolt_rounded,
                  color: t.accent,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _statBox(
                  context,
                  label: 'Speed',
                  value: '${tokensPerSec.toStringAsFixed(1)} tok/s',
                  icon: Icons.speed_rounded,
                  color: t.green,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _statBox(
                  context,
                  label: 'Total Power',
                  value: '${totalWattage.toStringAsFixed(0)} W',
                  icon: Icons.power_outlined,
                  color: t.orange,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _statBox(
                  context,
                  label: 'Efficiency',
                  value: '${tokensPerWatt.toStringAsFixed(3)} t/J',
                  icon: Icons.eco_rounded,
                  color: const Color(0xFF34C759),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statBox(
    BuildContext context, {
    required String label,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    final t = AppTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: t.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
              Text(label, style: t.caption.copyWith(fontSize: 11)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: t.bodyStrong.copyWith(fontSize: 14, fontFamily: 'monospace'),
          ),
        ],
      ),
    );
  }
}

