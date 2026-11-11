import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

import '../core/constants.dart';
import '../models/task_model.dart';
import '../services/agent_harness_service.dart';
import '../services/app_log_service.dart';
import '../services/cloud_service.dart';
import '../services/hive_service.dart';
import '../services/inference_service.dart';
import '../utils/thought_parser.dart';
import 'chat_controller.dart';
import 'settings_controller.dart';

class TaskController extends GetxController {
  final HiveService _hive = Get.find<HiveService>();
  final AgentHarnessService harness = Get.find<AgentHarnessService>();
  final _uuid = const Uuid();

  final tasks = <TaskModel>[].obs;
  final currentTask = Rxn<TaskModel>();
  final isPlanning = false.obs;
  final isExecuting = false.obs;
  final isPausedForChat = false.obs;
  final activeStepOutputStream = ''.obs;

  Completer<bool>? _shellApprovalCompleter;
  bool _cancelRequested = false;
  Timer? _schedulerTimer;
  final Map<String, DateTime> _workspaceSnapshot = <String, DateTime>{};

  @override
  void onInit() {
    super.onInit();
    loadTasks();
    _initScheduler();
    // Resume any queued tasks after startup
    Future.delayed(const Duration(seconds: 2), _processQueueIfIdle);
  }

  @override
  void onClose() {
    _schedulerTimer?.cancel();
    super.onClose();
  }

  void loadTasks() {
    final raw = _hive.getAllTasks();
    tasks.value = raw.map((m) => TaskModel.fromMap(m)).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    // Normalize any interrupted 'running' tasks from a previous app session back to 'queued'
    for (var i = 0; i < tasks.length; i++) {
      final t = tasks[i];
      if (t.status == 'running' || t.status == 'paused_for_chat') {
        final reset = t.copyWith(status: 'queued');
        tasks[i] = reset;
        _hive.saveTask(reset.id, reset.toMap());
      }
    }
  }

  void _initScheduler() {
    _captureWorkspaceSnapshot();
    _schedulerTimer = Timer.periodic(const Duration(seconds: 25), (_) async {
      await _checkScheduledAndWatchTasks();
      _processQueueIfIdle();
    });
  }

  Future<void> _captureWorkspaceSnapshot() async {
    if (kIsWeb || harness.workspacePath.value.isEmpty) return;
    try {
      final dir = Directory(harness.workspacePath.value);
      if (!await dir.exists()) return;
      final entities = await dir.list(recursive: true).toList();
      _workspaceSnapshot.clear();
      for (final e in entities) {
        if (e is File && !e.path.endsWith('MEMORY.md')) {
          final stat = await e.stat();
          _workspaceSnapshot[e.path] = stat.modified;
        }
      }
    } catch (_) {}
  }

  Future<bool> _detectWorkspaceFileChange() async {
    if (kIsWeb || harness.workspacePath.value.isEmpty) return false;
    try {
      final dir = Directory(harness.workspacePath.value);
      if (!await dir.exists()) return false;
      final entities = await dir.list(recursive: true).toList();
      bool changed = false;
      final next = <String, DateTime>{};
      for (final e in entities) {
        if (e is File && !e.path.endsWith('MEMORY.md')) {
          final stat = await e.stat();
          next[e.path] = stat.modified;
          final prev = _workspaceSnapshot[e.path];
          if (prev == null || stat.modified.isAfter(prev)) {
            changed = true;
          }
        }
      }
      if (changed) {
        _workspaceSnapshot
          ..clear()
          ..addAll(next);
      }
      return changed;
    } catch (_) {
      return false;
    }
  }

  Future<void> _checkScheduledAndWatchTasks() async {
    if (isExecuting.value) return;
    final now = DateTime.now();
    final workspaceChanged = await _detectWorkspaceFileChange();

    for (final task in tasks) {
      if (task.status == 'queued' || task.isActive) continue;
      if (!task.isRecurring) continue;

      final last = task.lastRunAt ?? task.completedAt ?? task.createdAt;
      bool shouldTrigger = false;

      switch (task.schedule) {
        case 'hourly':
          shouldTrigger = now.difference(last) >= const Duration(hours: 1);
          break;
        case 'every_6h':
          shouldTrigger = now.difference(last) >= const Duration(hours: 6);
          break;
        case 'daily':
          shouldTrigger = now.difference(last) >= const Duration(hours: 24);
          break;
        case 'watch_workspace':
          shouldTrigger =
              workspaceChanged && now.difference(last) >= const Duration(seconds: 30);
          break;
      }

      if (shouldTrigger) {
        final requeued = task.copyWith(
          status: 'queued',
          steps: [],
          finalAnswer: null,
        );
        _updateTask(requeued);
      }
    }
  }

