import 'dart:math' as math;
import '../models/chat_message.dart';
import '../utils/thought_parser.dart';

/// Result returned from a context compaction run.
class CompactResult {
  final String summary;
  final int prunedCount;
  final int estimatedTokensSaved;
  final bool usedModel;

  CompactResult({
    required this.summary,
    required this.prunedCount,
    required this.estimatedTokensSaved,
    this.usedModel = false,
  });
}

/// Context compactor inspired by DeepSeek harness, Claude Code, and Antigravity.
///
/// Condenses older conversational history into a dense, structured context summary
/// preserving primary objectives, constraints, technical context, files, and state,
/// while keeping recent active turns verbatim.
class ContextCompactorService {
  /// Regular expressions for detecting technical artifacts and constraints.
  static final _fileRegex = RegExp(
      r'[\w\-./\\]+\.(dart|cpp|c|h|hpp|py|json|yaml|yml|md|txt|gguf|bin|task|litertlm)',
      caseSensitive: false);
  static final _modelRegex = RegExp(
      r'\b(qwen[\w.-]*|gemma[\w.-]*|llama[\w.-]*|lfm[\w.-]*|deepseek[\w.-]*|phi[\w.-]*|mistral[\w.-]*)\b',
      caseSensitive: false);
  static final _errorRegex = RegExp(
      r'(error:?[^\n]{0,80}|exception:?[^\n]{0,80}|exit code\s*-?\d+|status\s*\d{3}|code:\s*503|0x[0-9a-fA-F]{6,8})',
      caseSensitive: false);
  static final _networkRegex = RegExp(
      r'\b(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?\b|\blocalhost(?::\d+)?\b',
      caseSensitive: false);

  static final _fillerRegex = RegExp(
      r'^(hi|hello|hey|ok|okay|thanks|thank you|cool|great|nice|done|got it|yes|no|sure|yep|nope)[.!?]*$',
      caseSensitive: false);

  static final _constraintKeywords = [
    'only',
    'must',
    "don't",
    'dont',
    'never',
    'not',
    'ensure',
    'prefer',
    'instead',
    'switch to',
    'keep',
    'separate',
    'pc only',
    'windows',
    'offline',
    'local only',
    'avoid',
  ];

  /// Compares and condenses [messages], leaving [retainRecent] messages intact.
  ///
  /// If [modelSummarizer] is provided, attempts an LLM-guided semantic compaction.
  /// If [modelSummarizer] is null, throws, or times out, gracefully falls back
  /// to the deterministic heuristic extractive compactor.
  static Future<CompactResult?> compact({
    required List<ChatMessage> messages,
    int retainRecent = 2,
    Future<String?> Function(String prompt)? modelSummarizer,
  }) async {
    if (messages.length <= retainRecent) {
      return null;
    }

    final splitIndex = messages.length - retainRecent;
    final toPrune = messages.sublist(0, splitIndex);

    // Calculate approximate original tokens (chars / 4)
    final originalChars = toPrune.fold<int>(0, (sum, m) => sum + m.content.length);

    // Attempt Model-guided semantic compaction if summarizer is available
    if (modelSummarizer != null) {
      try {
        final prompt = _buildModelSummarizationPrompt(toPrune);
        final raw = await modelSummarizer(prompt)
            .timeout(const Duration(seconds: 15));
        if (raw != null && raw.trim().isNotEmpty) {
          final formatted = _sanitizeModelSummary(raw.trim());
          if (formatted.isNotEmpty) {
            final savedChars = math.max(0, originalChars - formatted.length);
            return CompactResult(
              summary: formatted,
              prunedCount: toPrune.length,
              estimatedTokensSaved: (savedChars / 4).ceil(),
              usedModel: true,
            );
          }
        }
      } catch (e) {
        // Fall through to deterministic heuristic summarizer
      }
    }

    // Deterministic Heuristic Extractive Compactor (Zero-Failure)
    final summary = _heuristicSummarize(toPrune);
    final savedChars = math.max(0, originalChars - summary.length);

    return CompactResult(
      summary: summary,
      prunedCount: toPrune.length,
      estimatedTokensSaved: (savedChars / 4).ceil(),
      usedModel: false,
    );
  }

