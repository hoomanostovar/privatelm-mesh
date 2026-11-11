import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../core/constants.dart';
import '../utils/thought_parser.dart';
import 'app_log_service.dart';
import 'hive_service.dart';

/// Parsed tool call from a Hermes-style LLM response.
class AgentToolCall {
  final String name;
  final Map<String, dynamic> arguments;
  final String thought;
  final String preambleText;
  final String rawMatch;

  const AgentToolCall({
    required this.name,
    required this.arguments,
    this.thought = '',
    this.preambleText = '',
    this.rawMatch = '',
  });

  String get canonicalSignature {
    final sortedKeys = arguments.keys.toList()..sort();
    final canonicalMap = <String, dynamic>{
      for (final k in sortedKeys) k: arguments[k],
    };
    return '$name:${jsonEncode(canonicalMap)}';
  }
}

/// Result of executing an agent tool.
class AgentToolResult {
  final String toolName;
  final bool ok;
  final bool awaitingApproval;
  final String? pendingCommand;
  final String output;
  final int durationMs;

  const AgentToolResult({
    required this.toolName,
    required this.ok,
    required this.output,
    this.awaitingApproval = false,
    this.pendingCommand,
    this.durationMs = 0,
  });

  String toHermesResponseXml() {
    final payload = <String, dynamic>{
      'name': toolName,
      'status': ok ? 'ok' : 'error',
      'result': output,
    };
    return '<tool_response>\n${jsonEncode(payload)}\n</tool_response>';
  }
}

/// Built-in Hermes-Lite Agent Harness Service.
/// Provides:
/// - Standard Hermes `<tools>` / `<tool_call>` / `<tool_response>` parsing & formatting
/// - 5 built-in local tools: `workspace_files`, `web_search`, `web_fetch`, `memory_store`, `shell_exec`
/// - Sandboxed Agent Workspace directory management
/// - Persistent cross-run Agent Memory Store (backed by Hive + mirrored to `MEMORY.md`)
class AgentHarnessService extends GetxService {
  final HiveService _hive = Get.find<HiveService>();

  final workspacePath = ''.obs;
  final maxSteps = 8.obs;
  final shellPolicy = 'safe_readonly'.obs; // 'safe_readonly', 'ask_approval', 'disabled'
  final idleAwarePause = true.obs;
  final chatAgentModeEnabled = false.obs;

  /// Persistent memory store: key -> { 'value': String, 'updatedAt': String, 'tags': List<String> }
  final memoryEntries = <String, Map<String, dynamic>>{}.obs;

  @override
  void onInit() {
    super.onInit();
    _loadSettings();
    _initWorkspace();
  }

  void _loadSettings() {
    maxSteps.value = _hive.getSetting<int>(
          AppConstants.keyAgentMaxSteps,
          defaultValue: 8,
        ) ??
        8;
    shellPolicy.value = _hive.getSetting<String>(
          AppConstants.keyAgentShellPolicy,
          defaultValue: 'safe_readonly',
        ) ??
        'safe_readonly';
    idleAwarePause.value = _hive.getSetting<bool>(
          AppConstants.keyAgentIdleAwarePause,
          defaultValue: true,
        ) ??
        true;
    chatAgentModeEnabled.value = _hive.getSetting<bool>(
          AppConstants.keyChatAgentModeEnabled,
          defaultValue: false,
        ) ??
        false;

    final rawMem = _hive.getSetting<Map>(AppConstants.keyAgentMemoryStore);
    if (rawMem != null) {
      final loaded = <String, Map<String, dynamic>>{};
      rawMem.forEach((k, v) {
        if (k is String && v is Map) {
          loaded[k] = Map<String, dynamic>.from(v);
        }
      });
      memoryEntries.assignAll(loaded);
    }
  }

  Future<void> _initWorkspace() async {
    if (kIsWeb) return;
    try {
      final saved = _hive.getSetting<String>(AppConstants.keyAgentWorkspacePath);
      if (saved != null && saved.trim().isNotEmpty) {
        final dir = Directory(saved.trim());
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        workspacePath.value = dir.path;
      } else {
        final docs = await getApplicationDocumentsDirectory();
        final defaultDir = Directory(
          '${docs.path}${Platform.pathSeparator}PrivateLM_Agent_Workspace',
        );
        if (!await defaultDir.exists()) {
          await defaultDir.create(recursive: true);
        }
        workspacePath.value = defaultDir.path;
        await _hive.setSetting(
          AppConstants.keyAgentWorkspacePath,
          defaultDir.path,
        );
      }
      await _ensureStarterWorkspaceFiles();
      await _syncMemoryMarkdownFile();
    } catch (e) {
      if (Get.isRegistered<AppLogService>()) {
        Get.find<AppLogService>().warning(
          '[AgentHarness] Workspace init fallback: $e',
        );
      }
    }
  }

  Future<void> _ensureStarterWorkspaceFiles() async {
    if (kIsWeb || workspacePath.value.isEmpty) return;
    try {
      final readmeFile = File(
        '${workspacePath.value}${Platform.pathSeparator}README.md',
      );
      if (!await readmeFile.exists()) {
        await readmeFile.writeAsString(
          '# PrivateLM Agent Workspace\n\n'
          'This folder is the sandboxed workspace for your local **Hermes-Lite** agents.\n\n'
          '- Agents can read, write, append, and search files inside this folder using `workspace_files`.\n'
          '- Persistent facts stored via `memory_store` are automatically mirrored to `MEMORY.md`.\n'
          '- Drop notes, markdown files, CSVs, or code snippets here for background agents to process.\n',
        );
      }
    } catch (_) {}
  }

