import 'package:flutter_test/flutter_test.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';
import 'package:privatelm/models/task_model.dart';
import 'package:privatelm/models/transport_type.dart';
import 'package:privatelm/services/agent_harness_service.dart';
import 'package:privatelm/services/cluster_service.dart';
import 'package:privatelm/services/network_transport_service.dart';

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

  group('WAN / 5G Mobile Roaming & Locality-Aware Sub-Cluster Ordering', () {
    test('NetworkTransportService.isWanOrOverlayIp identifies Tailscale/CGNAT & WAN vs RFC1918 LAN', () {
      // RFC1918 Home LAN IPs -> false
      expect(NetworkTransportService.isWanOrOverlayIp('192.168.3.5'), isFalse);
      expect(NetworkTransportService.isWanOrOverlayIp('10.0.0.12'), isFalse);
      expect(NetworkTransportService.isWanOrOverlayIp('172.16.4.9'), isFalse);

      // Tailscale / CGNAT (100.64.0.0/10) & Public / DDNS -> true
      expect(NetworkTransportService.isWanOrOverlayIp('100.84.21.9'), isTrue);
      expect(NetworkTransportService.isWanOrOverlayIp('100.115.92.14'), isTrue);
      expect(NetworkTransportService.isWanOrOverlayIp('82.196.14.20'), isTrue);
      expect(NetworkTransportService.isWanOrOverlayIp('home-mesh.ts.net'), isTrue);
    });

    test('ClusterService.orderByLocalitySubClusters groups Home nodes before Away nodes (1x WAN hop)', () {
      final interleaved = [
        ClusterNodeAllocation(
          worker: const ClusterWorker(host: '100.84.21.9', port: 50052, name: 'Away Laptop (5G)'),
          capacityMb: 8192,
          speed: 120.0,
          transportType: TransportType.wan,
          latencyMs: 38.0,
        ),
        ClusterNodeAllocation(
          worker: const ClusterWorker(host: '192.168.3.154', port: 50052, name: 'Home Phone (Wi-Fi)'),
          capacityMb: 6144,
          speed: 35.0,
          transportType: TransportType.wifi,
          latencyMs: 6.0,
        ),
        ClusterNodeAllocation(
          worker: const ClusterWorker(host: '100.84.21.14', port: 50052, name: 'Away Phone (5G)'),
          capacityMb: 4096,
          speed: 30.0,
          transportType: TransportType.wan,
          latencyMs: 42.0,
        ),
      ];

      final ordered = ClusterService.orderByLocalitySubClusters(interleaved);
      expect(ordered.length, 3);
      // First node must be the Home LAN node so Home Coordinator -> Home Phone stay on LAN
      expect(ordered[0].isAway, isFalse);
      expect(ordered[0].worker!.name, 'Home Phone (Wi-Fi)');
      // Followed by the Away Sub-Cluster nodes (activation crosses WAN only once!)
      expect(ordered[1].isAway, isTrue);
      expect(ordered[2].isAway, isTrue);
      expect(ordered[1].capacityMb, greaterThanOrEqualTo(ordered[2].capacityMb));
    });

    test('MeshDeviceSlice.inclusiveLayerRangeLabel produces non-overlapping layer ranges', () {
      const sliceA = MeshDeviceSlice(
        id: 'n1',
        name: 'Raven',
        host: '192.168.3.5',
        deviceType: 'Desktop',
        hardwareBackend: 'Vulkan',
        transportType: TransportType.ethernet,
        latencyMs: 0.1,
        capacityMb: 2800,
        assignedModelMb: 2800,
        poolShareFraction: 0.7,
        modelFraction: 0.7,
        memoryUtilization: 1.0,
        layerStart: 0,
        layerEnd: 34,
        isLocal: true,
      );
      const sliceB = MeshDeviceSlice(
        id: 'n2',
        name: 'Squirrel',
        host: '192.168.3.12',
        deviceType: 'Desktop',
        hardwareBackend: 'Vulkan',
        transportType: TransportType.wifi,
        latencyMs: 4.0,
        capacityMb: 500,
        assignedModelMb: 500,
        poolShareFraction: 0.3,
        modelFraction: 0.3,
        memoryUtilization: 1.0,
        layerStart: 34,
        layerEnd: 40,
        isLocal: false,
      );

      expect(sliceA.inclusiveLayerRangeLabel, 'L00–L33');
      expect(sliceB.inclusiveLayerRangeLabel, 'L34–L39');
    });
  });
}

