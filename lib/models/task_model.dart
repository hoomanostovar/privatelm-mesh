class TaskModel {
  final String id;
  final String goal;
  final List<TaskStep> steps;
  final String status; // 'queued', 'running', 'paused_for_chat', 'awaiting_approval', 'completed', 'failed', 'cancelled'
  final DateTime createdAt;
  final DateTime? completedAt;
  final String? finalAnswer;
  final String schedule; // 'once', 'hourly', 'every_6h', 'daily', 'watch_workspace'
  final DateTime? lastRunAt;
  final int maxSteps;
  final List<String> allowedTools;

  static const List<String> defaultTools = [
    'workspace_files',
    'web_search',
    'web_fetch',
    'memory_store',
    'shell_exec',
  ];

  TaskModel({
    required this.id,
    required this.goal,
    List<TaskStep>? steps,
    this.status = 'queued',
    DateTime? createdAt,
    this.completedAt,
    this.finalAnswer,
    this.schedule = 'once',
    this.lastRunAt,
    this.maxSteps = 8,
    List<String>? allowedTools,
  })  : steps = steps ?? [],
        createdAt = createdAt ?? DateTime.now(),
        allowedTools = allowedTools ?? defaultTools;

  bool get isActive =>
      status == 'running' ||
      status == 'paused_for_chat' ||
      status == 'awaiting_approval' ||
      status == 'planning';

  bool get isRecurring => schedule != 'once';

  Map<String, dynamic> toMap() => {
        'id': id,
        'goal': goal,
        'steps': steps.map((s) => s.toMap()).toList(),
        'status': status,
        'createdAt': createdAt.toIso8601String(),
        'completedAt': completedAt?.toIso8601String(),
        'finalAnswer': finalAnswer,
        'schedule': schedule,
        'lastRunAt': lastRunAt?.toIso8601String(),
        'maxSteps': maxSteps,
        'allowedTools': allowedTools,
      };

  factory TaskModel.fromMap(Map<dynamic, dynamic> map) => TaskModel(
        id: map['id'] ?? '',
        goal: map['goal'] ?? '',
        steps: (map['steps'] as List?)
                ?.map((s) => TaskStep.fromMap(Map<String, dynamic>.from(s)))
                .toList() ??
            [],
        status: map['status'] ?? 'queued',
        createdAt: DateTime.tryParse(map['createdAt'] ?? '') ?? DateTime.now(),
        completedAt: map['completedAt'] != null
            ? DateTime.tryParse(map['completedAt'].toString())
            : null,
        finalAnswer: map['finalAnswer'] as String?,
        schedule: map['schedule'] as String? ?? 'once',
        lastRunAt: map['lastRunAt'] != null
            ? DateTime.tryParse(map['lastRunAt'].toString())
            : null,
        maxSteps: (map['maxSteps'] as num?)?.toInt() ?? 8,
        allowedTools: (map['allowedTools'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            defaultTools,
      );

  TaskModel copyWith({
    String? goal,
    List<TaskStep>? steps,
    String? status,
    DateTime? completedAt,
    String? finalAnswer,
    String? schedule,
    DateTime? lastRunAt,
    int? maxSteps,
    List<String>? allowedTools,
  }) =>
      TaskModel(
        id: id,
        goal: goal ?? this.goal,
        steps: steps ?? this.steps,
        status: status ?? this.status,
        createdAt: createdAt,
        completedAt: completedAt ?? this.completedAt,
        finalAnswer: finalAnswer ?? this.finalAnswer,
        schedule: schedule ?? this.schedule,
        lastRunAt: lastRunAt ?? this.lastRunAt,
        maxSteps: maxSteps ?? this.maxSteps,
        allowedTools: allowedTools ?? this.allowedTools,
      );
}

class TaskStep {
  final int index;
  final String description;
  final String? thought;
  final String? toolName;
  final String? toolArgs;
  final String? command;
  final String status; // 'pending', 'running', 'done', 'failed', 'awaiting_approval'
  final String? output;
  final int? durationMs;
  final DateTime? timestamp;

  const TaskStep({
    required this.index,
    required this.description,
    this.thought,
    this.toolName,
    this.toolArgs,
    this.command,
    this.status = 'pending',
    this.output,
    this.durationMs,
    this.timestamp,
  });

  Map<String, dynamic> toMap() => {
        'index': index,
        'description': description,
        'thought': thought,
        'toolName': toolName,
        'toolArgs': toolArgs,
        'command': command,
        'status': status,
        'output': output,
        'durationMs': durationMs,
        'timestamp': timestamp?.toIso8601String(),
      };

  factory TaskStep.fromMap(Map<String, dynamic> map) => TaskStep(
        index: (map['index'] as num?)?.toInt() ?? 0,
        description: map['description'] ?? '',
        thought: map['thought'] as String?,
        toolName: map['toolName'] as String?,
        toolArgs: map['toolArgs'] as String?,
        command: map['command'] as String?,
        status: map['status'] ?? 'pending',
        output: map['output'] as String?,
        durationMs: (map['durationMs'] as num?)?.toInt(),
        timestamp: map['timestamp'] != null
            ? DateTime.tryParse(map['timestamp'].toString())
            : null,
      );

  TaskStep copyWith({
    String? description,
    String? thought,
    String? toolName,
    String? toolArgs,
    String? command,
    String? status,
    String? output,
    int? durationMs,
    DateTime? timestamp,
  }) =>
      TaskStep(
        index: index,
        description: description ?? this.description,
        thought: thought ?? this.thought,
        toolName: toolName ?? this.toolName,
        toolArgs: toolArgs ?? this.toolArgs,
        command: command ?? this.command,
        status: status ?? this.status,
        output: output ?? this.output,
        durationMs: durationMs ?? this.durationMs,
        timestamp: timestamp ?? this.timestamp,
      );
}