  Future<void> setWorkspacePath(String newPath) async {
    final trimmed = newPath.trim();
    if (trimmed.isEmpty || kIsWeb) return;
    final dir = Directory(trimmed);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    workspacePath.value = dir.path;
    await _hive.setSetting(AppConstants.keyAgentWorkspacePath, dir.path);
    await _ensureStarterWorkspaceFiles();
    await _syncMemoryMarkdownFile();
  }

  Future<void> setMaxSteps(int steps) async {
    final clamped = steps.clamp(2, 25);
    maxSteps.value = clamped;
    await _hive.setSetting(AppConstants.keyAgentMaxSteps, clamped);
  }

  Future<void> setShellPolicy(String policy) async {
    if (!const ['safe_readonly', 'ask_approval', 'disabled'].contains(policy)) {
      return;
    }
    shellPolicy.value = policy;
    await _hive.setSetting(AppConstants.keyAgentShellPolicy, policy);
  }

  Future<void> setIdleAwarePause(bool enabled) async {
    idleAwarePause.value = enabled;
    await _hive.setSetting(AppConstants.keyAgentIdleAwarePause, enabled);
  }

  Future<void> setChatAgentModeEnabled(bool enabled) async {
    chatAgentModeEnabled.value = enabled;
    await _hive.setSetting(AppConstants.keyChatAgentModeEnabled, enabled);
  }

  Future<void> _saveMemoryToHive() async {
    await _hive.setSetting(
      AppConstants.keyAgentMemoryStore,
      Map<String, dynamic>.from(memoryEntries),
    );
    await _syncMemoryMarkdownFile();
  }

  Future<void> _syncMemoryMarkdownFile() async {
    if (kIsWeb || workspacePath.value.isEmpty) return;
    try {
      final file = File(
        '${workspacePath.value}${Platform.pathSeparator}MEMORY.md',
      );
      final buf = StringBuffer('# Agent Persistent Memory (`memory_store`)\n\n');
      if (memoryEntries.isEmpty) {
        buf.writeln('_No persistent memory entries saved yet._');
      } else {
        final keys = memoryEntries.keys.toList()..sort();
        for (final k in keys) {
          final entry = memoryEntries[k]!;
          final val = entry['value'] ?? '';
          final updatedAt = entry['updatedAt'] ?? '';
          buf.writeln('## `$k`');
          if (updatedAt.toString().isNotEmpty) {
            buf.writeln('_Updated: ${updatedAt}_');
          }
          buf.writeln('\n$val\n');
        }
      }
      await file.writeAsString(buf.toString());
    } catch (_) {}
  }

  // ── Hermes System Prompt & Tool Schema Definitions ──────────────────────

  List<Map<String, dynamic>> getToolDeclarations(List<String> allowedTools) {
    final all = <String, Map<String, dynamic>>{
      'workspace_files': {
        'type': 'function',
        'function': {
          'name': 'workspace_files',
          'description':
              'Read, write, append, list, search, or delete files inside the sandboxed Agent Workspace folder.',
          'parameters': {
            'type': 'object',
            'properties': {
              'action': {
                'type': 'string',
                'enum': ['list', 'read', 'write', 'append', 'search', 'delete'],
                'description': 'Operation to perform in the workspace.',
              },
              'path': {
                'type': 'string',
                'description':
                    'Relative file path inside the workspace (e.g. "notes.md" or "reports/summary.md").',
              },
              'content': {
                'type': 'string',
                'description': 'Text content for write or append actions.',
              },
              'query': {
                'type': 'string',
                'description': 'Keyword or regex pattern for the search action.',
              },
            },
            'required': ['action'],
          },
        },
      },
      'web_search': {
        'type': 'function',
        'function': {
          'name': 'web_search',
          'description':
              'Search the web for current information, articles, documentation, or facts. Returns top results with title, URL, and snippet.',
          'parameters': {
            'type': 'object',
            'properties': {
              'query': {
                'type': 'string',
                'description': 'Search query string.',
              },
              'max_results': {
                'type': 'integer',
                'description': 'Maximum results to return (default 5, max 8).',
              },
            },
            'required': ['query'],
          },
        },
      },
      'web_fetch': {
        'type': 'function',
        'function': {
          'name': 'web_fetch',
          'description':
              'Fetch a webpage URL and extract its main content as clean, readable Markdown.',
          'parameters': {
            'type': 'object',
            'properties': {
              'url': {
                'type': 'string',
                'description': 'Full http:// or https:// URL to fetch.',
              },
            },
            'required': ['url'],
          },
        },
      },
      'memory_store': {
        'type': 'function',
        'function': {
          'name': 'memory_store',
          'description':
              'Persistent key-value memory store across agent runs. Save facts, user preferences, or intermediate findings.',
          'parameters': {
            'type': 'object',
            'properties': {
              'action': {
                'type': 'string',
                'enum': ['set', 'get', 'list', 'delete'],
                'description': 'Memory store action.',
              },
              'key': {
                'type': 'string',
                'description': 'Unique key name (for set, get, delete).',
              },
              'value': {
                'type': 'string',
                'description': 'Fact or markdown note to store (for set).',
              },
            },
            'required': ['action'],
          },
        },
      },
      'shell_exec': {
        'type': 'function',
        'function': {
          'name': 'shell_exec',
          'description':
              'Execute a local shell command inside the Agent Workspace directory to inspect system status, git repos, or environment info.',
          'parameters': {
            'type': 'object',
            'properties': {
              'command': {
                'type': 'string',
                'description': 'Shell command to execute.',
              },
            },
            'required': ['command'],
          },
        },
      },
    };

    final effective = <Map<String, dynamic>>[];
    for (final name in allowedTools) {
      if (name == 'shell_exec' && shellPolicy.value == 'disabled') continue;
      final decl = all[name];
      if (decl != null) effective.add(decl);
    }
    return effective;
  }

