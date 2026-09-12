import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/store.dart';
import '../domain/domain.dart';
import 'picker.dart';
import 'summary.dart';
import 'widgets.dart';

class WorkoutScreen extends StatefulWidget {
  final int workoutId;
  const WorkoutScreen({super.key, required this.workoutId});

  @override
  State<WorkoutScreen> createState() => _WorkoutScreenState();
}

class _WorkoutScreenState extends State<WorkoutScreen> {
  int restLeft = 0;
  Timer? restTimer;
  final Map<int, String> weightEdits = {};
  final Map<int, String> repsEdits = {};

  @override
  void dispose() {
    restTimer?.cancel();
    super.dispose();
  }

  void _startRest() {
    final seconds = context.read<AppStore>().restSeconds;
    restTimer?.cancel();
    setState(() => restLeft = seconds);
    restTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() {
        restLeft--;
        if (restLeft <= 0) timer.cancel();
      });
    });
  }

  Future<void> _completeSet(AppStore store, int setId, double weightKg, int reps) async {
    final weight = weightEdits[setId];
    final repsText = repsEdits[setId];
    await store.updateSet(
      setId,
      weightKg: double.tryParse(weight ?? '') ?? weightKg,
      reps: int.tryParse(repsText ?? '') ?? reps,
      completedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _startRest();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;

    return FutureBuilder<WorkoutDetail?>(
      future: store.workoutDetail(widget.workoutId),
      builder: (context, snap) {
        final detail = snap.data;
        if (detail == null) {
          return const Scaffold(body: Center(child: Text('Workout not found')));
        }
        final volume = detail.volume;
        return Scaffold(
          appBar: AppBar(
            title: Text(detail.workout.name),
            actions: [
              if (restLeft > 0)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: ActionChip(
                      avatar: Icon(Icons.timer, size: 16, color: scheme.primary),
                      label: Text('${restLeft ~/ 60}:${(restLeft % 60).toString().padLeft(2, '0')}'),
                      onPressed: () {
                        restTimer?.cancel();
                        setState(() => restLeft = 0);
                      },
                    ),
                  ),
                ),
              if (detail.workout.active)
                TextButton(
                  onPressed: () async {
                    await store.finishWorkout(widget.workoutId);
                    if (!context.mounted) return;
                    Navigator.of(context).pushReplacement(MaterialPageRoute(
                        builder: (_) => SummaryScreen(widget.workoutId)));
                  },
                  child: Text('Finish',
                      style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w700)),
                ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Row(children: [
                Expanded(child: StatCard(label: 'Volume (${store.unit.label})',
                    value: trimZero(fromKg(volume.totalKg, store.unit)))),
                const SizedBox(width: 8),
                Expanded(child: StatCard(label: 'Sets · reps', value: '${volume.sets} · ${volume.reps}')),
              ]),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () async {
                  final exerciseId = await Navigator.of(context).push<int>(
                      MaterialPageRoute(builder: (_) => const ExercisePickerScreen()));
                  if (exerciseId != null) {
                    await store.addExerciseToWorkout(widget.workoutId, exerciseId);
                  }
                },
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add exercise'),
              ),
              const SizedBox(height: 16),
              if (detail.exercises.isEmpty)
                const EmptyState(
                  title: 'Empty workout',
                  subtitle: 'Add your first exercise to start logging sets.',
                  icon: Icons.add_chart,
                ),
              ...detail.exercises.map((view) => Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Card(
                      color: scheme.surfaceContainerLow,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(view.exercise.name, style: t.titleMedium),
                                  Text(view.exercise.muscleGroup,
                                      style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                                ]),
                              ),
                              IconButton(
                                icon: Icon(Icons.delete_outline, color: scheme.outline),
                                tooltip: 'Remove exercise',
                                onPressed: () => store.removeExercise(view.entry.id),
                              ),
                            ]),
                            const SizedBox(height: 4),
                            ...view.sets.map((set) {
                              final done = set.completedAt != null;
                              final weight = weightEdits[set.id] ??
                                  trimZero(fromKg(set.weightKg, store.unit));
                              final reps = repsEdits[set.id] ?? set.reps.toString();
                              return Padding(
                                padding: const EdgeInsets.symmetric(vertical: 4),
                                child: Row(children: [
                                  SizedBox(
                                    width: 26,
                                    child: Text('${view.sets.indexOf(set) + 1}',
                                        style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                                  ),
                                  SizedBox(
                                    width: 84,
                                    child: TextField(
                                      enabled: !done,
                                      controller: TextEditingController(text: weight),
                                      onChanged: (v) => weightEdits[set.id] = v,
                                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                      decoration: InputDecoration(
                                        isDense: true,
                                        suffixText: store.unit.label,
                                        border: const OutlineInputBorder(),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  SizedBox(
                                    width: 60,
                                    child: TextField(
                                      enabled: !done,
                                      controller: TextEditingController(text: reps),
                                      onChanged: (v) => repsEdits[set.id] = v,
                                      keyboardType: TextInputType.number,
                                      decoration: const InputDecoration(
                                        isDense: true,
                                        hintText: 'reps',
                                        border: OutlineInputBorder(),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Checkbox(
                                    value: set.isWarmup,
                                    onChanged: done
                                        ? null
                                        : (v) => store.updateSet(set.id, warmup: v ?? false),
                                  ),
                                  IconButton(
                                    icon: Icon(
                                      done ? Icons.check_circle : Icons.circle_outlined,
                                      color: done ? scheme.primary : scheme.outline,
                                    ),
                                    tooltip: 'Complete set',
                                    onPressed: done
                                        ? () => store.updateSet(set.id, completedAt: 0)
                                        : () => _completeSet(store, set.id, set.weightKg, set.reps),
                                  ),
                                ]),
                              );
                            }),
                            TextButton.icon(
                              onPressed: () => store.addSet(
                                  view.entry.id,
                                  view.sets.isEmpty
                                      ? 20
                                      : view.sets.last.weightKg,
                                  view.sets.isEmpty ? 8 : view.sets.last.reps),
                              icon: const Icon(Icons.add, size: 18),
                              label: const Text('Add set'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )),
            ],
          ),
        );
      },
    );
  }
}
