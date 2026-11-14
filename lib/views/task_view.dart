import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../controllers/task_controller.dart';
import '../core/haptics.dart';
import '../core/ui.dart';
import '../models/task_model.dart';
import '../services/agent_harness_service.dart';
import '../widgets/chat_bubble.dart';

class TaskView extends GetView<TaskController> {
  const TaskView({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Obx(() {
      final current = controller.currentTask.value;
      return PopScope(
        canPop: current == null,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) controller.currentTask.value = null;
        },
        child: Scaffold(
          backgroundColor: t.bg,
          appBar: current == null
              ? appScreenBar(
                  context,
                  title: 'Hermes-Lite Agents',
                  showBack: Navigator.of(context).canPop(),
                  actions: [
                    AppBarIcon(
                      icon: Icons.psychology_alt_rounded,
                      tooltip: 'Persistent Memory Store',
                      onPressed: () => _showMemoryStoreDialog(context),
                    ),
                    AppBarIcon(
                      icon: Icons.info_outline_rounded,
                      tooltip: 'About Hermes-Lite Harness',
                      onPressed: () => _showHarnessInfoDialog(context),
                    ),
                    AppBarIcon(
                      icon: Icons.add_rounded,
                      tooltip: 'New Agent Task',
                      onPressed: () => _showCreateSheet(context),
                    ),
                  ],
                )
              : appScreenBar(
                  context,
                  title: 'Agent Run',
                  leading: IconButton(
                    tooltip: 'All tasks',
                    icon: Icon(Icons.arrow_back_rounded, color: t.text),
                    onPressed: () => controller.currentTask.value = null,
                  ),
                  actions: [
                    if (current.isActive)
                      AppBarIcon(
                        icon: Icons.stop_circle_outlined,
                        tooltip: 'Stop agent',
                        onPressed: controller.cancelCurrentTask,
                      ),
                    AppBarIcon(
                      icon: Icons.delete_outline_rounded,
                      tooltip: 'Delete task',
                      onPressed: controller.isExecuting.value &&
                              controller.currentTask.value?.id == current.id
                          ? null
                          : () => _confirmDelete(context, current),
                    ),
                  ],
                ),
          body: current == null
              ? _buildAgentDashboard(context)
              : _buildTaskDetail(context, current),
        ),
      );
    });
  }

  // ── Main Dashboard (Workspace Controls + Templates + Chug Queue) ────────

  Widget _buildAgentDashboard(BuildContext context) {
    final t = AppTokens.of(context);
    final harness = controller.harness;

    return ListView(
      padding: kPagePadding,
      children: [
        // 1. Paused-for-chat live banner
        Obx(() {
          if (!controller.isPausedForChat.value) return const SizedBox.shrink();
          return Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFFF9F0A).withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: const Color(0xFFFF9F0A).withValues(alpha: 0.45),
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.pause_circle_filled_rounded,
                  color: Color(0xFFFF9F0A),
                  size: 18,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Chug Queue paused while interactive Chat is active — will auto-resume when your chat finishes.',
                    style: t.caption.copyWith(
                      color: t.text,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          );
        }),

        // 2. Harness Configuration & Workspace Card
        _buildHarnessConfigCard(context, harness, t),
        const SizedBox(height: 16),

        // 3. Starter Templates
        const SectionHeader(
          'Quick-Start Agent Templates',
          padding: EdgeInsets.fromLTRB(4, 0, 4, 8),
        ),
        _buildStarterTemplatesGrid(context, t),
        const SizedBox(height: 18),

        // 4. Chug Queue & Task History
        Row(
          children: [
            Expanded(
              child: SectionHeader(
                'Agent Chug Queue & Runs',
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                trailing: Text('${controller.tasks.length}', style: t.small),
              ),
            ),
            TextButton.icon(
              onPressed: () => _showCreateSheet(context),
              icon: const Icon(Icons.add_rounded, size: 16),
              label: const Text('New Agent Task'),
            ),
          ],
        ),
        if (controller.tasks.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
            decoration: BoxDecoration(
              color: t.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: t.hairline),
            ),
            child: Column(
              children: [
                Icon(Icons.smart_toy_outlined, size: 32, color: t.muted),
                const SizedBox(height: 10),
                Text('No agent tasks queued yet', style: t.bodyStrong),
                const SizedBox(height: 4),
                Text(
                  'Queue a goal or pick a template above. Background tasks chug at their own pace and automatically pause whenever you use the main Chat.',
                  textAlign: TextAlign.center,
                  style: t.caption,
                ),
              ],
            ),
          )
        else ...[
          AppGroup(
            children: [
              for (final task in controller.tasks) _TaskRow(task: task),
            ],
          ),
          const SectionFootnote('Swipe a task left to delete it.'),
        ],
        const SizedBox(height: 56),
      ],
    );
  }

  Widget _buildHarnessConfigCard(
    BuildContext context,
    AgentHarnessService harness,
    AppTokens t,
  ) {
    return Obx(() {
      final wsPath = harness.workspacePath.value;
      final memCount = harness.memoryEntries.length;
      final policy = harness.shellPolicy.value;
      final idlePause = harness.idleAwarePause.value;
      final maxSteps = harness.maxSteps.value;

      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: t.hairline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Workspace Directory row
            Row(
              children: [
                Icon(Icons.folder_special_rounded, size: 16, color: t.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            'Sandboxed Agent Workspace',
                            style: t.caption.copyWith(
                              fontWeight: FontWeight.w600,
                              color: t.text,
                            ),
                          ),
                          const SizedBox(width: 8),
                          AppTag(
                            controller.isExecuting.value ? 'CHUGGING' : 'READY',
                            color: controller.isExecuting.value
                                ? t.accent
                                : t.green,
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        wsPath.isEmpty ? 'Default Documents Workspace' : wsPath,
                        style: GoogleFonts.jetBrainsMono(
                          fontSize: 10.5,
                          color: t.muted,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (!kIsWeb)
                  TextButton(
                    onPressed: () async {
                      final picked =
                          await FilePicker.getDirectoryPath(
                        dialogTitle: 'Select Agent Workspace Folder',
                      );
                      if (picked != null && picked.isNotEmpty) {
                        await harness.setWorkspacePath(picked);
                        showToast('Workspace updated', picked);
                      }
                    },
                    child: const Text('Change'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Divider(height: 1, color: t.hairline),
            const SizedBox(height: 8),

            // Idle-aware Chug Mode toggle
            Row(
              children: [
                Icon(Icons.speed_rounded, size: 16, color: t.green),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Idle-Aware "Chug Mode"',
                        style: t.caption.copyWith(
                          fontWeight: FontWeight.w600,
                          color: t.text,
                        ),
                      ),
                      Text(
                        'Automatically pause background agents when you send a Chat message',
                        style: t.small,
                      ),
                    ],
                  ),
                ),
                Switch.adaptive(
                  value: idlePause,
                  activeTrackColor: t.accent,
                  onChanged: (v) => harness.setIdleAwarePause(v),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Bottom pills: Shell policy + Max steps + Memory count
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _ConfigChip(
                  icon: Icons.terminal_rounded,
                  label: 'Shell: ${_shellPolicyLabel(policy)}',
                  onTap: () => _showShellPolicySheet(context, harness),
                ),
                _ConfigChip(
                  icon: Icons.repeat_rounded,
                  label: 'Max Steps: $maxSteps',
                  onTap: () => _showMaxStepsSheet(context, harness),
                ),
                _ConfigChip(
                  icon: Icons.bookmark_added_rounded,
                  label: 'Memory: $memCount fact(s)',
                  onTap: () => _showMemoryStoreDialog(context),
                ),
              ],
            ),
          ],
        ),
      );
    });
  }

  String _shellPolicyLabel(String policy) {
    switch (policy) {
      case 'ask_approval':
        return 'Ask Approval';
      case 'disabled':
        return 'Disabled';
      default:
        return 'Safe Read-Only';
    }
  }

  Widget _buildStarterTemplatesGrid(BuildContext context, AppTokens t) {
    final templates = [
      (
        icon: Icons.summarize_rounded,
        title: 'Workspace Summarizer',
        desc: 'List & read files in the workspace and write WORKSPACE_SUMMARY.md',
        goal:
            'List all files in the Agent Workspace using workspace_files, read their contents, and write a comprehensive summary report to WORKSPACE_SUMMARY.md.',
      ),
      (
        icon: Icons.travel_explore_rounded,
        title: 'Web Research Digest',
        desc: 'Search the web, fetch articles, and compile a markdown briefing',
        goal:
            'Use web_search to find the latest developments in local GGUF LLM inference and quantization, fetch the top article with web_fetch, and write a concise briefing to research_digest.md in the workspace.',
      ),
      (
        icon: Icons.psychology_rounded,
        title: 'Memory Note Builder',
        desc: 'Extract key facts from workspace notes into persistent memory_store',
        goal:
            'Inspect the files in the Agent Workspace, extract the most important project facts, and save them into memory_store so you remember them across future runs.',
      ),
      (
        icon: Icons.monitor_heart_rounded,
        title: 'System & Repo Audit',
        desc: 'Run safe read-only checks and write a status report to the workspace',
        goal:
            'Check the current workspace files and run a safe read-only shell_exec status check (such as hostname or directory listing), then save a clean system_audit.md report.',
      ),
    ];

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final tpl in templates)
          SizedBox(
            width: (MediaQuery.of(context).size.width - 42) / 2,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () {
                Haptics.selectionClick();
                _showCreateSheet(context, initialGoal: tpl.goal);
              },
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: t.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: t.hairline),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(tpl.icon, size: 18, color: t.accent),
                    const SizedBox(height: 8),
                    Text(
                      tpl.title,
                      style: t.caption.copyWith(
                        fontWeight: FontWeight.w700,
                        color: t.text,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      tpl.desc,
                      style: t.small,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ── Task Detail (Live ReAct Loop & Synthesized Final Report) ────────────

  Widget _buildTaskDetail(BuildContext context, TaskModel task) {
    final t = AppTokens.of(context);
    final steps = task.steps;
    final done = steps.where((s) => s.status == 'done').length;
    final executing =
        controller.isExecuting.value && controller.currentTask.value?.id == task.id;

    return Column(
      children: [
        Expanded(
          child: SelectionArea(
            child: ListView(
              padding: kPagePadding,
              children: [
                const SizedBox(height: 4),
                Text(
                  task.goal,
                  style: t.title.copyWith(fontSize: 19, letterSpacing: -0.4),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _statusTag(context, task.status),
                    if (task.schedule != 'once')
                      AppTag(
                        _scheduleLabel(task.schedule),
                        color: t.accent,
                      ),
                    Text(
                      steps.isEmpty
                          ? _formatDate(task.createdAt)
                          : '$done step(s) completed (max ${task.maxSteps}) · ${_formatDate(task.createdAt)}',
                      style: t.small,
                    ),
                  ],
                ),

                // Approval Banner if waiting on shell_exec
                if (task.status == 'awaiting_approval') ...[
                  const SizedBox(height: 14),
                  _buildShellApprovalCard(context, task, t),
                ],

                // Live Streaming Output Box while step is generating
                Obx(() {
                  final streamText = controller.activeStepOutputStream.value;
                  if (!executing || streamText.trim().isEmpty) {
                    return const SizedBox.shrink();
                  }
                  return Container(
                    margin: const EdgeInsets.only(top: 14),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: t.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: t.accent.withValues(alpha: 0.4)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.8,
                                color: t.accent,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Live Agent Stream',
                              style: t.caption.copyWith(
                                color: t.accent,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          streamText,
                          style: GoogleFonts.jetBrainsMono(
                            fontSize: 11.5,
                            color: t.text,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  );
                }),

                // Final Synthesized Markdown Answer
                if (task.finalAnswer != null &&
                    task.finalAnswer!.trim().isNotEmpty) ...[
                  const SizedBox(height: 18),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: t.green.withValues(alpha: 0.07),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: t.green.withValues(alpha: 0.35),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.verified_rounded,
                              size: 17,
                              color: t.green,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Agent Final Output',
                                style: t.bodyStrong.copyWith(color: t.green),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Copy final output',
                              visualDensity: VisualDensity.compact,
                              icon: Icon(
                                Icons.copy_all_rounded,
                                size: 17,
                                color: t.muted,
                              ),
                              onPressed: () {
                                Clipboard.setData(
                                  ClipboardData(text: task.finalAnswer!),
                                );
                                showToast('Copied', 'Final agent report copied');
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        MarkdownBody(
                          data: task.finalAnswer!,
                          styleSheet: ChatBubble.answerStyle(context),
                        ),
                      ],
                    ),
                  ),
                ],

                // ReAct Steps Timeline
                const SectionHeader('Hermes ReAct Step Timeline'),
                if (steps.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: t.surface,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: t.hairline),
                    ),
                    child: Text(
                      task.status == 'queued'
                          ? 'Queued — waiting to start ReAct loop.'
                          : 'No steps recorded yet.',
                      style: t.caption,
                    ),
                  )
                else
                  Column(
                    children: [
                      for (var i = 0; i < steps.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _ReActStepCard(step: steps[i], number: i + 1),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),

        // Bottom Action Bar
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: executing
                ? PrimaryButton(
                    label: 'Stop Agent Run',
                    icon: Icons.stop_rounded,
                    onPressed: controller.cancelCurrentTask,
                  )
                : PrimaryButton(
                    label: task.status == 'completed'
                        ? 'Run Task Again'
                        : 'Start Agent Run',
                    icon: Icons.play_arrow_rounded,
                    onPressed: () {
                      Haptics.mediumImpact();
                      controller.executeTask(task);
                    },
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildShellApprovalCard(
    BuildContext context,
    TaskModel task,
    AppTokens t,
  ) {
    final pendingStep =
        task.steps.firstWhereOrNull((s) => s.status == 'awaiting_approval');
    final cmd = pendingStep?.command ?? pendingStep?.toolArgs ?? '';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFF9F0A).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFF9F0A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.security_rounded,
                color: Color(0xFFFF9F0A),
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(
                'Shell Command Approval Required',
                style: t.bodyStrong.copyWith(color: const Color(0xFFFF9F0A)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: t.bg,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              cmd,
              style: GoogleFonts.jetBrainsMono(fontSize: 12, color: t.text),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: controller.rejectPendingShellCommand,
                child: Text('Reject', style: TextStyle(color: t.red)),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: controller.approvePendingShellCommand,
                icon: const Icon(Icons.check_rounded, size: 16),
                label: const Text('Approve & Run'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Create Sheet & Dialogs ──────────────────────────────────────────────

  void _showCreateSheet(BuildContext context, {String? initialGoal}) {
    final textCtrl = TextEditingController(text: initialGoal ?? '');
    var selectedSchedule = 'once';
    var maxSteps = controller.harness.maxSteps.value;
    final selectedTools = Set<String>.from(TaskModel.defaultTools);

    showAppSheet<void>(
      context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            final t = AppTokens.of(ctx);
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('New Hermes-Lite Agent Task', style: t.title),
                const SizedBox(height: 4),
                Text(
                  'The agent will loop through Think -> Tool Call -> Observe until the goal is achieved.',
                  style: t.caption,
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: textCtrl,
                  autofocus: initialGoal == null,
                  minLines: 3,
                  maxLines: 6,
                  style: t.body,
                  decoration: InputDecoration(
                    hintText:
                        'e.g., Search the web for Qwen3 benchmarks, summarize them, and save to benchmarks.md in the workspace',
                    hintStyle: t.caption,
                    filled: true,
                    fillColor: t.surface,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: t.hairline),
                    ),
                  ),
                ),
                const SizedBox(height: 14),

                // Schedule Selector
                Text('Schedule / Trigger', style: t.caption.copyWith(fontWeight: FontWeight.w600, color: t.text)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final s in const [
                      ('once', 'Run Once'),
                      ('hourly', 'Every Hour'),
                      ('every_6h', 'Every 6h'),
                      ('daily', 'Daily'),
                      ('watch_workspace', 'Watch Workspace Folder'),
                    ])
                      ChoiceChip(
                        label: Text(s.$2, style: const TextStyle(fontSize: 11.5)),
                        selected: selectedSchedule == s.$1,
                        onSelected: (_) =>
                            setModalState(() => selectedSchedule = s.$1),
                      ),
                  ],
                ),
                const SizedBox(height: 12),

                // Enabled Tools
                Text('Allowed Tools', style: t.caption.copyWith(fontWeight: FontWeight.w600, color: t.text)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final tool in TaskModel.defaultTools)
                      FilterChip(
                        label: Text(tool, style: const TextStyle(fontSize: 11.5)),
                        selected: selectedTools.contains(tool),
                        onSelected: (v) {
                          setModalState(() {
                            if (v) {
                              selectedTools.add(tool);
                            } else if (selectedTools.length > 1) {
                              selectedTools.remove(tool);
                            }
                          });
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                PrimaryButton(
                  label: 'Queue & Start Agent',
                  icon: Icons.rocket_launch_rounded,
                  onPressed: () {
                    final goal = textCtrl.text.trim();
                    if (goal.isEmpty) return;
                    Navigator.pop(ctx);
                    controller.createTask(
                      goal,
                      schedule: selectedSchedule,
                      maxSteps: maxSteps,
                      allowedTools: selectedTools.toList(),
                    );
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showShellPolicySheet(BuildContext context, AgentHarnessService harness) {
    final t = AppTokens.of(context);
    showAppSheet<void>(
      context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Shell Execution Policy (`shell_exec`)', style: t.title),
          const SizedBox(height: 8),
          ListTile(
            leading: Icon(Icons.verified_user_rounded, color: t.green),
            title: const Text('Safe Read-Only (Recommended)'),
            subtitle: const Text(
              'Allows non-destructive inspection commands (dir, ls, git status, systeminfo) inside the workspace.',
            ),
            onTap: () {
              harness.setShellPolicy('safe_readonly');
              Navigator.pop(ctx);
            },
          ),
          ListTile(
            leading: const Icon(Icons.help_outline_rounded, color: Color(0xFFFF9F0A)),
            title: const Text('Ask Approval Before Running'),
            subtitle: const Text(
              'Pauses the agent and asks for your 1-click confirmation before running any shell command.',
            ),
            onTap: () {
              harness.setShellPolicy('ask_approval');
              Navigator.pop(ctx);
            },
          ),
          ListTile(
            leading: Icon(Icons.block_rounded, color: t.red),
            title: const Text('Disabled'),
            subtitle: const Text(
              'Prevents agents from calling shell_exec entirely.',
            ),
            onTap: () {
              harness.setShellPolicy('disabled');
              Navigator.pop(ctx);
            },
          ),
        ],
      ),
    );
  }

  void _showMaxStepsSheet(BuildContext context, AgentHarnessService harness) {
    final t = AppTokens.of(context);
    showAppSheet<void>(
      context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Maximum ReAct Steps per Run', style: t.title),
          const SizedBox(height: 6),
          Text(
            'Limits how many tool calls an agent can make before synthesizing its final answer.',
            style: t.caption,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              for (final s in const [4, 6, 8, 12, 16, 20])
                ChoiceChip(
                  label: Text('$s steps'),
                  selected: harness.maxSteps.value == s,
                  onSelected: (_) {
                    harness.setMaxSteps(s);
                    Navigator.pop(ctx);
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }

  void _showMemoryStoreDialog(BuildContext context) {
    final harness = controller.harness;
    final keyCtrl = TextEditingController();
    final valCtrl = TextEditingController();

    showDialog<void>(
      context: context,
      builder: (ctx) {
        final t = AppTokens.of(ctx);
        return AlertDialog(
          backgroundColor: t.surface,
          title: Row(
            children: [
              Icon(Icons.psychology_alt_rounded, color: t.accent, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Agent Persistent Memory', style: t.bodyStrong),
              ),
            ],
          ),
          content: SizedBox(
            width: 460,
            child: Obx(() {
              final entries = harness.memoryEntries.entries.toList();
              return SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Facts stored here persist across sessions and are injected into the Hermes-Lite system prompt and mirrored to MEMORY.md in the workspace.',
                      style: t.small,
                    ),
                    const SizedBox(height: 12),
                    if (entries.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text('No memory entries yet.', style: t.caption),
                      )
                    else
                      for (final e in entries)
                        Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: t.bg,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: t.hairline),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      e.key,
                                      style: GoogleFonts.jetBrainsMono(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: t.accent,
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      '${e.value['value'] ?? ''}',
                                      style: t.caption.copyWith(color: t.text),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                icon: Icon(Icons.delete_outline_rounded, size: 17, color: t.red),
                                onPressed: () {
                                  harness.executeToolCall(
                                    AgentToolCall(
                                      name: 'memory_store',
                                      arguments: {'action': 'delete', 'key': e.key},
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                    const Divider(height: 20),
                    Text('Add Memory Entry', style: t.caption.copyWith(fontWeight: FontWeight.w700, color: t.text)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: keyCtrl,
                      decoration: const InputDecoration(
                        hintText: 'Key (e.g. project_goal)',
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: valCtrl,
                      decoration: const InputDecoration(
                        hintText: 'Value / fact to remember',
                        isDense: true,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
            FilledButton(
              onPressed: () {
                final k = keyCtrl.text.trim();
                final v = valCtrl.text.trim();
                if (k.isEmpty || v.isEmpty) return;
                harness.executeToolCall(
                  AgentToolCall(
                    name: 'memory_store',
                    arguments: {'action': 'set', 'key': k, 'value': v},
                  ),
                );
                keyCtrl.clear();
                valCtrl.clear();
              },
              child: const Text('Save Fact'),
            ),
          ],
        );
      },
    );
  }

  void _showHarnessInfoDialog(BuildContext context) {
    final t = AppTokens.of(context);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: t.surface,
        title: Row(
          children: [
            Icon(Icons.smart_toy_rounded, color: t.accent, size: 22),
            const SizedBox(width: 8),
            Expanded(
              child: Text('About Hermes-Lite Agent Harness', style: t.bodyStrong),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Hermes-Lite brings autonomous multi-step tool use to your local and mesh models with \$0 token cost.',
                style: t.caption.copyWith(color: t.text),
              ),
              const SizedBox(height: 12),
              Text('How the ReAct Loop Works', style: t.caption.copyWith(fontWeight: FontWeight.w700, color: t.text)),
              const SizedBox(height: 4),
              Text(
                '• The model receives tool schemas in <tools> and outputs <tool_call>{"name": "...", "arguments": {...}}</tool_call>.\n'
                '• The harness intercepts </tool_call> immediately, executes the local Dart tool, returns <tool_response>, and auto-compacts older tool outputs so 4K/8K context windows never overflow.\n'
                '• Duplicate-call guardrails prevent smaller 1.2B–8B models from getting stuck in repetitive loops.',
                style: t.small,
              ),
              const SizedBox(height: 12),
              Text('Built-in Local Toolset', style: t.caption.copyWith(fontWeight: FontWeight.w700, color: t.text)),
              const SizedBox(height: 4),
              Text(
                '1. workspace_files — Read, write, append, list, and search files inside your sandboxed Agent Workspace folder.\n'
                '2. web_search — Keyless DuckDuckGo search returning titles, URLs, and snippets.\n'
                '3. web_fetch — Fetches webpages and strips HTML/JS bloat into clean Markdown.\n'
                '4. memory_store — Persistent key-value memory across runs (synced to MEMORY.md).\n'
                '5. shell_exec — Safe read-only or approval-gated local command execution.',
                style: t.small,
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(BuildContext context, TaskModel task) async {
    final ok = await confirmSheet(
      context,
      title: 'Delete agent task?',
      message: '"${task.goal}" will be removed.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (ok) controller.deleteTask(task.id);
  }

  static String _scheduleLabel(String schedule) {
    switch (schedule) {
      case 'hourly':
        return 'EVERY HOUR';
      case 'every_6h':
        return 'EVERY 6H';
      case 'daily':
        return 'DAILY';
      case 'watch_workspace':
        return 'WATCH FOLDER';
      default:
        return 'ONCE';
    }
  }

  static Widget _statusTag(BuildContext context, String status) {
    final t = AppTokens.of(context);
    final (label, color) = switch (status) {
      'completed' => ('COMPLETED', t.green),
      'failed' => ('FAILED', t.red),
      'running' => ('RUNNING', t.accent),
      'paused_for_chat' => ('PAUSED FOR CHAT', const Color(0xFFFF9F0A)),
      'awaiting_approval' => ('NEEDS APPROVAL', const Color(0xFFFF9F0A)),
      'cancelled' => ('CANCELLED', t.muted),
      _ => ('QUEUED', t.muted),
    };
    return AppTag(label, color: color);
  }

  static String _formatDate(DateTime date) {
    final diff = DateTime.now().difference(date);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return DateFormat('MMM d').format(date);
  }
}

class _ConfigChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ConfigChip({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: t.bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: t.hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13.5, color: t.accent),
            const SizedBox(width: 6),
            Text(
              label,
              style: t.small.copyWith(
                color: t.text,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TaskRow extends StatelessWidget {
  final TaskModel task;
  const _TaskRow({required this.task});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final c = Get.find<TaskController>();
    final done = task.steps.where((s) => s.status == 'done').length;
    final total = task.steps.length;

    final (icon, iconColor) = switch (task.status) {
      'completed' => (Icons.check_circle_rounded, t.green),
      'failed' => (Icons.error_outline_rounded, t.red),
      'running' => (Icons.autorenew_rounded, t.accent),
      'paused_for_chat' => (Icons.pause_circle_filled_rounded, const Color(0xFFFF9F0A)),
      'awaiting_approval' => (Icons.security_rounded, const Color(0xFFFF9F0A)),
      _ => (Icons.schedule_rounded, t.muted),
    };

    final sub = [
      if (total > 0) '$done step(s)',
      if (task.schedule != 'once') TaskView._scheduleLabel(task.schedule),
      TaskView._formatDate(task.createdAt),
    ].join(' · ');

    return Dismissible(
      key: Key(task.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: t.red,
        child: const Icon(Icons.delete_outline_rounded, color: Colors.white, size: 20),
      ),
      onDismissed: (_) => c.deleteTask(task.id),
      child: AppRow(
        leading: Icon(icon, size: 20, color: iconColor),
        title: task.goal,
        subtitle: sub,
        chevron: true,
        onTap: () => c.currentTask.value = task,
      ),
    );
  }
}

class _ReActStepCard extends StatefulWidget {
  final TaskStep step;
  final int number;

  const _ReActStepCard({required this.step, required this.number});

  @override
  State<_ReActStepCard> createState() => _ReActStepCardState();
}

class _ReActStepCardState extends State<_ReActStepCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final s = widget.step;

    final (badgeColor, icon) = switch (s.status) {
      'done' => (t.green, Icons.check_circle_rounded),
      'failed' => (t.red, Icons.error_outline_rounded),
      'running' => (t.accent, Icons.sync_rounded),
      'awaiting_approval' => (const Color(0xFFFF9F0A), Icons.security_rounded),
      _ => (t.muted, Icons.circle_outlined),
    };

    return Container(
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.hairline),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => setState(() => _expanded = !_expanded),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 17, color: badgeColor),
                  const SizedBox(width: 8),
                  Text(
                    'Step ${widget.number}',
                    style: t.caption.copyWith(
                      fontWeight: FontWeight.w700,
                      color: t.text,
                    ),
                  ),
                  if (s.toolName != null && s.toolName!.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: t.accent.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        s.toolName!,
                        style: GoogleFonts.jetBrainsMono(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: t.accent,
                        ),
                      ),
                    ),
                  ],
                  const Spacer(),
                  if (s.durationMs != null)
                    Text('${s.durationMs} ms', style: t.small),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 18,
                    color: t.muted,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                s.description,
                style: t.body.copyWith(fontSize: 13.5),
                maxLines: _expanded ? 10 : 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (_expanded) ...[
                if (s.thought != null && s.thought!.trim().isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text('Reasoning (<think>):', style: t.small.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: t.bg,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      s.thought!,
                      style: t.small.copyWith(fontStyle: FontStyle.italic),
                    ),
                  ),
                ],
                if (s.toolArgs != null && s.toolArgs!.trim().isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text('Tool Arguments:', style: t.small.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: t.bg,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      s.toolArgs!,
                      style: GoogleFonts.jetBrainsMono(fontSize: 11, color: t.text),
                    ),
                  ),
                ],
                if (s.output != null && s.output!.trim().isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text('Observation / Output:', style: t.small.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: t.bg,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      s.output!,
                      style: GoogleFonts.jetBrainsMono(
                        fontSize: 11,
                        color: s.status == 'failed' ? t.red : t.muted,
                      ),
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