  /// Builds the Hermes-style system prompt with `<tools>` declarations.
  String buildHermesSystemPrompt({
    List<String>? allowedTools,
    String? baseSystemPrompt,
  }) {
    final tools = getToolDeclarations(allowedTools ?? TaskModelDefaults.tools);
    final toolsJson = tools.map((t) => jsonEncode(t)).join('\n');

    final memSummary = memoryEntries.isEmpty
        ? 'None saved yet.'
        : memoryEntries.entries
            .take(8)
            .map((e) => '- `${e.key}`: ${_truncateSingleLine(e.value['value']?.toString() ?? '', 90)}')
            .join('\n');

    return '''${baseSystemPrompt ?? 'You are a capable local autonomous agent running on the PrivateLM Hermes-Lite harness.'}

You have access to the following tools to accomplish the user's goal step-by-step:
<tools>
$toolsJson
</tools>

### Tool Calling Rules
1. To call a tool, output a single `<tool_call>` XML block containing valid JSON with `"name"` and `"arguments"`. Examples:
   - List files: `<tool_call>{"name": "workspace_files", "arguments": {"action": "list"}}</tool_call>`
   - Read a file: `<tool_call>{"name": "workspace_files", "arguments": {"action": "read", "path": "README.md"}}</tool_call>`
   - Write a file: `<tool_call>{"name": "workspace_files", "arguments": {"action": "write", "path": "notes.md", "content": "# Notes\nHello"}}</tool_call>`
   - Save memory: `<tool_call>{"name": "memory_store", "arguments": {"action": "set", "key": "status", "value": "ready"}}</tool_call>`
   - Search web: `<tool_call>{"name": "web_search", "arguments": {"query": "topic"}}</tool_call>`
2. Stop immediately after closing `</tool_call>` and wait for the `<tool_response>` before continuing.
3. Call ONE tool per step. Always include `"path"` and `"content"` when writing or appending a file.
4. Once you have gathered enough information or completed all file writes, provide your clear, comprehensive final Markdown answer without any `<tool_call>` tag.

### Environment Context
- **Sandboxed Agent Workspace**: `${workspacePath.value.isEmpty ? './PrivateLM_Agent_Workspace' : workspacePath.value}`
- **Shell Execution Policy**: `${shellPolicy.value}`
- **Stored Memory Keys**:
$memSummary''';
  }

  // ── Hermes Tool Call Parser ─────────────────────────────────────────────

  /// Parses an LLM output string for a Hermes `<tool_call>` (or fallback JSON call).
  /// Returns `null` if the response is a final answer with no tool call.
  static AgentToolCall? parseToolCall(String rawOutput) {
    final parsedThought = splitThoughtTags(rawOutput);
    final thought = parsedThought.thought;
    final visible = parsedThought.answer.trim();

    // 1. Primary: <tool_call> ... </tool_call> (or unclosed <tool_call> at end)
    final xmlRegex = RegExp(
      r'<(?:tool_call|function_call)>\s*([\s\S]*?)(?:</(?:tool_call|function_call)>|$)',
      caseSensitive: false,
    );
    final xmlMatch = xmlRegex.firstMatch(visible);
    if (xmlMatch != null) {
      final inner = xmlMatch.group(1)?.trim() ?? '';
      final preamble = visible.substring(0, xmlMatch.start).trim();
      final decoded = _tryDecodeToolJson(inner);
      if (decoded != null) {
        return AgentToolCall(
          name: decoded.$1,
          arguments: decoded.$2,
          thought: thought,
          preambleText: preamble,
          rawMatch: xmlMatch.group(0) ?? '',
        );
      }
    }

    // 2. Fallback: Fenced ```json or ```tool_call block containing {"name": ..., "arguments": ...}
    final fenceRegex = RegExp(
      r'```(?:json|tool_call|xml)?\s*(\{[\s\S]*?"name"\s*:\s*"(?:workspace_files|web_search|web_fetch|memory_store|shell_exec)"[\s\S]*?\})\s*```',
      caseSensitive: false,
    );
    final fenceMatch = fenceRegex.firstMatch(visible);
    if (fenceMatch != null) {
      final inner = fenceMatch.group(1)?.trim() ?? '';
      final preamble = visible.substring(0, fenceMatch.start).trim();
      final decoded = _tryDecodeToolJson(inner);
      if (decoded != null) {
        return AgentToolCall(
          name: decoded.$1,
          arguments: decoded.$2,
          thought: thought,
          preambleText: preamble,
          rawMatch: fenceMatch.group(0) ?? '',
        );
      }
    }

    // 3. Fallback: Bare JSON object if the entire visible message is a tool call JSON
    if (visible.startsWith('{') && visible.endsWith('}') && visible.contains('"name"')) {
      final decoded = _tryDecodeToolJson(visible);
      if (decoded != null) {
        return AgentToolCall(
          name: decoded.$1,
          arguments: decoded.$2,
          thought: thought,
          preambleText: '',
          rawMatch: visible,
        );
      }
    }

    return null;
  }

