import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/store.dart';
import '../domain/domain.dart';
import 'widgets.dart';

class SummaryScreen extends StatelessWidget {
  final int workoutId;
  const SummaryScreen(this.workoutId, {super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final scheme = Theme.of(context).colorScheme;

    return FutureBuilder<WorkoutDetail?>(
      future: store.workoutDetail(workoutId),
      builder: (context, snap) {
        if (snap.hasError) {
          return Scaffold(
            appBar: AppBar(title: const Text('Workout summary')),
            body: Center(
              child: EmptyState(
                title: 'Could not load this workout',
                subtitle: snap.error.toString(),
                icon: Icons.error_outline,
              ),
            ),
          );
        }
        final detail = snap.data;
        if (detail == null) {
          return const Scaffold(body: Center(child: Text('Workout not found')));
        }
        final completed = detail.exercises
            .expand((e) => e.sets)
            .where((s) => s.completedAt != null)
            .toList();
        final allSets = completed
            .map((s) =>
                (weightKg: s.weightKg, reps: s.reps, isWarmup: s.isWarmup))
            .toList();
        // Zero-rep sets are legal in the store but carry no e1RM (audit B4).
        final working = completed
            .where((s) => !s.isWarmup && s.reps >= 1)
            .map((s) => (s.weightKg, s.reps))
            .toList();
        final volume = volumeOf(allSets);
        final bestE1rm = working.isEmpty ? 0.0 : formatE1rm(e1rmMaxOf(working));
        final totals = volumeOf(allSets);

        return Scaffold(
          appBar: AppBar(title: Text('${detail.workout.name} · summary')),
          body: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                '${formatDateTime(detail.workout.startedAt)} · ${formatDuration(detail.workout.startedAt, detail.workout.endedAt)}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                    child: StatCard(
                        label: 'Total volume (${store.unit.label})',
                        value: trimZero(fromKg(totals.totalKg, store.unit)))),
                const SizedBox(width: 8),
                Expanded(
                    child: StatCard(
                        label: 'Best e1RM (kg)', value: trimZero(bestE1rm))),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                    child: StatCard(
                        label: 'Working sets', value: '${volume.sets}')),
                const SizedBox(width: 8),
                Expanded(
                    child:
                        StatCard(label: 'Total reps', value: '${volume.reps}')),
              ]),
              const SizedBox(height: 16),
              const SectionHeader('Exercises'),
              ...detail.exercises.map((view) {
                final v = volumeOf(view.sets
                    .where((s) => s.completedAt != null)
                    .map((s) => (
                          weightKg: s.weightKg,
                          reps: s.reps,
                          isWarmup: s.isWarmup
                        ))
                    .toList());
                return CardRow(
                  icon: Icons.fitness_center,
                  title: view.exercise.name,
                  subtitle:
                      '${view.exercise.muscleGroup} · ${v.sets} sets · ${v.reps} reps',
                  trailing:
                      '${trimZero(fromKg(v.totalKg, store.unit))} ${store.unit.label}',
                );
              }),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
                icon: Icon(Icons.delete_outline, color: scheme.error),
                label: Text('Delete workout',
                    style: TextStyle(color: scheme.error)),
                onPressed: () async {
                  await store.deleteWorkout(workoutId);
                  if (context.mounted) Navigator.of(context).pop();
                },
              ),
            ],
          ),
        );
      },
    );
  }
}
