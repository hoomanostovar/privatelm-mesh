import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/models/task_model.dart';
import 'package:privatelm/services/agent_harness_service.dart';

void main() {
  group('Hermes-Lite AgentHarnessService Tool Call Parser', () {
    test('parses standard <tool_call> XML with <think> reasoning and preamble', () {
      const raw = '''<think>
I should list the files in the workspace first.
</think>
Let me inspect the workspace directory.
<tool_call>
{"name": "workspace_files", "arguments": {"action": "list"}}
</tool_call>''';

      final call = AgentHarnessService.parseToolCall(raw);
      expect(call, isNotNull);
      expect(call!.name, 'workspace_files');
      expect(call.arguments['action'], 'list');
      expect(call.thought, contains('list the files in the workspace'));
      expect(call.preambleText, 'Let me inspect the workspace directory.');
    });

    test('parses unclosed <tool_call> when halted by </tool_call> stop sequence', () {
      const raw = '''<tool_call>
{"name": "web_search", "arguments": {"query": "llama.cpp rpc mesh", "max_results": 3}}''';

      final call = AgentHarnessService.parseToolCall(raw);
      expect(call, isNotNull);
      expect(call!.name, 'web_search');
      expect(call.arguments['query'], 'llama.cpp rpc mesh');
      expect(call.arguments['max_results'], 3);
    });

    test('parses fallback fenced JSON tool call block from smaller models', () {
      const raw = '''I will save this fact to memory.
```json
{"name": "memory_store", "arguments": {"action": "set", "key": "gpu_vram", "value": "16GB"}}
```''';

      final call = AgentHarnessService.parseToolCall(raw);
      expect(call, isNotNull);
      expect(call!.name, 'memory_store');
      expect(call.arguments['action'], 'set');
      expect(call.arguments['key'], 'gpu_vram');
    });

    test('returns null for normal final answer without tool call', () {
      const raw = '''<think>All steps are complete.</think>
Here is the final summary of your workspace files:
- `README.md`
- `MEMORY.md`''';

      final call = AgentHarnessService.parseToolCall(raw);
      expect(call, isNull);
    });

    test('canonicalSignature is key-order independent for duplicate detection', () {
      const callA = AgentToolCall(
        name: 'workspace_files',
        arguments: {'path': 'notes.md', 'action': 'read'},
      );
      const callB = AgentToolCall(
        name: 'workspace_files',
        arguments: {'action': 'read', 'path': 'notes.md'},
      );
      expect(callA.canonicalSignature, equals(callB.canonicalSignature));
    });
  });

  group('Hermes-Lite Web & Shell Guardrails', () {
    test('htmlToCleanMarkdown strips scripts/styles and preserves headings', () {
      const html = '''
<html>
  <head>
    <title>Test Page</title>
    <script>alert("xss");</script>
    <style>body { color: red; }</style>
  </head>
  <body>
    <h1>Main Heading</h1>
    <p>Paragraph with &amp; entity.</p>
    <ul><li>First item</li><li>Second item</li></ul>
  </body>
</html>''';

      final md = AgentHarnessService.htmlToCleanMarkdown(
        html,
        sourceUrl: 'https://example.com',
      );
      expect(md, contains('# Test Page'));
      expect(md, contains('# Main Heading'));
      expect(md, contains('Paragraph with & entity.'));
      expect(md, contains('- First item'));
      expect(md, isNot(contains('alert')));
      expect(md, isNot(contains('color: red')));
    });

    test('isSafeReadonlyCommand allows inspection commands and blocks destructive ones', () {
      expect(AgentHarnessService.isSafeReadonlyCommand('git status'), isTrue);
      expect(AgentHarnessService.isSafeReadonlyCommand('dir'), isTrue);
      expect(AgentHarnessService.isSafeReadonlyCommand('ls -la'), isTrue);
      expect(AgentHarnessService.isSafeReadonlyCommand('whoami'), isTrue);

      expect(AgentHarnessService.isSafeReadonlyCommand('rm -rf /'), isFalse);
      expect(AgentHarnessService.isSafeReadonlyCommand('del secret.txt'), isFalse);
      expect(AgentHarnessService.isSafeReadonlyCommand('echo hi > file.txt'), isFalse);
      expect(AgentHarnessService.isSafeReadonlyCommand('Remove-Item foo'), isFalse);
    });

    test('TaskModel serializes and deserializes Hermes fields cleanly', () {
      final model = TaskModel(
        id: 't1',
        goal: 'Summarize workspace',
        status: 'completed',
        schedule: 'daily',
        maxSteps: 10,
        finalAnswer: 'Done!',
        steps: [
          const TaskStep(
            index: 0,
            description: 'workspace_files (list)',
            thought: 'Checking files',
            toolName: 'workspace_files',
            toolArgs: '{"action":"list"}',
            status: 'done',
            output: 'README.md',
            durationMs: 14,
          ),
        ],
      );

      final restored = TaskModel.fromMap(model.toMap());
      expect(restored.id, 't1');
      expect(restored.schedule, 'daily');
      expect(restored.maxSteps, 10);
      expect(restored.finalAnswer, 'Done!');
      expect(restored.steps.length, 1);
      expect(restored.steps.first.toolName, 'workspace_files');
      expect(restored.steps.first.durationMs, 14);
    });
  });
}

