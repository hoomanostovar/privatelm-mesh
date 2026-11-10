import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:markdown/markdown.dart' as md;
import '../core/haptics.dart';

/// Custom MarkdownElementBuilder that renders fenced code blocks (`<pre><code>`)
/// with a dedicated language header, single-click copy button with animated feedback,
/// and horizontal scrolling.
class CodeBlockBuilder extends MarkdownElementBuilder {
  final BuildContext context;

  CodeBlockBuilder(this.context);

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    // Extract raw code string
    final rawCode = element.textContent.trimRight();

    // Extract code language from <code class="language-xyz">
    String language = '';
    if (element.children != null && element.children!.isNotEmpty) {
      final child = element.children!.first;
      if (child is md.Element && child.attributes.containsKey('class')) {
        final cls = child.attributes['class'] ?? '';
        final match = RegExp(r'language-([\w+\-#]+)').firstMatch(cls);
        if (match != null) {
          language = match.group(1) ?? '';
        }
      }
    }

    return CodeBlockCard(code: rawCode, language: language);
  }
}

/// A sleek code block card featuring a language badge, single-click copy button,
/// and continuous text selection support within a parent SelectionArea.
class CodeBlockCard extends StatefulWidget {
  final String code;
  final String language;

  const CodeBlockCard({
    super.key,
    required this.code,
    required this.language,
  });

  @override
  State<CodeBlockCard> createState() => _CodeBlockCardState();
}

class _CodeBlockCardState extends State<CodeBlockCard> {
  bool _copied = false;

  Future<void> _copyCode() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    Haptics.lightImpact();
    if (!mounted) return;
    setState(() => _copied = true);
    await Future.delayed(const Duration(milliseconds: 1500));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final muted = Theme.of(context).hintColor;

    final bg = isDark ? const Color(0xFF141416) : const Color(0xFFF6F6F8);
    final headerBg = isDark ? const Color(0xFF1C1C1F) : const Color(0xFFEBEBEF);
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.08);

    final langDisplay = widget.language.isEmpty
        ? 'CODE'
        : widget.language.toUpperCase();

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header Bar
          Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            color: headerBg,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Language pill
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.code_rounded, size: 14, color: muted),
                    const SizedBox(width: 6),
                    Text(
                      langDisplay,
                      style: GoogleFonts.firaCode(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                        color: muted,
                      ),
                    ),
                  ],
                ),
                // Copy Code Button
                Tooltip(
                  message: 'Copy code block',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: _copyCode,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 150),
                            child: Icon(
                              _copied
                                  ? Icons.check_rounded
                                  : Icons.content_copy_rounded,
                              key: ValueKey(_copied),
                              size: 13,
                              color: _copied
                                  ? const Color(0xFF34C759)
                                  : muted,
                            ),
                          ),
                          const SizedBox(width: 5),
                          Text(
                            _copied ? 'Copied!' : 'Copy code',
                            style: GoogleFonts.inter(
                              fontSize: 12,
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
          ),
          // Code Content (horizontally scrollable, continuous text selection)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(14),
            child: Text(
              widget.code,
              style: GoogleFonts.firaCode(
                fontSize: 13,
                height: 1.5,
                letterSpacing: -0.1,
                color: onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