  /// Builds a deterministic, structured summary from [toPrune].
  static String _heuristicSummarize(List<ChatMessage> toPrune) {
    final objectives = <String>{};
    final constraints = <String>{};
    final techArtifacts = <String>{};
    final resolutions = <String>{};

    // If an earlier <CONTEXT_SUMMARY> is present, parse and merge its sections
    for (final m in toPrune) {
      if (m.content.contains('<CONTEXT_SUMMARY>')) {
        _extractExistingSummarySections(
          m.content,
          objectives: objectives,
          constraints: constraints,
          techArtifacts: techArtifacts,
          resolutions: resolutions,
        );
      }
    }

    for (final m in toPrune) {
      // Skip earlier compacted summaries here (handled above)
      if (m.content.contains('<CONTEXT_SUMMARY>')) continue;

      final content = m.content.trim();
      if (content.isEmpty) continue;

      // Extract technical entities across all messages
      for (final match in _fileRegex.allMatches(content)) {
        final f = match.group(0);
        if (f != null && !f.startsWith('http')) techArtifacts.add('File: `$f`');
      }
      for (final match in _modelRegex.allMatches(content)) {
        final model = match.group(0);
        if (model != null) techArtifacts.add('Model: `$model`');
      }
      for (final match in _networkRegex.allMatches(content)) {
        final net = match.group(0);
        if (net != null) techArtifacts.add('Endpoint: `$net`');
      }
      for (final match in _errorRegex.allMatches(content)) {
        final err = match.group(0);
        if (err != null) techArtifacts.add('Error trace: `$err`');
      }

      if (m.role == 'user') {
        final cleanText = content.split('\n\nAttached file:').first.trim();
        if (_fillerRegex.hasMatch(cleanText)) continue;

        // Check for explicit constraints
        final lower = cleanText.toLowerCase();
        for (final kw in _constraintKeywords) {
          if (lower.contains(kw)) {
            final sentence = _extractRelevantClause(cleanText, kw);
            if (sentence.isNotEmpty && sentence.length < 180) {
              constraints.add(sentence);
            }
          }
        }

        // Add user request as an objective
        final lines = cleanText.split('\n');
        final firstLine = lines.first.trim();
        if (firstLine.isNotEmpty && firstLine.length < 160) {
          objectives.add(firstLine);
        } else if (cleanText.length <= 140) {
          objectives.add(cleanText);
        } else {
          objectives.add('${cleanText.substring(0, 137)}...');
        }
      } else if (m.role == 'assistant') {
        final parsed = splitThoughtTags(content);
        final ans = parsed.answer.trim();
        if (ans.isEmpty) continue;

        // Look for solutions, conclusions, or fixes
        if (ans.toLowerCase().contains('fixed') ||
            ans.toLowerCase().contains('resolved') ||
            ans.toLowerCase().contains('implemented') ||
            ans.toLowerCase().contains('solution:')) {
          final firstLine = ans.split('\n').firstWhere(
                (l) => l.trim().isNotEmpty && l.length < 160,
                orElse: () => '',
              );
          if (firstLine.isNotEmpty) {
            resolutions.add(firstLine.trim());
          }
        }
      }
    }

    final buf = StringBuffer();
    buf.writeln('<CONTEXT_SUMMARY>');
    buf.writeln('### 1. Primary Objectives & Topics');
    if (objectives.isEmpty) {
      buf.writeln('- Ongoing assistance and coding queries.');
    } else {
      for (final obj in objectives.take(6)) {
        buf.writeln('- $obj');
      }
    }
    buf.writeln();

    buf.writeln('### 2. Key Constraints & User Decisions');
    if (constraints.isEmpty) {
      buf.writeln('- Follow standard architectural constraints and project standards.');
    } else {
      for (final c in constraints.take(6)) {
        buf.writeln('- $c');
      }
    }
    buf.writeln();

    buf.writeln('### 3. Important Technical Context & Files');
    if (techArtifacts.isEmpty) {
      buf.writeln('- Standard local workspace environment.');
    } else {
      for (final t in techArtifacts.take(8)) {
        buf.writeln('- $t');
      }
    }
    buf.writeln();

    buf.writeln('### 4. Current State & Pending Tasks');
    if (resolutions.isEmpty) {
      buf.writeln('- Context compressed. Continuing active conversation turns.');
    } else {
      for (final r in resolutions.take(4)) {
        buf.writeln('- $r');
      }
    }
    buf.write('</CONTEXT_SUMMARY>');

    return buf.toString();
  }