  void _processQueueIfIdle() {
    if (isExecuting.value) return;
    final nextTask = tasks.firstWhereOrNull((t) => t.status == 'queued');
    if (nextTask != null) {
      executeTask(nextTask);
    }
  }

  /// Create and enqueue a new Hermes-Lite agent task.
  Future<void> createTask(
    String goal, {
    String schedule = 'once',
    int? maxSteps,
    List<String>? allowedTools,
    bool runImmediately = true,
  }) async {
    if (goal.trim().isEmpty) return;

    final taskId = _uuid.v4();
    final task = TaskModel(
      id: taskId,
      goal: goal.trim(),
      status: 'queued',
      schedule: schedule,
      maxSteps: maxSteps ?? harness.maxSteps.value,
      allowedTools: allowedTools ?? TaskModel.defaultTools,
    );

    tasks.insert(0, task);
    await _hive.saveTask(taskId, task.toMap());
    currentTask.value = task;

    if (runImmediately && !isExecuting.value) {
      await executeTask(task);
    }
  }

  /// Cancel the currently running task.
  void cancelCurrentTask() {
    _cancelRequested = true;
    if (_shellApprovalCompleter != null && !_shellApprovalCompleter!.isCompleted) {
      _shellApprovalCompleter!.complete(false);
    }
    try {
      Get.find<InferenceService>().stopGeneration();
    } catch (_) {}
  }

  void approvePendingShellCommand() {
    if (_shellApprovalCompleter != null && !_shellApprovalCompleter!.isCompleted) {
      _shellApprovalCompleter!.complete(true);
    }
  }

  void rejectPendingShellCommand() {
    if (_shellApprovalCompleter != null && !_shellApprovalCompleter!.isCompleted) {
      _shellApprovalCompleter!.complete(false);
    }
  }

  /// Waits if the user is actively chatting in the main Chat tab ("Chug Mode").
  Future<void> _waitWhileUserChatBusy(TaskModel task) async {
    if (!harness.idleAwarePause.value) return;
    if (!Get.isRegistered<ChatController>()) return;
    final chat = Get.find<ChatController>();

    if (chat.isLoading.value || chat.isStreaming.value) {
      isPausedForChat.value = true;
      _updateTask(task.copyWith(status: 'paused_for_chat'));
      while ((chat.isLoading.value || chat.isStreaming.value) && !_cancelRequested) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
      isPausedForChat.value = false;
      if (!_cancelRequested) {
        _updateTask(task.copyWith(status: 'running'));
      }
    }
  }

