import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:provider/provider.dart';

import '../coach/agent.dart';
import '../coach/health_tools.dart';
import '../coach/tools.dart';
import '../data/store.dart';
import '../health/service.dart';
import '../llm/attachments.dart';
import '../llm/llm.dart';
import '../services/notify.dart';

class CoachMessage {
  final String role;
  final String text;
  const CoachMessage(this.role, this.text);
}

class CoachTab extends StatefulWidget {
  const CoachTab({super.key});

  @override
  State<CoachTab> createState() => _CoachTabState();
}

class _CoachTabState extends State<CoachTab> {
  final input = TextEditingController();
  final scroll = ScrollController();
  List<CoachMessage> messages = [
    const CoachMessage(
      ChatMessage.roleAssistant,
      "Hi! I'm your Compounder coach. Ask me about your training, meals, money, mood, sleep or heart data — "
      "or attach a photo, PDF or CSV and I'll read it. Try \"How did I sleep this week?\" "
      "or \"What's my net worth trend?\"",
    ),
  ];
  List<Attachment> attachments = [];
  bool thinking = false;
  bool attaching = false;
  String? activeTool;
  String? error;
  CoachAgent? agent;

  CoachAgent _buildAgent(
          AppStore store, NotifyService notify, HealthService health) =>
      CoachAgent(
        toolList: [
          HealthOverviewTool(health.repository, health),
          SleepTool(health.repository),
          HeartRateTool(health.repository),
          HealthMetricTool(health.repository),
          HealthWorkoutsTool(health.repository),
          HealthSyncStatusTool(health),
          NutritionTool(store),
          WorkoutTool(store),
          ExerciseProgressTool(store),
          NetWorthTool(store),
          NetWorthHistoryTool(store),
          ProjectUpsideTool(store),
          MindLogTool(store),
          LogMealTool(store),
          LogMoodTool(store),
          StartWorkoutTool(store),
          AddSetTool(store),
          SetReminderTool(store, notify),
          ListRemindersTool(store),
          CancelReminderTool(store, notify),
        ],
        onToolRun: (name) => setState(() => activeTool = name),
      );

  Future<void> _attachFiles() async {
    setState(() => attaching = true);
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: Attachment.supportedExtensions,
      );
      if (files.isEmpty) return;
      final picked = <Attachment>[];
      for (final file in files) {
        final bytes = await _readBytes(file);
        if (bytes != null) picked.add(Attachment(file.name, bytes));
      }
      setState(() => attachments = [...attachments, ...picked]);
    } finally {
      if (mounted) setState(() => attaching = false);
    }
  }

  Future<Uint8List?> _readBytes(PlatformFile file) async {
    try {
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  Future<void> _send() async {
    final text = input.text.trim();
    if ((text.isEmpty && attachments.isEmpty) || thinking) return;
    final store = context.read<AppStore>();
    final notify = context.read<NotifyService>();
    final health = context.read<HealthService>();
    final ai = store.ai;
    if (!ai.configured) {
      setState(() => error =
          'Set your AI endpoint and key in Settings before using the coach.');
      return;
    }
    final sentAttachments = attachments;
    input.clear();
    final display = text +
        (sentAttachments.isEmpty
            ? ''
            : '\n\n[attached: ${sentAttachments.map((a) => a.name).join(', ')}]');
    setState(() {
      messages = [
        ...messages,
        CoachMessage(ChatMessage.roleUser, display.trim())
      ];
      attachments = [];
      thinking = true;
      error = null;
      activeTool = null;
    });
    try {
      final userMessage = await buildUserMessage(text, sentAttachments);
      agent ??= _buildAgent(store, notify, health);
      final reply = await agent!.replyMessage(
          ChatClient(ai.baseUrl, ai.apiKey, ai.model), userMessage);
      if (!mounted) return;
      setState(() {
        messages = [
          ...messages,
          CoachMessage(ChatMessage.roleAssistant, reply)
        ];
        thinking = false;
        activeTool = null;
      });
      notify.rescheduleDaily(store);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        thinking = false;
        activeTool = null;
        error = e.toString();
      });
    }
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scroll.hasClients) scroll.jumpTo(scroll.position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    input.dispose();
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Coach'),
        actions: [
          IconButton(
            icon: const Icon(Icons.attach_file),
            tooltip: 'Attach image, CSV or PDF',
            onPressed: attaching ? null : _attachFiles,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'New conversation',
            onPressed: () {
              agent?.reset();
              setState(() {
                messages = [
                  const CoachMessage(ChatMessage.roleAssistant,
                      'Fresh start. What are we working on?')
                ];
                error = null;
              });
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: scroll,
              padding: const EdgeInsets.all(16),
              itemCount: messages.length + (thinking ? 1 : 0),
              itemBuilder: (context, i) {
                if (i == messages.length) {
                  return _Bubble(
                    isUser: false,
                    child: Row(children: [
                      const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: 12),
                      Text(
                        activeTool == null
                            ? 'Thinking…'
                            : 'Reading your $activeTool data…',
                        style: t.bodyMedium
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ]),
                  );
                }
                final m = messages[i];
                final isUser = m.role == ChatMessage.roleUser;
                return _Bubble(
                  isUser: isUser,
                  child: isUser
                      ? Text(m.text,
                          style:
                              t.bodyMedium?.copyWith(color: scheme.onPrimary))
                      : GptMarkdown(
                          m.text,
                          style:
                              t.bodyMedium?.copyWith(color: scheme.onSurface),
                          isStreaming: false,
                        ),
                );
              },
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Card(
                color: scheme.errorContainer,
                child: ListTile(
                  title: Text(error!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: scheme.onErrorContainer)),
                  trailing: TextButton(
                      onPressed: () => setState(() => error = null),
                      child: const Text('Dismiss')),
                ),
              ),
            ),
          if (attachments.isNotEmpty)
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final a in attachments)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: InputChip(
                        avatar: Icon(
                          a.isImage
                              ? Icons.image_outlined
                              : a.isPdf
                                  ? Icons.picture_as_pdf_outlined
                                  : Icons.description_outlined,
                          size: 18,
                        ),
                        label: Text(
                            '${a.name} (${(a.bytes.length / 1024).round()} KB)'),
                        onDeleted: () => setState(() => attachments =
                            attachments.where((x) => x != a).toList()),
                      ),
                    ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: input,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: const InputDecoration(
                    hintText: 'Ask about health, wealth or mind…',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  padding: EdgeInsets.zero,
                ),
                onPressed: thinking ? null : _send,
                child: const Icon(Icons.send),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final bool isUser;
  final Widget child;
  const _Bubble({required this.isUser, required this.child});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        constraints: const BoxConstraints(maxWidth: 520),
        decoration: BoxDecoration(
          color: isUser ? scheme.primary : scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(isUser ? 18 : 6),
            bottomRight: Radius.circular(isUser ? 6 : 18),
          ),
        ),
        child: child,
      ),
    );
  }
}
