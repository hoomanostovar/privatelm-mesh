import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:privatelm/models/chat_message.dart';
import 'package:privatelm/services/context_compactor_service.dart';
import 'package:privatelm/services/hive_service.dart';
import 'package:privatelm/widgets/code_block_builder.dart';

void main() {
  group('ContextCompactorService Tests', () {
    test('returns null when message count is less than or equal to retainRecent', () async {
      final messages = [
        ChatMessage(id: '1', chatId: 'c1', role: 'user', content: 'Hello'),
        ChatMessage(id: '2', chatId: 'c1', role: 'assistant', content: 'Hi there!'),
      ];

      final result = await ContextCompactorService.compact(
        messages: messages,
        retainRecent: 2,
      );

      expect(result, isNull);
    });

    test('heuristic summarizer extracts objectives, constraints, files, and errors', () async {
      final messages = [
        ChatMessage(
          id: '1',
          chatId: 'c1',
          role: 'user',
          content: 'We need to fix the crash when loading qwen2.5 coder 0.5B abliterated. Only build PC version on Windows, never build all binaries.',
        ),
        ChatMessage(
          id: '2',
          chatId: 'c1',
          role: 'assistant',
          content: 'Got it. Investigated lib/services/desktop_inference_engine.dart. Found error: llama-server exited with code -1073740791. Fixed the offline RPC check.',
        ),
        ChatMessage(
          id: '3',
          chatId: 'c1',
          role: 'user',
          content: 'we also want a compact function with a good algo like deepseek or claude.',
        ),
        ChatMessage(
          id: '4',
          chatId: 'c1',
          role: 'assistant',
          content: 'Working on context compaction now.',
        ),
      ];

      final result = await ContextCompactorService.compact(
        messages: messages,
        retainRecent: 2,
      );

      expect(result, isNotNull);
      expect(result!.prunedCount, equals(2));
      expect(result.summary, contains('<CONTEXT_SUMMARY>'));
      expect(result.summary, contains('### 1. Primary Objectives & Topics'));
      expect(result.summary, contains('### 2. Key Constraints & User Decisions'));
      expect(result.summary, contains('### 3. Important Technical Context & Files'));
      expect(result.summary, contains('### 4. Current State & Pending Tasks'));
      expect(result.summary, contains('</CONTEXT_SUMMARY>'));

      // Check extracted entities
      expect(result.summary.toLowerCase(), contains('qwen'));
      expect(result.summary, contains('desktop_inference_engine.dart'));
      expect(result.summary.toLowerCase(), contains('windows'));
    });

    test('preserves prior <CONTEXT_SUMMARY> sections across rolling compactions', () async {
      const priorSummary = '''
<CONTEXT_SUMMARY>
### 1. Primary Objectives & Topics
- Support offline local llama.cpp clustering.

### 2. Key Constraints & User Decisions
- Zero external software dependencies.
- Windows PC only for testing.

### 3. Important Technical Context & Files
- File: `lib/services/desktop_inference_engine.dart`
- Model: `qwen2.5-coder`

### 4. Current State & Pending Tasks
- Cluster RPC pre-flight TCP check implemented.
</CONTEXT_SUMMARY>''';

      final messages = [
        ChatMessage(id: '0', chatId: 'c1', role: 'system', content: priorSummary),
        ChatMessage(id: '1', chatId: 'c1', role: 'user', content: 'Now add text selection across lines.'),
        ChatMessage(id: '2', chatId: 'c1', role: 'assistant', content: 'Implemented SelectionArea and CodeBlockBuilder.'),
        ChatMessage(id: '3', chatId: 'c1', role: 'user', content: 'What next?'),
        ChatMessage(id: '4', chatId: 'c1', role: 'assistant', content: 'All set.'),
      ];

      final result = await ContextCompactorService.compact(
        messages: messages,
        retainRecent: 2,
      );

      expect(result, isNotNull);
      expect(result!.summary, contains('Zero external software dependencies'));
      expect(result.summary, contains('Windows PC only for testing'));
      expect(result.summary, contains('desktop_inference_engine.dart'));
      expect(result.summary, contains('Support offline local llama.cpp clustering.'));
    });
  });

  group('HiveService deleteMessages Test', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('hive_delete_test');
      Hive.init(tempDir.path);
    });

    tearDown(() async {
      await Hive.deleteFromDisk();
      await tempDir.delete(recursive: true);
    });

    test('deleteMessages removes targeted IDs while keeping others', () async {
      final hive = await HiveService().init();

      await hive.saveMessage('m1', {'id': 'm1', 'chatId': 'c1', 'content': 'First'});
      await hive.saveMessage('m2', {'id': 'm2', 'chatId': 'c1', 'content': 'Second'});
      await hive.saveMessage('m3', {'id': 'm3', 'chatId': 'c1', 'content': 'Third'});

      expect(hive.getMessagesForChat('c1').length, equals(3));

      await hive.deleteMessages(['m1', 'm2']);

      final remaining = hive.getMessagesForChat('c1');
      expect(remaining.length, equals(1));
      expect(remaining.first['id'], equals('m3'));
    });
  });

  group('CodeBlockBuilder Tests', () {
    testWidgets('CodeBlockBuilder extracts language and code properly', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                final builder = CodeBlockBuilder(context);
                final codeElement = md.Element('code', [md.Text('final x = 42;')]);
                codeElement.attributes['class'] = 'language-dart';

                final preElement = md.Element('pre', [codeElement]);

                final widget = builder.visitElementAfterWithContext(
                  context,
                  preElement,
                  null,
                  null,
                );

                expect(widget, isNotNull);
                expect(widget, isA<CodeBlockCard>());
                final card = widget as CodeBlockCard;
                expect(card.language, equals('dart'));
                expect(card.code, equals('final x = 42;'));

                return widget;
              },
            ),
          ),
        ),
      );

      await tester.pump();
      expect(find.text('DART'), findsOneWidget);
      expect(find.text('Copy code'), findsOneWidget);
      expect(find.text('final x = 42;'), findsOneWidget);
    });
  });
}