  /// Execute a Hermes-Lite ReAct loop for the given [task].
  Future<void> executeTask(TaskModel task) async {
    if (isExecuting.value) return;
    isExecuting.value = true;
    _cancelRequested = false;
    activeStepOutputStream.value = '';

    var workingTask = task.copyWith(
      status: 'running',
      steps: [],
      finalAnswer: null,
      lastRunAt: DateTime.now(),
    );
    _updateTask(workingTask);

    final steps = <TaskStep>[];
    final seenCalls = <String>{};
    final conversation = <Map<String, String>>[];
    final systemPrompt = harness.buildHermesSystemPrompt(
      allowedTools: workingTask.allowedTools,
    );

    try {
      var nextPrompt = 'Goal: ${workingTask.goal}\n\n'
          'Think step-by-step and call one tool at a time using <tool_call> if needed, or provide the final answer once complete.';

      for (var stepIdx = 0; stepIdx < workingTask.maxSteps; stepIdx++) {
        if (_cancelRequested) {
          workingTask = workingTask.copyWith(
            steps: List<TaskStep>.from(steps),
            status: 'cancelled',
          );
          _updateTask(workingTask);
          break;
        }

        await _waitWhileUserChatBusy(workingTask);
        if (_cancelRequested) break;

        activeStepOutputStream.value = '';
        final stepPlaceholder = TaskStep(
          index: stepIdx,
          description: 'Step ${stepIdx + 1}: Thinking…',
          status: 'running',
          timestamp: DateTime.now(),
        );
        steps.add(stepPlaceholder);
        workingTask = workingTask.copyWith(steps: List<TaskStep>.from(steps));
        _updateTask(workingTask);

        final rawResponse = await _generateAgentStep(
          prompt: nextPrompt,
          systemPrompt: systemPrompt,
          history: conversation,
          onToken: (tok) {
            activeStepOutputStream.value += tok;
          },
        );

        if (_cancelRequested) {
          steps[stepIdx] = stepPlaceholder.copyWith(
            status: 'failed',
            description: 'Cancelled by user.',
          );
          workingTask = workingTask.copyWith(
            steps: List<TaskStep>.from(steps),
            status: 'cancelled',
          );
          _updateTask(workingTask);
          break;
        }

        final toolCall = AgentHarnessService.parseToolCall(rawResponse);

        if (toolCall == null) {
          // Model finished and returned its synthesized final answer!
          final parsed = splitThoughtTags(rawResponse);
          final finalAnswer = parsed.answer.trim().isNotEmpty
              ? parsed.answer.trim()
              : rawResponse.trim();

          steps[stepIdx] = TaskStep(
            index: stepIdx,
            description: 'Synthesized final response',
            thought: parsed.thought.isNotEmpty ? parsed.thought : null,
            toolName: 'final_answer',
            status: 'done',
            output: finalAnswer,
            timestamp: DateTime.now(),
          );
          workingTask = workingTask.copyWith(
            steps: List<TaskStep>.from(steps),
            status: 'completed',
            finalAnswer: finalAnswer,
            completedAt: DateTime.now(),
            lastRunAt: DateTime.now(),
          );
          _updateTask(workingTask);
          break;
        }

        // Check duplicate-call guardrail
        final sig = toolCall.canonicalSignature;
        if (seenCalls.contains(sig)) {
          const guardrailMsg =
              'Duplicate tool call detected: you already called this tool with the exact same arguments. Use the previous result to proceed to the next step or write your final answer.';
          steps[stepIdx] = TaskStep(
            index: stepIdx,
            description: 'Duplicate call guardrail (${toolCall.name})',
            thought: toolCall.thought.isNotEmpty ? toolCall.thought : null,
            toolName: toolCall.name,
            toolArgs: jsonEncode(toolCall.arguments),
            status: 'done',
            output: guardrailMsg,
            timestamp: DateTime.now(),
          );
          workingTask = workingTask.copyWith(steps: List<TaskStep>.from(steps));
          _updateTask(workingTask);

          conversation.add({'role': 'user', 'content': nextPrompt});
          conversation.add({
            'role': 'assistant',
            'content':
                '<tool_call>\n${jsonEncode({'name': toolCall.name, 'arguments': toolCall.arguments})}\n</tool_call>',
          });
          nextPrompt =
              '<tool_response>\n${jsonEncode({'name': toolCall.name, 'status': 'warning', 'result': guardrailMsg})}\n</tool_response>';
          continue;
        }
        seenCalls.add(sig);

        final stepDesc = toolCall.preambleText.isNotEmpty
            ? toolCall.preambleText
            : _describeToolCall(toolCall);

        steps[stepIdx] = TaskStep(
          index: stepIdx,
          description: stepDesc,
          thought: toolCall.thought.isNotEmpty ? toolCall.thought : null,
          toolName: toolCall.name,
          toolArgs: jsonEncode(toolCall.arguments),
          command: toolCall.name == 'shell_exec'
              ? toolCall.arguments['command']?.toString()
              : null,
          status: 'running',
          timestamp: DateTime.now(),
        );
        workingTask = workingTask.copyWith(steps: List<TaskStep>.from(steps));
        _updateTask(workingTask);

        // Execute tool
        var toolResult = await harness.executeToolCall(toolCall);

        // Handle interactive approval gate for shell_exec
        if (toolResult.awaitingApproval) {
          steps[stepIdx] = steps[stepIdx].copyWith(
            status: 'awaiting_approval',
            output: toolResult.output,
          );
          workingTask = workingTask.copyWith(
            steps: List<TaskStep>.from(steps),
            status: 'awaiting_approval',
          );
          _updateTask(workingTask);

          _shellApprovalCompleter = Completer<bool>();
          final approved = await _shellApprovalCompleter!.future;
          _shellApprovalCompleter = null;

          if (approved && !_cancelRequested) {
            workingTask = workingTask.copyWith(status: 'running');
            _updateTask(workingTask);
            toolResult = await harness.executeToolCall(
              toolCall,
              shellApprovedByUser: true,
            );
          } else {
            toolResult = AgentToolResult(
              toolName: 'shell_exec',
              ok: false,
              output: 'User rejected execution of shell command: ${toolResult.pendingCommand}',
            );
          }
        }

        steps[stepIdx] = steps[stepIdx].copyWith(
          status: toolResult.ok ? 'done' : 'failed',
          output: toolResult.output,
          durationMs: toolResult.durationMs,
        );
        workingTask = workingTask.copyWith(steps: List<TaskStep>.from(steps));
        _updateTask(workingTask);

        // Append turn to ReAct conversation history & compact if needed
        conversation.add({'role': 'user', 'content': nextPrompt});
        conversation.add({
          'role': 'assistant',
          'content':
              '<tool_call>\n${jsonEncode({'name': toolCall.name, 'arguments': toolCall.arguments})}\n</tool_call>',
        });
        _compactAgentConversationIfNeeded(conversation);
        nextPrompt = toolResult.toHermesResponseXml();

        // If we reached the final allowed step, request final synthesis
        if (stepIdx == workingTask.maxSteps - 1 && !_cancelRequested) {
          await _waitWhileUserChatBusy(workingTask);
          final synthPrompt =
              '$nextPrompt\n\nYou have reached the maximum number of tool steps (${workingTask.maxSteps}). Do NOT output any more <tool_call> tags. Synthesize all findings above into a clear, final Markdown report for the user.';
          final finalRaw = await _generateAgentStep(
            prompt: synthPrompt,
            systemPrompt: systemPrompt,
            history: conversation,
            onToken: (tok) {
              activeStepOutputStream.value += tok;
            },
          );
          final parsed = splitThoughtTags(finalRaw);
          final finalAnswer = parsed.answer.trim().isNotEmpty
              ? parsed.answer.trim()
              : finalRaw.trim();
          workingTask = workingTask.copyWith(
            steps: List<TaskStep>.from(steps),
            status: 'completed',
            finalAnswer: finalAnswer,
            completedAt: DateTime.now(),
            lastRunAt: DateTime.now(),
          );
          _updateTask(workingTask);
        }
      }
    } catch (e) {
      if (Get.isRegistered<AppLogService>()) {
        Get.find<AppLogService>().error('[AgentHarness] Task failed', details: e);
      }
      steps.add(TaskStep(
        index: steps.length,
        description: 'Execution error: $e',
        status: 'failed',
        output: '$e',
        timestamp: DateTime.now(),
      ));
      workingTask = workingTask.copyWith(
        steps: List<TaskStep>.from(steps),
        status: 'failed',
      );
      _updateTask(workingTask);
    } finally {
      isExecuting.value = false;
      isPausedForChat.value = false;
      activeStepOutputStream.value = '';
      // Capture updated workspace snapshot so agent-written files don't re-trigger watch_workspace
      await _captureWorkspaceSnapshot();
      // Chug next queued task if any
      Future.delayed(const Duration(milliseconds: 400), _processQueueIfIdle);
    }
  }