  static (String, Map<String, dynamic>)? _tryDecodeToolJson(String rawJson) {
    var cleaned = rawJson.trim();
    // Strip markdown fences if wrapped inside <tool_call>
    if (cleaned.startsWith('```')) {
      cleaned = cleaned
          .replaceFirst(RegExp(r'^```[a-zA-Z0-9_-]*\s*'), '')
          .replaceFirst(RegExp(r'\s*```$'), '')
          .trim();
    }
    final firstBrace = cleaned.indexOf('{');
    final lastBrace = cleaned.lastIndexOf('}');
    if (firstBrace >= 0 && lastBrace > firstBrace) {
      cleaned = cleaned.substring(firstBrace, lastBrace + 1);
    }
    try {
      final obj = jsonDecode(cleaned);
      if (obj is Map) {
        final name = (obj['name'] ?? obj['tool'] ?? obj['function'])?.toString().trim() ?? '';
        if (name.isEmpty) return null;
        final rawArgs = obj['arguments'] ?? obj['parameters'] ?? obj['args'] ?? const {};
        Map<String, dynamic> args = {};
        if (rawArgs is Map) {
          args = Map<String, dynamic>.from(rawArgs);
        } else if (rawArgs is String && rawArgs.trim().startsWith('{')) {
          final parsedArgs = jsonDecode(rawArgs);
          if (parsedArgs is Map) {
            args = Map<String, dynamic>.from(parsedArgs);
          }
        }
        return (name, args);
      }
    } catch (_) {}
    return null;
  }

  // ── Tool Execution Dispatcher ───────────────────────────────────────────

  Future<AgentToolResult> executeToolCall(
    AgentToolCall call, {
    bool shellApprovedByUser = false,
  }) async {
    final sw = Stopwatch()..start();
    try {
      switch (call.name) {
        case 'workspace_files':
          return await _execWorkspaceFiles(call.arguments, sw);
        case 'web_search':
          return await _execWebSearch(call.arguments, sw);
        case 'web_fetch':
          return await _execWebFetch(call.arguments, sw);
        case 'memory_store':
          return await _execMemoryStore(call.arguments, sw);
        case 'shell_exec':
          return await _execShell(
            call.arguments,
            sw,
            approvedByUser: shellApprovedByUser,
          );
        default:
          return AgentToolResult(
            toolName: call.name,
            ok: false,
            output:
                'Unknown tool "${call.name}". Available tools: workspace_files, web_search, web_fetch, memory_store, shell_exec.',
            durationMs: sw.elapsedMilliseconds,
          );
      }
    } catch (e) {
      return AgentToolResult(
        toolName: call.name,
        ok: false,
        output: 'Tool execution error: $e',
        durationMs: sw.elapsedMilliseconds,
      );
    }
  }

  // ── Tool 1: workspace_files (Sandboxed Local File I/O) ──────────────────