  /// Extracts sections from a previous `<CONTEXT_SUMMARY>` to prevent context decay.
  static void _extractExistingSummarySections(
    String content, {
    required Set<String> objectives,
    required Set<String> constraints,
    required Set<String> techArtifacts,
    required Set<String> resolutions,
  }) {
    final start = content.indexOf('<CONTEXT_SUMMARY>');
    final end = content.indexOf('</CONTEXT_SUMMARY>');
    final body = (start != -1 && end != -1 && end > start)
        ? content.substring(start + 17, end)
        : content;

    String currentSection = '';
    for (final rawLine in body.split('\n')) {
      final line = rawLine.trim();
      if (line.startsWith('### 1.')) {
        currentSection = 'obj';
      } else if (line.startsWith('### 2.')) {
        currentSection = 'const';
      } else if (line.startsWith('### 3.')) {
        currentSection = 'tech';
      } else if (line.startsWith('### 4.')) {
        currentSection = 'res';
      } else if (line.startsWith('- ') && line.length > 2) {
        final val = line.substring(2).trim();
        if (currentSection == 'obj') objectives.add(val);
        if (currentSection == 'const') constraints.add(val);
        if (currentSection == 'tech') techArtifacts.add(val);
        if (currentSection == 'res') resolutions.add(val);
      }
    }
  }

  /// Extracts the sentence or clause surrounding a keyword.
  static String _extractRelevantClause(String text, String keyword) {
    final sentences = text.split(RegExp(r'(?<=[.!?\n])\s+'));
    for (final s in sentences) {
      if (s.toLowerCase().contains(keyword)) {
        return s.trim();
      }
    }
    return '';
  }

  /// Prepares prompt for model-guided semantic summarization.
  static String _buildModelSummarizationPrompt(List<ChatMessage> toPrune) {
    final transcript = StringBuffer();
    for (final m in toPrune) {
      final role = m.role == 'user' ? 'User' : 'Assistant';
      final clean = m.role == 'assistant'
          ? splitThoughtTags(m.content).answer.trim()
          : m.content.trim();
      if (clean.isNotEmpty) {
        transcript.writeln('[$role]: $clean');
      }
    }

    return '''
You are an expert conversation summarizer for coding and technical work.
Summarize the conversation transcript below into a dense, structured context recap for an LLM assistant.
Preserve user objectives, explicit constraints, technical context, files, error fixes, and state.
Output ONLY in this exact format:

<CONTEXT_SUMMARY>
### 1. Primary Objectives & Topics
- [Primary goals or requests]

### 2. Key Constraints & User Decisions
- [Explicit constraints and user corrections]

### 3. Important Technical Context & Files
- [Files, tools, models, endpoints]

### 4. Current State & Pending Tasks
- [Current state and recent resolutions]
</CONTEXT_SUMMARY>

Transcript to summarize:
$transcript
''';
  }

  /// Sanitizes output from model summarizer to ensure proper XML tags and headers.
  static String _sanitizeModelSummary(String raw) {
    if (raw.contains('<CONTEXT_SUMMARY>') && raw.contains('</CONTEXT_SUMMARY>')) {
      final s = raw.indexOf('<CONTEXT_SUMMARY>');
      final e = raw.indexOf('</CONTEXT_SUMMARY>') + 18;
      return raw.substring(s, e).trim();
    }
    if (raw.contains('### 1.') || raw.contains('Primary Objectives')) {
      return '<CONTEXT_SUMMARY>\n$raw\n</CONTEXT_SUMMARY>';
    }
    return '';
  }
}