  /// Runs an inline Hermes-Lite ReAct turn directly inside interactive Chat.
  Future<String> runInteractiveChatAgentTurn({
    required String userPrompt,
    required String baseSystemPrompt,
    required List<Map<String, String>> chatHistory,
    required void Function(String statusMarkdown) onProgressUpdate,
  }) async {
    final systemPrompt = harness.buildHermesSystemPrompt(
      baseSystemPrompt: baseSystemPrompt,
    );
    final workingHistory = List<Map<String, String>>.from(chatHistory);
    final seenCalls = <String>{};
    final toolTraceLog = <String>[];
    var nextPrompt = userPrompt;
    final maxChatSteps = harness.maxSteps.value.clamp(2, 10);

    for (var step = 0; step < maxChatSteps; step++) {
      var streamedStep = '';
      final raw = await _generateAgentStep(
        prompt: nextPrompt,
        systemPrompt: systemPrompt,
        history: workingHistory,
        onToken: (tok) {
          streamedStep += tok;
          if (!streamedStep.contains('<tool_call>')) {
            final prefix = toolTraceLog.isEmpty
                ? ''
                : '${toolTraceLog.join('\n')}\n\n';
            onProgressUpdate('$prefix$streamedStep');
          }
        },
      );

      final call = AgentHarnessService.parseToolCall(raw);
      if (call == null) {
        final prefix =
            toolTraceLog.isEmpty ? '' : '${toolTraceLog.join('\n')}\n\n';
        return '$prefix$raw';
      }

      final sig = call.canonicalSignature;
      if (seenCalls.contains(sig)) {
        workingHistory.add({'role': 'user', 'content': nextPrompt});
        workingHistory.add({
          'role': 'assistant',
          'content':
              '<tool_call>\n${jsonEncode({'name': call.name, 'arguments': call.arguments})}\n</tool_call>',
        });
        nextPrompt =
            '<tool_response>\n{"name": "${call.name}", "status": "warning", "result": "Duplicate call blocked. Provide your final answer now."}\n</tool_response>';
        continue;
      }
      seenCalls.add(sig);

      final callLabel = _describeToolCall(call);
      toolTraceLog.add('> 🔧 **Step ${step + 1}**: `$callLabel`');
      onProgressUpdate('${toolTraceLog.join('\n')}\n\n_Running `${call.name}`…_');

      final res = await harness.executeToolCall(call);
      workingHistory.add({'role': 'user', 'content': nextPrompt});
      workingHistory.add({
        'role': 'assistant',
        'content':
            '<tool_call>\n${jsonEncode({'name': call.name, 'arguments': call.arguments})}\n</tool_call>',
      });
      _compactAgentConversationIfNeeded(workingHistory);
      nextPrompt = res.toHermesResponseXml();
    }

    final finalRaw = await _generateAgentStep(
      prompt:
          '$nextPrompt\n\nProvide your final synthesized answer now without calling any more tools.',
      systemPrompt: systemPrompt,
      history: workingHistory,
    );
    final prefix = toolTraceLog.isEmpty ? '' : '${toolTraceLog.join('\n')}\n\n';
    return '$prefix$finalRaw';
  }

