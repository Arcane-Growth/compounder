import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/store.dart';
import '../domain/domain.dart';
import 'breathing.dart';
import 'widgets.dart';

class MindTab extends StatefulWidget {
  const MindTab({super.key});

  @override
  State<MindTab> createState() => _MindTabState();
}

class _MindTabState extends State<MindTab> {
  static const moodLabels = ['Rough', 'Low', 'Okay', 'Good', 'Great'];
  static const moodIcons = [
    Icons.sentiment_very_dissatisfied,
    Icons.sentiment_dissatisfied,
    Icons.sentiment_neutral,
    Icons.sentiment_satisfied,
    Icons.sentiment_very_satisfied,
  ];

  int _selectedMood = 0;
  final moodNote = TextEditingController();

  int _minutes = 10;

  @override
  void dispose() {
    moodNote.dispose();
    super.dispose();
  }

  void _beginSession() {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => BreathingSession(minutes: _minutes)));
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;

    final streak = Mind.moodStreak(
        store.moods.map((m) => DateTime.fromMillisecondsSinceEpoch(m.timestamp)).toList());
    final weekAgo = DateTime.now().subtract(const Duration(days: 7)).millisecondsSinceEpoch;
    final weekMoods = store.moods.where((m) => m.timestamp >= weekAgo).map((m) => m.mood).toList();
    final weekAvg = Mind.averageMood(weekMoods);

    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          TintedIconCircle(Icons.psychology,
              background: scheme.primary, foreground: scheme.onPrimary),
          const SizedBox(width: 10),
          Text('Mind', style: t.titleLarge),
        ]),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            color: scheme.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const TintedIconCircle(Icons.sentiment_satisfied),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('How are you feeling?', style: t.titleMedium),
                      Text('One honest data point a day compounds into self-knowledge.',
                          style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                    ]),
                  ),
                ]),
                const SizedBox(height: 14),
                Row(children: [
                  for (var i = 1; i <= 5; i++)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: ChoiceChip(
                          selected: _selectedMood == i,
                          onSelected: (_) => setState(() => _selectedMood = i),
                          avatar: Icon(moodIcons[i - 1], size: 20),
                          label: Text(moodLabels[i - 1], style: t.labelSmall),
                          labelStyle: const TextStyle(fontSize: 10),
                          padding: EdgeInsets.zero,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ),
                ]),
                const SizedBox(height: 12),
                TextField(
                  controller: moodNote,
                  decoration: const InputDecoration(labelText: "What's behind it? (optional)"),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _selectedMood == 0
                      ? null
                      : () {
                          store.logMood(_selectedMood, moodNote.text.trim());
                          setState(() {
                            moodNote.clear();
                            _selectedMood = 0;
                          });
                        },
                  icon: const Icon(Icons.check),
                  label: const Text('Log mood'),
                ),
                const SizedBox(height: 14),
                Row(children: [
                  Expanded(child: StatCard(label: 'Check-in streak', value: '$streak days')),
                  const SizedBox(width: 8),
                  Expanded(
                      child: StatCard(
                          label: '7-day average',
                          value: weekAvg == null ? '–' : '${weekAvg.toStringAsFixed(1)} / 5')),
                ]),
              ]),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            color: scheme.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const TintedIconCircle(Icons.spa),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Sit with it', style: t.titleMedium),
                      Text('Pick a length and follow the bubble: breathe in, hold, breathe out. '
                          'Finished sessions are logged.',
                          style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                    ]),
                  ),
                ]),
                const SizedBox(height: 14),
                Row(children: [
                  for (final m in [3, 5, 10, 20])
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: ChoiceChip(
                          label: Text('$m min'),
                          selected: _minutes == m,
                          onSelected: (_) => setState(() => _minutes = m),
                        ),
                      ),
                    ),
                ]),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: _beginSession,
                  icon: const Icon(Icons.self_improvement),
                  label: Text('Begin guided $_minutes-minute session'),
                ),
                if (store.meditations.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    'Last session: ${store.meditations.first.minutes} min · '
                    '${formatDate(store.meditations.first.timestamp)}',
                    style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ]),
            ),
          ),
          const SizedBox(height: 20),
          const SectionHeader('Thought records'),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New thought record'),
            onPressed: () => _showThoughtDialog(context, store),
          ),
          const SizedBox(height: 8),
          if (store.thoughts.isEmpty)
            const EmptyState(
              title: 'Nothing written yet',
              subtitle: 'Capture a situation, the thought that came with it, and a kinder, truer reply.',
              icon: Icons.edit_note,
            )
          else
            ...store.thoughts.map((record) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Card(
                    color: scheme.surfaceContainerLow,
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Expanded(child: Text(record.situation, style: t.titleMedium)),
                          IconButton(
                            icon: Icon(Icons.delete_outline, color: scheme.outline),
                            onPressed: () => store.deleteThought(record.id),
                          ),
                        ]),
                        const SizedBox(height: 4),
                        Text('The thought',
                            style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                        Text(record.thought, style: t.bodyMedium),
                        if (record.reframe.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Icon(Icons.check, size: 16, color: scheme.primary),
                            const SizedBox(width: 8),
                            Expanded(
                                child: Text(record.reframe,
                                    style: t.bodyMedium?.copyWith(color: scheme.primary))),
                          ]),
                        ],
                        const SizedBox(height: 8),
                        Text(formatDateTime(record.timestamp),
                            style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                      ]),
                    ),
                  ),
                )),
        ],
      ),
    );
  }

  void _showThoughtDialog(BuildContext context, AppStore store) {
    final situation = TextEditingController();
    final thought = TextEditingController();
    final reframe = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New thought record'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: situation, decoration: const InputDecoration(labelText: 'What happened?')),
            const SizedBox(height: 12),
            TextField(
                controller: thought,
                decoration: const InputDecoration(labelText: 'What did you tell yourself?')),
            const SizedBox(height: 12),
            TextField(
                controller: reframe,
                decoration:
                    const InputDecoration(labelText: 'A kinder, truer reply (optional)')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: thought.text.trim().isEmpty
                ? null
                : () {
                    store.logThought(
                        situation.text.trim(), thought.text.trim(), reframe.text.trim());
                    Navigator.pop(context);
                  },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}
