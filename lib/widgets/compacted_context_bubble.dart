import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/haptics.dart';
import '../models/chat_message.dart';

/// A sleek accordion card representing a compacted context snapshot in chat.
class CompactedContextBubble extends StatefulWidget {
  final ChatMessage message;

  const CompactedContextBubble({super.key, required this.message});

  @override
  State<CompactedContextBubble> createState() => _CompactedContextBubbleState();
}

class _CompactedContextBubbleState extends State<CompactedContextBubble> {
  bool _expanded = false;
  bool _copied = false;

  String _cleanSummary(String text) {
    return text
        .replaceAll('<CONTEXT_SUMMARY>', '')
        .replaceAll('</CONTEXT_SUMMARY>', '')
        .trim();
  }

  Future<void> _copySummary() async {
    final clean = _cleanSummary(widget.message.content);
    await Clipboard.setData(ClipboardData(text: clean));
    Haptics.lightImpact();
    if (!mounted) return;
    setState(() => _copied = true);
    await Future.delayed(const Duration(milliseconds: 1400));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = Theme.of(context).hintColor;
    final onSurface = Theme.of(context).colorScheme.onSurface;

    final cleanSummary = _cleanSummary(widget.message.content);

    final cardBg = isDark ? const Color(0xFF161619) : const Color(0xFFF4F4F7);
    final borderColor = isDark
        ? const Color(0xFFFF9500).withValues(alpha: 0.25)
        : const Color(0xFFFF9500).withValues(alpha: 0.35);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 720),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: borderColor, width: 0.8),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Accordion Header Bar
              InkWell(
                onTap: () {
                  Haptics.selectionClick();
                  setState(() => _expanded = !_expanded);
                },
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      // Badge icon
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: isDark
                                ? [const Color(0xFFFF9500), const Color(0xFFFF5E3A)]
                                : [const Color(0xFFFF9500), const Color(0xFFFF7A00)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Center(
                          child: Icon(Icons.compress_rounded,
                              size: 18, color: Colors.white),
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Title & subtitle
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  'Context Compacted',
                                  style: GoogleFonts.inter(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: onSurface,
                                    letterSpacing: -0.2,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFF9500)
                                        .withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    'Snapshot',
                                    style: GoogleFonts.inter(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      color: const Color(0xFFFF9500),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _expanded
                                  ? 'Tap to collapse context recap'
                                  : 'Preserved objectives, constraints & state · Tap to view',
                              style: GoogleFonts.inter(
                                fontSize: 12,
                                color: muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Rotate chevron
                      AnimatedRotation(
                        turns: _expanded ? 0.5 : 0.0,
                        duration: const Duration(milliseconds: 200),
                        child: Icon(Icons.expand_more_rounded,
                            size: 20, color: muted),
                      ),
                    ],
                  ),
                ),
              ),

              // Expandable content
              AnimatedCrossFade(
                firstChild: const SizedBox.shrink(),
                secondChild: Container(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.06)
                            : Colors.black.withValues(alpha: 0.06),
                      ),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 10),
                      // Action row inside summary
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Compacted Context Recap',
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: muted,
                            ),
                          ),
                          Tooltip(
                            message: 'Copy summary',
                            child: InkWell(
                              borderRadius: BorderRadius.circular(6),
                              onTap: _copySummary,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 3),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      _copied
                                          ? Icons.check_rounded
                                          : Icons.content_copy_rounded,
                                      size: 13,
                                      color: _copied
                                          ? const Color(0xFF34C759)
                                          : muted,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      _copied ? 'Copied' : 'Copy',
                                      style: GoogleFonts.inter(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w500,
                                        color: _copied
                                          ? const Color(0xFF34C759)
                                          : muted,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      // Render Markdown summary with selectable: false for unified parent selection
                      MarkdownBody(
                        data: cleanSummary,
                        selectable: false,
                        styleSheet: _summaryStyle(context),
                      ),
                    ],
                  ),
                ),
                crossFadeState: _expanded
                    ? CrossFadeState.showSecond
                    : CrossFadeState.showFirst,
                duration: const Duration(milliseconds: 220),
              ),
            ],
          ),
        ),
      ),
    );
  }

  MarkdownStyleSheet _summaryStyle(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = Theme.of(context).colorScheme.onSurface;
    final muted = Theme.of(context).hintColor;
    final base = GoogleFonts.inter(
        fontSize: 13.5, color: color, height: 1.5, letterSpacing: -0.1);

    return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: base,
      strong: base.copyWith(fontWeight: FontWeight.w600),
      em: base.copyWith(fontStyle: FontStyle.italic),
      listBullet: base.copyWith(color: const Color(0xFFFF9500)),
      h3: base.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          color: isDark ? const Color(0xFFFFB340) : const Color(0xFFCC7700),
          height: 1.4),
      pPadding: const EdgeInsets.only(bottom: 4),
      code: GoogleFonts.firaCode(
        fontSize: 12,
        color: color,
        backgroundColor:
            isDark ? const Color(0xFF222226) : const Color(0xFFE8E8EC),
      ),
      blockquote: base.copyWith(color: muted),
    );
  }
}

