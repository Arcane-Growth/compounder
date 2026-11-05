import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../data/store.dart';
import '../domain/domain.dart';
import 'health.dart';
import 'history.dart';
import 'progress.dart';
import 'settings.dart';
import 'summary.dart';
import 'widgets.dart';
import 'workout.dart';

class HomeTab extends StatelessWidget {
  const HomeTab({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          TintedIconCircle(Icons.fitness_center,
              background: scheme.primary, foreground: scheme.onPrimary),
          const SizedBox(width: 10),
          Text('Compounder', style: t.titleLarge),
        ]),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      body: FutureBuilder<Workout?>(
        future: store.activeWorkout(),
        builder: (context, snap) {
          final active = snap.data;
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const ScreenIntro(
                eyebrow: 'Compound your life',
                title: 'A little better,\nevery day.',
                subtitle:
                    'Health, wealth and mind — small reps in each, compounded on your own device.',
              ),
              const SizedBox(height: 20),
              if (active != null)
                Card(
                  color: scheme.primaryContainer,
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 12),
                    onTap: () => _openWorkout(context, active.id),
                    title: Text(active.name,
                        style: t.headlineSmall
                            ?.copyWith(color: scheme.onPrimaryContainer)),
                    subtitle: Text(
                      'Started ${formatDateTime(active.startedAt)} · tap to pick up where you left off',
                      style: TextStyle(color: scheme.onPrimaryContainer),
                    ),
                    trailing: Icon(Icons.play_arrow,
                        color: scheme.onPrimaryContainer),
                  ),
                )
              else
                FilledButton.icon(
                  onPressed: () async {
                    final name = await _askWorkoutName(context);
                    if (name == null) return;
                    final id = await store.createWorkout(name);
                    if (context.mounted) _openWorkout(context, id);
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('Start workout'),
                ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const HistoryScreen())),
                    icon: const Icon(Icons.history, size: 18),
                    label: const Text('History'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const ProgressScreen())),
                    icon: const Icon(Icons.show_chart, size: 18),
                    label: const Text('Progress'),
                  ),
                ),
              ]),
              const SizedBox(height: 24),
              const HealthSummaryCard(),
              const SizedBox(height: 24),
              const SectionHeader('Recent sessions'),
              const SizedBox(height: 8),
              if (store.history.isEmpty)
                const EmptyState(
                  title: 'No sessions yet',
                  subtitle:
                      'Create a workout and log your first lifts to see them here.',
                  icon: Icons.fitness_center,
                )
              else
                ...store.history.map((row) => CardRow(
                      icon: Icons.fitness_center,
                      title: row.name,
                      subtitle:
                          '${formatDate(row.startedAt)} · ${row.exerciseCount} exercises · ${row.setCount} sets',
                      trailing:
                          '${trimZero(fromKg(row.totalKg, store.unit))} ${store.unit.label}',
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => SummaryScreen(row.workoutId))),
                    )),
            ],
          );
        },
      ),
    );
  }

  void _openWorkout(BuildContext context, int id) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => WorkoutScreen(workoutId: id)));
  }
}

Future<String?> _askWorkoutName(BuildContext context) async {
  final controller = TextEditingController(text: 'Workout');
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('New workout'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Name'),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Start')),
      ],
    ),
  );
  return result;
}