  Future<String> _generateAgentStep({
    required String prompt,
    required String systemPrompt,
    required List<Map<String, String>> history,
    void Function(String)? onToken,
  }) async {
    final mode = _hive.getSetting(
          AppConstants.keyInferenceMode,
          defaultValue: 'local',
        ) ??
        'local';

    final baseStop = Get.isRegistered<SettingsController>()
        ? Get.find<SettingsController>().stopSequences.toList()
        : <String>[];
    final stopSeqs = <String>{
      ...baseStop,
      '</tool_call>',
      '</function_call>',
    }.toList();

    if (mode == 'local') {
      final inference = Get.find<InferenceService>();
      var result = await inference.generate(
        prompt: prompt,
        systemPrompt: systemPrompt,
        conversationHistory: history,
        source: 'agent',
        stopSequences: stopSeqs,
        onToken: onToken,
      );
      if (result.startsWith('ERROR:')) {
        throw Exception(result);
      }
      if (result.contains('<tool_call>') && !result.contains('</tool_call>')) {
        result = '$result\n</tool_call>';
      }
      return result;
    } else {
      final cloud = Get.find<CloudService>();
      final msgs = <Map<String, String>>[
        {'role': 'system', 'content': systemPrompt},
        ...history,
        {'role': 'user', 'content': prompt},
      ];
      return await cloud.sendMessage(
        messages: msgs,
        onToken: onToken,
      );
    }
  }

  void _compactAgentConversationIfNeeded(List<Map<String, String>> conversation) {
    var totalChars = conversation.fold<int>(
      0,
      (sum, m) => sum + (m['content']?.length ?? 0),
    );
    if (totalChars <= 10000 || conversation.length <= 4) return;

    // Compact older tool_response messages while preserving the last 2 turns intact
    for (var i = 0; i < conversation.length - 4; i++) {
      final content = conversation[i]['content'] ?? '';
      if (content.contains('<tool_response>') && content.length > 600) {
        conversation[i] = {
          'role': conversation[i]['role'] ?? 'user',
          'content':
              '${content.substring(0, 450)}\n...[older tool output compacted]...</tool_response>',
        };
      }
    }
  }

  String _describeToolCall(AgentToolCall call) {
    final args = call.arguments;
    switch (call.name) {
      case 'workspace_files':
        final action = args['action'] ?? 'list';
        final path = args['path'] ?? args['query'] ?? '';
        return path.toString().isEmpty
            ? 'workspace_files ($action)'
            : 'workspace_files ($action: $path)';
      case 'web_search':
        return 'web_search ("${args['query'] ?? ''}")';
      case 'web_fetch':
        return 'web_fetch (${args['url'] ?? ''})';
      case 'memory_store':
        final action = args['action'] ?? 'list';
        final key = args['key'] ?? '';
        return key.toString().isEmpty
            ? 'memory_store ($action)'
            : 'memory_store ($action: $key)';
      case 'shell_exec':
        return 'shell_exec (${args['command'] ?? ''})';
      default:
        return call.name;
    }
  }

  void deleteTask(String id) {
    _hive.deleteTask(id);
    tasks.removeWhere((t) => t.id == id);
    if (currentTask.value?.id == id) {
      currentTask.value = null;
    }
  }

  void _updateTask(TaskModel task) {
    if (currentTask.value?.id == task.id) {
      currentTask.value = task;
    }
    final idx = tasks.indexWhere((t) => t.id == task.id);
    if (idx >= 0) tasks[idx] = task;
    _hive.saveTask(task.id, task.toMap());
  }
}
