import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../coach/agent.dart';
import '../coach/tools.dart';
import '../data/store.dart';
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
      "Hi! I'm your Compounder coach. Ask me about your training, meals, net worth or mood — "
          "for example \"How is my deadlift progressing?\", \"What's my net worth?\" or "
          "\"How have I been feeling this week?\"",
    ),
  ];
  bool thinking = false;
  String? activeTool;
  String? error;
  CoachAgent? agent;

  CoachAgent _buildAgent(AppStore store) => CoachAgent(
        toolList: [
          NutritionTool(store),
          WorkoutTool(store),
          ExerciseProgressTool(store),
          NetWorthTool(store),
          MindLogTool(store),
          LogMealTool(store),
          LogMoodTool(store),
          StartWorkoutTool(store),
          AddSetTool(store),
        ],
        onToolRun: (name) => setState(() => activeTool = name),
      );

  Future<void> _send() async {
    final text = input.text.trim();
    if (text.isEmpty || thinking) return;
    final store = context.read<AppStore>();
    final ai = store.ai;
    if (!ai.configured) {
      setState(() => error = 'Set your AI endpoint and key in Settings before using the coach.');
      return;
    }
    input.clear();
    setState(() {
      messages = [...messages, CoachMessage(ChatMessage.roleUser, text)];
      thinking = true;
      error = null;
      activeTool = null;
    });
    try {
      agent ??= _buildAgent(store);
      final reply = await agent!.reply(ChatClient(ai.baseUrl, ai.apiKey, ai.model), text);
      if (!mounted) return;
      setState(() {
        messages = [...messages, CoachMessage(ChatMessage.roleAssistant, reply)];
        thinking = false;
        activeTool = null;
      });
      context.read<NotifyService>().rescheduleDaily(store);
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
            icon: const Icon(Icons.refresh),
            tooltip: 'New conversation',
            onPressed: () {
              agent?.reset();
              setState(() {
                messages = [
                  const CoachMessage(ChatMessage.roleAssistant, 'Fresh start. What are we working on?')
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
                          width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: 12),
                      Text(
                        activeTool == null ? 'Thinking…' : 'Reading your $activeTool data…',
                        style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ]),
                  );
                }
                final m = messages[i];
                final isUser = m.role == ChatMessage.roleUser;
                return _Bubble(
                  isUser: isUser,
                  child: Text(m.text,
                      style: t.bodyMedium?.copyWith(color: isUser ? scheme.onPrimary : scheme.onSurface)),
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
                      onPressed: () => setState(() => error = null), child: const Text('Dismiss')),
                ),
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
        constraints: const BoxConstraints(maxWidth: 460),
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