  File? _resolveSandboxedFile(String relativePath) {
    if (kIsWeb || workspacePath.value.isEmpty) return null;
    final cleanRel = relativePath
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'^/+'), '')
        .trim();
    if (cleanRel.isEmpty || cleanRel.split('/').contains('..')) {
      return null;
    }
    final rootDir = Directory(workspacePath.value).absolute;
    final target = File(
      '${rootDir.path}${Platform.pathSeparator}${cleanRel.replaceAll('/', Platform.pathSeparator)}',
    ).absolute;
    if (!target.path.toLowerCase().startsWith(rootDir.path.toLowerCase())) {
      return null;
    }
    return target;
  }

  Future<AgentToolResult> _execWorkspaceFiles(
    Map<String, dynamic> args,
    Stopwatch sw,
  ) async {
    if (kIsWeb || workspacePath.value.isEmpty) {
      return AgentToolResult(
        toolName: 'workspace_files',
        ok: false,
        output: 'Workspace files tool is not available on Web.',
        durationMs: sw.elapsedMilliseconds,
      );
    }

    final action = (args['action'] ?? 'list').toString().toLowerCase().trim();
    final relPath = (args['path'] ??
            args['file'] ??
            args['filename'] ??
            args['filepath'] ??
            args['name'] ??
            args['target'] ??
            '')
        .toString()
        .trim();

    if (action == 'list') {
      final rootDir = Directory(workspacePath.value);
      if (!await rootDir.exists()) {
        await rootDir.create(recursive: true);
      }
      final entities = await rootDir.list(recursive: true).toList();
      if (entities.isEmpty) {
        return AgentToolResult(
          toolName: 'workspace_files',
          ok: true,
          output: 'Workspace (${rootDir.path}) is currently empty.',
          durationMs: sw.elapsedMilliseconds,
        );
      }
      final lines = <String>[
        'Workspace root: ${rootDir.path}',
        'Files (${entities.whereType<File>().length}):',
      ];
      for (final entity in entities) {
        if (entity is File) {
          final rel = entity.path
              .substring(rootDir.path.length)
              .replaceAll(RegExp(r'^[\\/]+'), '');
          final stat = await entity.stat();
          lines.add('- $rel (${stat.size} bytes, modified ${stat.modified.toIso8601String()})');
        }
      }
      return AgentToolResult(
        toolName: 'workspace_files',
        ok: true,
        output: lines.join('\n'),
        durationMs: sw.elapsedMilliseconds,
      );
    }

    if (action == 'search') {
      final query = (args['query'] ?? args['pattern'] ?? relPath).toString().trim();
      if (query.isEmpty) {
        return AgentToolResult(
          toolName: 'workspace_files',
          ok: false,
          output: 'Missing "query" parameter for workspace_files search.',
          durationMs: sw.elapsedMilliseconds,
        );
      }
      final rootDir = Directory(workspacePath.value);
      final entities = await rootDir.list(recursive: true).toList();
      final matches = <String>[];
      final lowerQuery = query.toLowerCase();
      for (final entity in entities) {
        if (entity is File) {
          try {
            final content = await entity.readAsString();
            final fileLines = content.split('\n');
            final rel = entity.path
                .substring(rootDir.path.length)
                .replaceAll(RegExp(r'^[\\/]+'), '');
            for (var i = 0; i < fileLines.length; i++) {
              if (fileLines[i].toLowerCase().contains(lowerQuery)) {
                matches.add('$rel:${i + 1}: ${_truncateSingleLine(fileLines[i], 140)}');
                if (matches.length >= 40) break;
              }
            }
          } catch (_) {}
        }
        if (matches.length >= 40) break;
      }
      return AgentToolResult(
        toolName: 'workspace_files',
        ok: true,
        output: matches.isEmpty
            ? 'No matches found for "$query" in workspace.'
            : 'Found ${matches.length} match(es) for "$query":\n${matches.join('\n')}',
        durationMs: sw.elapsedMilliseconds,
      );
    }

    final file = _resolveSandboxedFile(relPath);
    if (file == null) {
      return AgentToolResult(
        toolName: 'workspace_files',
        ok: false,
        output:
            'Invalid or outside-sandbox path "$relPath". Provide a relative path inside the Agent Workspace (e.g. "report.md").',
        durationMs: sw.elapsedMilliseconds,
      );
    }

    if (action == 'read') {
      if (!await file.exists()) {
        return AgentToolResult(
          toolName: 'workspace_files',
          ok: false,
          output: 'File "$relPath" does not exist in the workspace.',
          durationMs: sw.elapsedMilliseconds,
        );
      }
      final text = await file.readAsString();
      return AgentToolResult(
        toolName: 'workspace_files',
        ok: true,
        output: _capToolOutput(text, maxChars: 6000),
        durationMs: sw.elapsedMilliseconds,
      );
    }

    if (action == 'write') {
      final content = (args['content'] ?? args['text'] ?? '').toString();
      await file.parent.create(recursive: true);
      await file.writeAsString(content);
      return AgentToolResult(
        toolName: 'workspace_files',
        ok: true,
        output: 'Wrote ${content.length} chars to "$relPath".',
        durationMs: sw.elapsedMilliseconds,
      );
    }

    if (action == 'append') {
      final content = (args['content'] ?? args['text'] ?? '').toString();
      await file.parent.create(recursive: true);
      await file.writeAsString(content, mode: FileMode.append);
      return AgentToolResult(
        toolName: 'workspace_files',
        ok: true,
        output: 'Appended ${content.length} chars to "$relPath".',
        durationMs: sw.elapsedMilliseconds,
      );
    }

    if (action == 'delete') {
      if (await file.exists()) {
        await file.delete();
        return AgentToolResult(
          toolName: 'workspace_files',
          ok: true,
          output: 'Deleted "$relPath" from workspace.',
          durationMs: sw.elapsedMilliseconds,
        );
      }
      return AgentToolResult(
        toolName: 'workspace_files',
        ok: false,
        output: 'File "$relPath" not found.',
        durationMs: sw.elapsedMilliseconds,
      );
    }

    return AgentToolResult(
      toolName: 'workspace_files',
      ok: false,
      output:
          'Unsupported workspace_files action "$action". Use list, read, write, append, search, or delete.',
      durationMs: sw.elapsedMilliseconds,
    );
  }

  // ── Tool 2: web_search (Keyless DuckDuckGo HTML Search) ─────────────────

  Future<AgentToolResult> _execWebSearch(
    Map<String, dynamic> args,
    Stopwatch sw,
  ) async {
    final query = (args['query'] ?? args['q'] ?? '').toString().trim();
    if (query.isEmpty) {
      return AgentToolResult(
        toolName: 'web_search',
        ok: false,
        output: 'Missing "query" argument for web_search.',
        durationMs: sw.elapsedMilliseconds,
      );
    }
    final maxResults =
        ((args['max_results'] as num?)?.toInt() ?? 5).clamp(1, 8);

    try {
      final uri = Uri.https('html.duckduckgo.com', '/html/', {'q': query});
      final res = await http.get(
        uri,
        headers: const {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
          'Accept': 'text/html,application/xhtml+xml',
        },
      ).timeout(const Duration(seconds: 12));

      if (res.statusCode != 200) {
        return AgentToolResult(
          toolName: 'web_search',
          ok: false,
          output: 'Search HTTP status ${res.statusCode} for "$query".',
          durationMs: sw.elapsedMilliseconds,
        );
      }

      final parsed = extractDuckDuckGoResults(res.body, maxResults: maxResults);
      if (parsed.isEmpty) {
        return AgentToolResult(
          toolName: 'web_search',
          ok: true,
          output: 'No web search results found for "$query".',
          durationMs: sw.elapsedMilliseconds,
        );
      }

      final buf = StringBuffer('Web search results for "$query":\n\n');
      for (var i = 0; i < parsed.length; i++) {
        final r = parsed[i];
        buf.writeln('${i + 1}. **${r['title']}**');
        buf.writeln('   URL: ${r['url']}');
        if ((r['snippet'] ?? '').isNotEmpty) {
          buf.writeln('   Snippet: ${r['snippet']}');
        }
        buf.writeln();
      }
      return AgentToolResult(
        toolName: 'web_search',
        ok: true,
        output: buf.toString().trim(),
        durationMs: sw.elapsedMilliseconds,
      );
    } catch (e) {
      return AgentToolResult(
        toolName: 'web_search',
        ok: false,
        output: 'Web search failed: $e',
        durationMs: sw.elapsedMilliseconds,
      );
    }
  }

  @visibleForTesting
  static List<Map<String, String>> extractDuckDuckGoResults(
    String htmlBody, {
    int maxResults = 5,
  }) {
    final results = <Map<String, String>>[];
    final linkRegex = RegExp(
      r'<a[^>]+class="[^"]*result__a[^"]*"[^>]+href="([^"]+)"[^>]*>([\s\S]*?)</a>',
      caseSensitive: false,
    );
    final snippetRegex = RegExp(
      r'<a[^>]+class="[^"]*result__snippet[^"]*"[^>]*>([\s\S]*?)</a>',
      caseSensitive: false,
    );

    final links = linkRegex.allMatches(htmlBody).toList();
    final snippets = snippetRegex.allMatches(htmlBody).toList();

    for (var i = 0; i < links.length && results.length < maxResults; i++) {
      var rawHref = links[i].group(1) ?? '';
      final uddgMatch = RegExp(r'[?&]uddg=([^&]+)').firstMatch(rawHref);
      if (uddgMatch != null) {
        rawHref = Uri.decodeComponent(uddgMatch.group(1)!);
      } else if (rawHref.startsWith('//')) {
        rawHref = 'https:$rawHref';
      }
      final title = _stripHtmlTags(links[i].group(2) ?? '').trim();
      final snippet = i < snippets.length
          ? _stripHtmlTags(snippets[i].group(1) ?? '').trim()
          : '';
      if (title.isNotEmpty && rawHref.startsWith('http')) {
        results.add({
          'title': title,
          'url': rawHref,
          'snippet': snippet,
        });
      }
    }
    return results;
  }

  // ── Tool 3: web_fetch (Clean HTML -> Markdown Extractor) ────────────────

  Future<AgentToolResult> _execWebFetch(
    Map<String, dynamic> args,
    Stopwatch sw,
  ) async {
    final urlStr = (args['url'] ?? '').toString().trim();
    final uri = Uri.tryParse(urlStr);
    if (uri == null || (!uri.isScheme('http') && !uri.isScheme('https'))) {
      return AgentToolResult(
        toolName: 'web_fetch',
        ok: false,
        output: 'Invalid URL "$urlStr". Provide a full http:// or https:// URL.',
        durationMs: sw.elapsedMilliseconds,
      );
    }

    try {
      final res = await http.get(
        uri,
        headers: const {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
          'Accept': 'text/html,application/xhtml+xml,text/plain,application/json',
        },
      ).timeout(const Duration(seconds: 15));

      if (res.statusCode < 200 || res.statusCode >= 400) {
        return AgentToolResult(
          toolName: 'web_fetch',
          ok: false,
          output: 'HTTP ${res.statusCode} when fetching $urlStr.',
          durationMs: sw.elapsedMilliseconds,
        );
      }

      final markdown = htmlToCleanMarkdown(res.body, sourceUrl: urlStr);
      return AgentToolResult(
        toolName: 'web_fetch',
        ok: true,
        output: _capToolOutput(markdown, maxChars: 5500),
        durationMs: sw.elapsedMilliseconds,
      );
    } catch (e) {
      return AgentToolResult(
        toolName: 'web_fetch',
        ok: false,
        output: 'Failed to fetch $urlStr: $e',
        durationMs: sw.elapsedMilliseconds,
      );
    }
  }

  @visibleForTesting
  static String htmlToCleanMarkdown(String html, {String? sourceUrl}) {
    var s = html;
    // Extract <title> if present
    final titleMatch = RegExp(
      r'<title[^>]*>([\s\S]*?)</title>',
      caseSensitive: false,
    ).firstMatch(s);
    final pageTitle =
        titleMatch != null ? _stripHtmlTags(titleMatch.group(1)!).trim() : '';

    // Remove script, style, svg, noscript, nav, footer, header tags
    s = s.replaceAll(
      RegExp(
        r'<(script|style|svg|noscript|nav|footer|iframe)[^>]*>[\s\S]*?</\1>',
        caseSensitive: false,
      ),
      ' ',
    );

    // Convert headings
    s = s.replaceAllMapped(
      RegExp(r'<h1[^>]*>([\s\S]*?)</h1>', caseSensitive: false),
      (m) => '\n\n# ${_stripHtmlTags(m.group(1)!).trim()}\n\n',
    );
    s = s.replaceAllMapped(
      RegExp(r'<h2[^>]*>([\s\S]*?)</h2>', caseSensitive: false),
      (m) => '\n\n## ${_stripHtmlTags(m.group(1)!).trim()}\n\n',
    );
    s = s.replaceAllMapped(
      RegExp(r'<h3[^>]*>([\s\S]*?)</h3>', caseSensitive: false),
      (m) => '\n\n### ${_stripHtmlTags(m.group(1)!).trim()}\n\n',
    );

    // Convert list items and paragraphs
    s = s.replaceAllMapped(
      RegExp(r'<li[^>]*>([\s\S]*?)</li>', caseSensitive: false),
      (m) => '\n- ${_stripHtmlTags(m.group(1)!).trim()}',
    );
    s = s.replaceAll(
      RegExp(r'</?(p|div|section|article|br|tr)[^>]*>', caseSensitive: false),
      '\n',
    );

    // Strip remaining tags and normalize whitespace
    s = _stripHtmlTags(s);
    final cleanedLines = s
        .split('\n')
        .map((l) => l.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((l) => l.isNotEmpty)
        .toList();

    final buf = StringBuffer();
    if (pageTitle.isNotEmpty) {
      buf.writeln('# $pageTitle');
    }
    if (sourceUrl != null && sourceUrl.isNotEmpty) {
      buf.writeln('Source: $sourceUrl\n');
    }
    buf.write(cleanedLines.join('\n'));
    return buf.toString().trim();
  }

  static String _stripHtmlTags(String input) {
    return input
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&#x27;', "'")
        .replaceAll(RegExp(r'\s+'), ' ');
  }

  // ── Tool 4: memory_store (Persistent Cross-Run Scratchpad) ──────────────

  Future<AgentToolResult> _execMemoryStore(
    Map<String, dynamic> args,
    Stopwatch sw,
  ) async {
    final action = (args['action'] ?? 'list').toString().toLowerCase().trim();
    final key = (args['key'] ?? '').toString().trim();

    if (action == 'set') {
      if (key.isEmpty) {
        return AgentToolResult(
          toolName: 'memory_store',
          ok: false,
          output: 'Missing "key" parameter for memory_store set.',
          durationMs: sw.elapsedMilliseconds,
        );
      }
      final value = (args['value'] ?? args['content'] ?? '').toString();
      memoryEntries[key] = {
        'value': value,
        'updatedAt': DateTime.now().toIso8601String(),
      };
      await _saveMemoryToHive();
      return AgentToolResult(
        toolName: 'memory_store',
        ok: true,
        output: 'Saved key "$key" to persistent memory store (and synced to MEMORY.md).',
        durationMs: sw.elapsedMilliseconds,
      );
    }

    if (action == 'get') {
      if (key.isEmpty) {
        return AgentToolResult(
          toolName: 'memory_store',
          ok: false,
          output: 'Missing "key" parameter for memory_store get.',
          durationMs: sw.elapsedMilliseconds,
        );
      }
      final entry = memoryEntries[key];
      if (entry == null) {
        return AgentToolResult(
          toolName: 'memory_store',
          ok: false,
          output: 'Key "$key" not found in memory_store.',
          durationMs: sw.elapsedMilliseconds,
        );
      }
      return AgentToolResult(
        toolName: 'memory_store',
        ok: true,
        output: '${entry['value']}',
        durationMs: sw.elapsedMilliseconds,
      );
    }

    if (action == 'delete') {
      if (memoryEntries.remove(key) != null) {
        await _saveMemoryToHive();
        return AgentToolResult(
          toolName: 'memory_store',
          ok: true,
          output: 'Deleted key "$key" from memory_store.',
          durationMs: sw.elapsedMilliseconds,
        );
      }
      return AgentToolResult(
        toolName: 'memory_store',
        ok: false,
        output: 'Key "$key" not found.',
        durationMs: sw.elapsedMilliseconds,
      );
    }

    // Default: list
    if (memoryEntries.isEmpty) {
      return AgentToolResult(
        toolName: 'memory_store',
        ok: true,
        output: 'Memory store is currently empty.',
        durationMs: sw.elapsedMilliseconds,
      );
    }
    final lines = memoryEntries.entries
        .map((e) => '- ${e.key}: ${e.value['value']}')
        .join('\n');
    return AgentToolResult(
      toolName: 'memory_store',
      ok: true,
      output: 'Stored memory entries (${memoryEntries.length}):\n$lines',
      durationMs: sw.elapsedMilliseconds,
    );
  }

  // ── Tool 5: shell_exec (Safe / Approval-Gated Shell Runner) ─────────────

  @visibleForTesting
  static bool isSafeReadonlyCommand(String cmd) {
    final trimmed = cmd.trim();
    if (trimmed.isEmpty) return false;
    final lower = trimmed.toLowerCase();

    // Block redirection, destructive commands, or command chaining
    const forbidden = [
      'rm ',
      'del ',
      'remove-item',
      'rmdir',
      'format ',
      'shutdown',
      'reboot',
      'stop-process',
      'taskkill',
      'kill ',
      'reg delete',
      'reg add',
      'sc delete',
      'mkfs',
      'dd ',
      '>',
      '| iex',
      'invoke-expression',
      'curl ',
      'wget ',
      'invoke-webrequest',
    ];
    for (final bad in forbidden) {
      if (lower.contains(bad)) return false;
    }

    const allowedPrefixes = [
      'dir',
      'ls',
      'get-childitem',
      'cat ',
      'type ',
      'get-content',
      'echo ',
      'write-output',
      'pwd',
      'get-location',
      'whoami',
      'hostname',
      'date',
      'get-date',
      'systeminfo',
      'uname',
      'df',
      'free',
      'ps',
      'tasklist',
      'get-process',
      'where ',
      'which ',
      'findstr ',
      'grep ',
      'git status',
      'git log',
      'git diff',
      'git branch',
      'python --version',
      'dart --version',
      'flutter --version',
    ];
    return allowedPrefixes.any(
      (p) => lower == p.trim() || lower.startsWith(p),
    );
  }

  Future<AgentToolResult> _execShell(
    Map<String, dynamic> args,
    Stopwatch sw, {
    bool approvedByUser = false,
  }) async {
    if (kIsWeb) {
      return AgentToolResult(
        toolName: 'shell_exec',
        ok: false,
        output: 'shell_exec is not supported on Web.',
        durationMs: sw.elapsedMilliseconds,
      );
    }

    final command = (args['command'] ?? args['cmd'] ?? '').toString().trim();
    if (command.isEmpty) {
      return AgentToolResult(
        toolName: 'shell_exec',
        ok: false,
        output: 'Missing "command" parameter for shell_exec.',
        durationMs: sw.elapsedMilliseconds,
      );
    }

    final policy = shellPolicy.value;
    if (policy == 'disabled') {
      return AgentToolResult(
        toolName: 'shell_exec',
        ok: false,
        output: 'shell_exec is disabled in Agent Settings.',
        durationMs: sw.elapsedMilliseconds,
      );
    }

    if (policy == 'safe_readonly' && !approvedByUser) {
      if (!isSafeReadonlyCommand(command)) {
        return AgentToolResult(
          toolName: 'shell_exec',
          ok: false,
          output:
              'Blocked by safe_readonly policy: "$command" is not on the read-only allowlist. Use workspace_files for file edits or switch shell policy to "ask_approval" in Agent Settings.',
          durationMs: sw.elapsedMilliseconds,
        );
      }
    } else if (policy == 'ask_approval' && !approvedByUser) {
      return AgentToolResult(
        toolName: 'shell_exec',
        ok: false,
        awaitingApproval: true,
        pendingCommand: command,
        output: 'Awaiting user approval to execute: $command',
        durationMs: sw.elapsedMilliseconds,
      );
    }

    try {
      final workDir = workspacePath.value.isNotEmpty
          ? workspacePath.value
          : Directory.current.path;
      final ProcessResult res;
      if (Platform.isWindows) {
        res = await Process.run(
          'powershell',
          ['-NoProfile', '-NonInteractive', '-Command', command],
          workingDirectory: workDir,
        ).timeout(const Duration(seconds: 15));
      } else {
        res = await Process.run(
          '/bin/sh',
          ['-c', command],
          workingDirectory: workDir,
        ).timeout(const Duration(seconds: 15));
      }

      final stdoutStr = res.stdout.toString().trim();
      final stderrStr = res.stderr.toString().trim();
      final combined = [
        'Exit code: ${res.exitCode}',
        if (stdoutStr.isNotEmpty) 'STDOUT:\n$stdoutStr',
        if (stderrStr.isNotEmpty) 'STDERR:\n$stderrStr',
      ].join('\n\n');

      return AgentToolResult(
        toolName: 'shell_exec',
        ok: res.exitCode == 0,
        output: _capToolOutput(combined, maxChars: 4000),
        durationMs: sw.elapsedMilliseconds,
      );
    } catch (e) {
      return AgentToolResult(
        toolName: 'shell_exec',
        ok: false,
        output: 'Shell execution failed or timed out: $e',
        durationMs: sw.elapsedMilliseconds,
      );
    }
  }

  static String _capToolOutput(String text, {int maxChars = 5000}) {
    if (text.length <= maxChars) return text;
    final head = (maxChars * 0.7).round();
    final tail = maxChars - head;
    final omitted = text.length - maxChars;
    return '${text.substring(0, head)}\n\n... [$omitted characters truncated to fit local context window] ...\n\n${text.substring(text.length - tail)}';
  }

  static String _truncateSingleLine(String text, int maxLen) {
    final single = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (single.length <= maxLen) return single;
    return '${single.substring(0, maxLen - 1)}…';
  }
}

abstract class TaskModelDefaults {
  static const List<String> tools = [
    'workspace_files',
    'web_search',
    'web_fetch',
    'memory_store',
    'shell_exec',
  ];
}

