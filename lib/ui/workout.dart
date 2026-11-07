import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
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
  AppStore? _store;
  WorkoutDetail? _detail;
  bool _loading = true;

  final Map<int, TextEditingController> _weightControllers = {};
  final Map<int, TextEditingController> _repsControllers = {};
  final Map<int, FocusNode> _weightFocus = {};
  final Map<int, FocusNode> _repsFocus = {};
  final Map<int, WorkoutSet> _setsById = {};

  final ValueNotifier<int> _restLeft = ValueNotifier(0);
  Timer? _restTimer;

  @override
  void initState() {
    super.initState();
    _store = context.read<AppStore>();
    _loadDetail();
  }

  @override
  void dispose() {
    _restTimer?.cancel();
    _restLeft.dispose();
    for (final controller in _weightControllers.values) {
      controller.dispose();
    }
    for (final controller in _repsControllers.values) {
      controller.dispose();
    }
    for (final node in _weightFocus.values) {
      node.dispose();
    }
    for (final node in _repsFocus.values) {
      node.dispose();
    }
    super.dispose();
  }

  Future<void> _loadDetail() async {
    final detail = await _store!.workoutDetail(widget.workoutId);
    if (!mounted) return;
    setState(() {
      _detail = detail;
      _loading = false;
      _syncControllers();
    });
  }

  Future<void> _reloadDetail() async {
    final detail = await _store!.workoutDetail(widget.workoutId);
    if (!mounted) return;
    setState(() {
      _detail = detail;
      _syncControllers();
    });
  }

  void _syncControllers() {
    final detail = _detail;
    if (detail == null) return;
    final unit = _store!.unit;
    final active = <int>{};
    _setsById.clear();
    for (final view in detail.exercises) {
      for (final set in view.sets) {
        active.add(set.id);
        _setsById[set.id] = set;
        final weightText = trimZero(fromKg(set.weightKg, unit));
        final repsText = set.reps.toString();
        final weightController = _weightControllers.putIfAbsent(
            set.id, () => TextEditingController(text: weightText));
        final repsController = _repsControllers.putIfAbsent(
            set.id, () => TextEditingController(text: repsText));
        final weightNode = _focusFor(set.id, true);
        final repsNode = _focusFor(set.id, false);
        if (!weightNode.hasFocus && weightController.text != weightText) {
          weightController.text = weightText;
        }
        if (!repsNode.hasFocus && repsController.text != repsText) {
          repsController.text = repsText;
        }
      }
    }
    for (final id in _weightControllers.keys.toList()) {
      if (active.contains(id)) continue;
      _weightControllers.remove(id)?.dispose();
      _repsControllers.remove(id)?.dispose();
      _weightFocus.remove(id)?.dispose();
      _repsFocus.remove(id)?.dispose();
      _setsById.remove(id);
    }
  }

  FocusNode _focusFor(int setId, bool weight) {
    final nodes = weight ? _weightFocus : _repsFocus;
    return nodes.putIfAbsent(setId, () {
      final node = FocusNode();
      node.addListener(() {
        if (!node.hasFocus) _saveSetValues(setId);
      });
      return node;
    });
  }

  List<({int id, double weightKg, int reps})> _pendingUpdates() {
    final unit = _store!.unit;
    final updates = <({int id, double weightKg, int reps})>[];
    for (final entry in _setsById.entries) {
      final weightController = _weightControllers[entry.key];
      final repsController = _repsControllers[entry.key];
      if (weightController == null || repsController == null) {
        continue;
      }
      final parsedWeight = parseWeightKg(weightController.text, unit);
      final parsedReps = int.tryParse(repsController.text.trim());
      if (parsedWeight == null || parsedReps == null) {
        continue;
      }
      final weightKg = parsedWeight < 0 ? 0.0 : parsedWeight;
      final reps = parsedReps < 0 ? 0 : parsedReps;
      final set = entry.value;
      if ((weightKg - set.weightKg).abs() < 0.0001 && reps == set.reps) {
        continue;
      }
      updates.add((id: entry.key, weightKg: weightKg, reps: reps));
    }
    return updates;
  }

  Future<void> _persistPendingUpdates(
      List<({int id, double weightKg, int reps})> updates) async {
    for (final update in updates) {
      await _store!
          .updateSet(update.id, weightKg: update.weightKg, reps: update.reps);
    }
    if (updates.isNotEmpty) await _reloadDetail();
  }

  Future<void> _saveSetValues(int setId, {bool reload = true}) async {
    final set = _setsById[setId];
    final weightController = _weightControllers[setId];
    final repsController = _repsControllers[setId];
    if (set == null || weightController == null || repsController == null) {
      return;
    }
    final unit = _store!.unit;
    final parsedWeight = parseWeightKg(weightController.text, unit);
    final parsedReps = int.tryParse(repsController.text.trim());
    if (parsedWeight == null) {
      weightController.text = trimZero(fromKg(set.weightKg, unit));
    }
    if (parsedReps == null) {
      repsController.text = set.reps.toString();
    }
    if (parsedWeight == null || parsedReps == null) return;
    final weightKg = parsedWeight < 0 ? 0.0 : parsedWeight;
    final reps = parsedReps < 0 ? 0 : parsedReps;
    if ((weightKg - set.weightKg).abs() < 0.0001 && reps == set.reps) return;
    await _store!.updateSet(setId, weightKg: weightKg, reps: reps);
    if (reload) await _reloadDetail();
  }

  void _startRest() {
    final seconds = _store!.restSeconds;
    _restTimer?.cancel();
    _restLeft.value = seconds;
    _restTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      final next = _restLeft.value - 1;
      _restLeft.value = next < 0 ? 0 : next;
      if (next <= 0) timer.cancel();
    });
  }

  Future<void> _toggleWarmup(WorkoutSet set, bool warmup) async {
    await _saveSetValues(set.id, reload: false);
    await _store!.updateSet(set.id, warmup: warmup);
    await _reloadDetail();
  }

  Future<void> _toggleComplete(WorkoutSet set) async {
    if (set.completedAt != null) {
      await _store!.updateSet(set.id, completedAt: 0);
      await _reloadDetail();
      return;
    }
    await _saveSetValues(set.id, reload: false);
    await _store!
        .updateSet(set.id, completedAt: DateTime.now().millisecondsSinceEpoch);
    _startRest();
    await _reloadDetail();
  }

  Future<void> _addSet(ExerciseView view) async {
    final last = view.sets.isEmpty ? null : view.sets.last;
    if (last != null) await _saveSetValues(last.id, reload: false);
    final unit = _store!.unit;
    final weightController = last == null ? null : _weightControllers[last.id];
    final repsController = last == null ? null : _repsControllers[last.id];
    final weightKg = (weightController == null
            ? null
            : parseWeightKg(weightController.text, unit)) ??
        last?.weightKg ??
        0;
    final reps = (repsController == null
            ? null
            : int.tryParse(repsController.text.trim())) ??
        last?.reps ??
        0;
    await _store!.addSet(
        view.entry.id, weightKg < 0 ? 0 : weightKg, reps < 0 ? 0 : reps,
        completed: false);
    await _reloadDetail();
  }

  Widget _restChip(ColorScheme scheme) {
    return ValueListenableBuilder<int>(
      valueListenable: _restLeft,
      builder: (context, restLeft, _) {
        if (restLeft <= 0) return const SizedBox.shrink();
        return Center(
          child: Padding(
            padding: const EdgeInsets.only(right: 12),
            child: ActionChip(
              avatar: Icon(Icons.timer, size: 16, color: scheme.primary),
              label: Text(
                  '${restLeft ~/ 60}:${(restLeft % 60).toString().padLeft(2, '0')}'),
              onPressed: () {
                _restTimer?.cancel();
                _restLeft.value = 0;
              },
            ),
          ),
        );
      },
    );
  }

  Widget _setHeader(ColorScheme scheme, TextTheme t, String unitLabel) {
    final style =
        t.labelSmall?.copyWith(color: scheme.onSurfaceVariant, fontSize: 10);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(children: [
        SizedBox(width: 20, child: Text('#', style: style)),
        SizedBox(
          width: 70,
          child: Text('Weight ($unitLabel)',
              style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(width: 4),
        SizedBox(width: 40, child: Text('Reps', style: style)),
        const SizedBox(width: 4),
        SizedBox(
            width: 48,
            child: Text('Warm-up',
                style: style, textAlign: TextAlign.center, maxLines: 2)),
        SizedBox(
            width: 48,
            child: Text('Done', style: style, textAlign: TextAlign.center)),
      ]),
    );
  }

  Widget _setRow(BuildContext context, ColorScheme scheme, TextTheme t,
      ExerciseView view, int index, WorkoutSet set) {
    final weightController = _weightControllers[set.id];
    final repsController = _repsControllers[set.id];
    if (weightController == null || repsController == null) {
      return const SizedBox.shrink();
    }
    final weightNode = _focusFor(set.id, true);
    final repsNode = _focusFor(set.id, false);
    final done = set.completedAt != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        SizedBox(
          width: 20,
          child: Text('${index + 1}',
              style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
        ),
        SizedBox(
          width: 70,
          child: TextField(
            controller: weightController,
            focusNode: weightNode,
            onSubmitted: (_) => _saveSetValues(set.id),
            onTapOutside: (_) => FocusScope.of(context).unfocus(),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textAlign: TextAlign.center,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            ),
          ),
        ),
        const SizedBox(width: 4),
        SizedBox(
          width: 40,
          child: TextField(
            controller: repsController,
            focusNode: repsNode,
            onSubmitted: (_) => _saveSetValues(set.id),
            onTapOutside: (_) => FocusScope.of(context).unfocus(),
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            decoration: const InputDecoration(
              isDense: true,
              hintText: '0',
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            ),
          ),
        ),
        const SizedBox(width: 4),
        SizedBox(
          width: 48,
          child: Tooltip(
            message: 'Warm-up set',
            child: Checkbox(
              value: set.isWarmup,
              onChanged: (value) => _toggleWarmup(set, value ?? false),
            ),
          ),
        ),
        SizedBox(
          width: 48,
          child: Tooltip(
            message: done ? 'Mark set incomplete' : 'Mark set complete',
            child: Checkbox(
              value: done,
              onChanged: (_) => _toggleComplete(set),
            ),
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final detail = _detail;

    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Workout')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (detail == null) {
      return const Scaffold(body: Center(child: Text('Workout not found')));
    }

    final volume = volumeOf(detail.exercises
        .expand((e) => e.sets)
        .where((s) => s.completedAt != null)
        .map(
            (s) => (weightKg: s.weightKg, reps: s.reps, isWarmup: s.isWarmup)));

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) unawaited(_persistPendingUpdates(_pendingUpdates()));
      },
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: 72,
          title: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(detail.workout.name,
                  style: t.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              _ElapsedTimer(
                  startedAt: detail.workout.startedAt,
                  endedAt: detail.workout.endedAt),
            ],
          ),
          actions: [
            _restChip(scheme),
            if (detail.workout.active)
              TextButton(
                onPressed: () async {
                  await _persistPendingUpdates(_pendingUpdates());
                  await store.finishWorkout(widget.workoutId);
                  if (!context.mounted) return;
                  Navigator.of(context).pushReplacement(MaterialPageRoute(
                      builder: (_) => SummaryScreen(widget.workoutId)));
                },
                child: Text('Finish',
                    style: TextStyle(
                        color: scheme.primary, fontWeight: FontWeight.w700)),
              ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Row(children: [
              Expanded(
                  child: StatCard(
                      label: 'Volume (${store.unit.label})',
                      value: trimZero(fromKg(volume.totalKg, store.unit)))),
              const SizedBox(width: 8),
              Expanded(
                  child: StatCard(
                      label: 'Sets · reps',
                      value: '${volume.sets} · ${volume.reps}')),
            ]),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () async {
                final exerciseId = await Navigator.of(context).push<int>(
                    MaterialPageRoute(
                        builder: (_) => const ExercisePickerScreen()));
                if (exerciseId == null) return;
                try {
                  await _store!.addExerciseToWorkout(
                      widget.workoutId, exerciseId,
                      seedDefaultSet: true);
                } on StoreException catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text(e.message)));
                  }
                  return;
                }
                await _reloadDetail();
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
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(view.exercise.name,
                                        style: t.titleMedium),
                                    Text(view.exercise.muscleGroup,
                                        style: t.bodySmall?.copyWith(
                                            color: scheme.onSurfaceVariant)),
                                  ]),
                            ),
                            IconButton(
                              icon: Icon(Icons.delete_outline,
                                  color: scheme.outline),
                              tooltip: 'Remove exercise',
                              onPressed: () async {
                                await _persistPendingUpdates(_pendingUpdates());
                                await _store!.removeExercise(view.entry.id);
                                await _reloadDetail();
                              },
                            ),
                          ]),
                          const SizedBox(height: 4),
                          _setHeader(scheme, t, store.unit.label),
                          ...view.sets.asMap().entries.map((entry) => _setRow(
                              context,
                              scheme,
                              t,
                              view,
                              entry.key,
                              entry.value)),
                          TextButton.icon(
                            onPressed: () => _addSet(view),
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
      ),
    );
  }
}

class _ElapsedTimer extends StatefulWidget {
  final int startedAt;
  final int? endedAt;

  const _ElapsedTimer({required this.startedAt, this.endedAt});

  @override
  State<_ElapsedTimer> createState() => _ElapsedTimerState();
}

class _ElapsedTimerState extends State<_ElapsedTimer> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void didUpdateWidget(covariant _ElapsedTimer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.startedAt != widget.startedAt ||
        oldWidget.endedAt != widget.endedAt) {
      _syncTimer();
    }
  }

  void _syncTimer() {
    _timer?.cancel();
    if (widget.endedAt == null) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final label = widget.endedAt == null ? 'Elapsed' : 'Duration';
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.timer_outlined, size: 14, color: scheme.primary),
      const SizedBox(width: 4),
      Text(
        '$label ${formatDuration(widget.startedAt, widget.endedAt)}',
        style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ]);
  }
}
