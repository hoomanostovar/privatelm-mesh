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
    duration: const Duration(milliseconds: 2800),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);

    return InteractivePress(
      onTap: widget.onScanTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        height: 120,
        width: double.infinity,
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: t.hairline, width: 0.8),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: t.isDark ? 0.30 : 0.05),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final progress = _controller.value;
            final sweepAngle = progress * 6.28318530718; // 2 * pi

            return Stack(
              alignment: Alignment.center,
              children: [
                // Background subtle grid lines
                CustomPaint(
                  size: const Size(double.infinity, 120),
                  painter: _RadarGridPainter(color: t.hairline),
                ),
                // Rotating radar beam
                Transform.rotate(
                  angle: sweepAngle,
                  child: Container(
                    width: 140,
                    height: 140,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: SweepGradient(
                        colors: [
                          t.accent.withValues(alpha: 0.0),
                          t.accent.withValues(alpha: 0.18),
                          t.accent.withValues(alpha: 0.0),
                        ],
                        stops: const [0.0, 0.25, 0.26],
                      ),
                    ),
                  ),
                ),
                // Concentric expanding pulse ripple 1
                _rippleCircle(t.accent, (progress * 150).clamp(0, 150), 1.0 - progress),
                // Concentric expanding pulse ripple 2
                _rippleCircle(
                  t.accent,
                  (((progress + 0.5) % 1.0) * 150).clamp(0, 150),
                  1.0 - ((progress + 0.5) % 1.0),
                ),
                // Central Coordinator Orb
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: [t.accent, t.accent.withValues(alpha: 0.8)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: t.accent.withValues(alpha: 0.45),
                        blurRadius: 20,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: const Icon(Icons.hub_rounded, color: Colors.white, size: 23),
                ),
                // Overlay Pill Badge
                Positioned(
                  bottom: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: t.bg.withValues(alpha: 0.90),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: t.accent.withValues(alpha: 0.25),
                        width: 0.8,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.2),
                          blurRadius: 8,
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        PulsingStatusDot(color: t.green, size: 6),
                        const SizedBox(width: 8),
                        Text(
                          '${widget.onlineCount} Mesh Node${widget.onlineCount == 1 ? '' : 's'} Active · Tap to Scan',
                          style: t.caption.copyWith(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.1,
                          ),
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
          color: color.withValues(alpha: (opacity * 0.50).clamp(0.0, 1.0)),
          width: 1.5,
        ),
      ),
    );
  }
}

class _RadarGridPainter extends CustomPainter {
  final Color color;
  const _RadarGridPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 0.5
      ..style = PaintingStyle.stroke;

    final center = Offset(size.width / 2, size.height / 2);
    canvas.drawCircle(center, 30, paint);
    canvas.drawCircle(center, 55, paint);
    canvas.drawLine(Offset(center.dx - 70, center.dy), Offset(center.dx + 70, center.dy), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
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
    final isSpecialStatus = status == 'communicating' || status == 'benchmarking';

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlowCard(
        borderRadius: 16,
        isGlowActive: isSpecialStatus,
        glowColor: status == 'communicating' ? t.accent : Colors.purple,
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: t.fill,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: t.hairline),
                  ),
                  child: Icon(icon, size: 20, color: t.text),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              title,
                              style: t.bodyStrong.copyWith(fontSize: 14),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (isLocal) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: t.accent.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: t.accent.withValues(alpha: 0.3)),
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
                      const SizedBox(height: 3),
                      Text(subtitle, style: t.caption.copyWith(fontSize: 11.5)),
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
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: statusColor.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PulsingStatusDot(
                        color: statusColor,
                        size: 5.5,
                        animate: isSpecialStatus || status == 'ready',
                      ),
                      const SizedBox(width: 5),
                      Text(
                        status.toUpperCase(),
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
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

/// Mesh Aggregate Telemetry HUD Card with 21st.dev Bento Grid Layout.
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

    return GlowCard(
      borderRadius: 18,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: t.accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.insights_rounded, size: 16, color: t.accent),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Cluster Telemetry & Power HUD', style: t.bodyStrong.copyWith(fontSize: 14)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: t.green.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: t.green.withValues(alpha: 0.25)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    PulsingStatusDot(color: t.green, size: 5),
                    const SizedBox(width: 5),
                    Text(
                      'LIVE',
                      style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                        color: t.green,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: BentoMetricCard(
                  title: 'Mesh Tokens',
                  value: '$totalTokens',
                  icon: Icons.bolt_rounded,
                  accentColor: t.accent,
                  subtitle: 'Pooled count',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: BentoMetricCard(
                  title: 'Throughput',
                  value: '${tokensPerSec.toStringAsFixed(1)} t/s',
                  icon: Icons.speed_rounded,
                  accentColor: t.green,
                  tag: tokensPerSec > 0 ? 'ACTIVE' : 'IDLE',
                  tagColor: tokensPerSec > 0 ? t.green : t.muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: BentoMetricCard(
                  title: 'Total Power',
                  value: '${totalWattage.toStringAsFixed(0)} W',
                  icon: Icons.power_outlined,
                  accentColor: t.orange,
                  subtitle: 'Pooled draw',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: BentoMetricCard(
                  title: 'Efficiency',
                  value: '${tokensPerWatt.toStringAsFixed(2)} t/J',
                  icon: Icons.eco_rounded,
                  accentColor: const Color(0xFF34C759),
                  subtitle: 'Tokens per Joule',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

