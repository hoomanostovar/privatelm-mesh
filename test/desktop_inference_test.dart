import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/services/desktop_inference_engine.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart' show ChatMessage;

void main() {
  test('DesktopInferenceEngine loads model with unreachable RPC safely', () async {
    final modelPath = 'C:\\Users\\hooma\\Documents\\models\\gemma-3-1b-it-q4_0.gguf';
    if (!File(modelPath).existsSync()) {
      print('Skipping test because model file does not exist at $modelPath');
      return;
    }

    print('[Test] Loading model with offline RPC worker (192.168.3.175:50052)...');
    final result = await DesktopInferenceEngine.instance.loadModel(
      modelPath: modelPath,
      threads: 4,
      contextSize: 2048,
      rpcEndpoints: ['192.168.3.175:50052'],
    );

    expect(result.success, isTrue, reason: 'Model should load successfully despite unreachable RPC worker');
    print('[Test] Result success: ${result.success}');
    print('[Test] Result message: ${result.message}');

    print('[Test] Testing chat completion stream...');
    final stream = DesktopInferenceEngine.instance.generateChat(
      messages: [
        ChatMessage(role: 'user', content: 'Say hello in 3 words!'),
      ],
      maxTokens: 16,
    );
    final responseBuf = StringBuffer();
    await for (final token in stream) {
      responseBuf.write(token);
    }
    print('[Test] Generated response: "${responseBuf.toString().trim()}"');
    expect(responseBuf.isNotEmpty, isTrue);

    await DesktopInferenceEngine.instance.unloadModel();
    print('[Test] Finished clean unload of Gemma.');

    final qwenPath = 'C:\\Users\\hooma\\Documents\\models\\qwen2.5-coder-0.5b-instruct-abliterated-q4_k_m.gguf';
    if (File(qwenPath).existsSync()) {
      print('[Test] Loading Qwen2.5 Coder Abliterated model...');
      final qwenResult = await DesktopInferenceEngine.instance.loadModel(
        modelPath: qwenPath,
        threads: 4,
        contextSize: 2048,
        rpcEndpoints: ['192.168.3.175:50052'],
      );
      expect(qwenResult.success, isTrue);
      print('[Test] Qwen result: ${qwenResult.message}');

      final qwenStream = DesktopInferenceEngine.instance.generateChat(
        messages: [
          ChatMessage(role: 'user', content: 'Write a python one-liner to print numbers 1 to 5.'),
        ],
        maxTokens: 32,
      );
      final qwenBuf = StringBuffer();
      await for (final token in qwenStream) {
        qwenBuf.write(token);
      }
      print('[Test] Qwen response: "${qwenBuf.toString().trim()}"');
      expect(qwenBuf.isNotEmpty, isTrue);

      await DesktopInferenceEngine.instance.unloadModel();
      print('[Test] Finished clean unload of Qwen.');
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
