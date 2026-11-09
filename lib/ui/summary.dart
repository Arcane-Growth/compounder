import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../data/store.dart';
import '../domain/domain.dart';
import 'widgets.dart';

class SummaryScreen extends StatefulWidget {
  final int workoutId;
  const SummaryScreen(this.workoutId, {super.key});

  @override
  State<SummaryScreen> createState() => _SummaryScreenState();
}

class _SummaryScreenState extends State<SummaryScreen> {
  /// The detail future is created once so a rebuild (the store notifying, a
  /// theme change, an expansion toggle) never re-queries the database and
  /// never drops the loaded workout back to a loading state.
  late final Future<WorkoutDetail?> _detail;

  /// Personal records for this session, read from the persisted flags so the
  /// summary agrees with what the user was shown during the workout.
  late final Future<List<PrSummary>> _prs;

  /// Workout-exercise ids whose set list is expanded. Held in State so the
  /// expansion survives rebuilds and expanding one exercise does not collapse
  /// another. Collapsed by default: the owner asked to expand "if I want".
  final Set<int> _expanded = <int>{};

  @override
  void initState() {
    super.initState();
    final store = context.read<AppStore>();
    _detail = store.workoutDetail(widget.workoutId);
    _prs = store.prSummary(widget.workoutId);
    // Observe the PR future as soon as it exists: the FutureBuilder only
    // subscribes once the workout detail has loaded, so a query that fails
    // faster than that would otherwise surface as an unhandled async error.
    _prs.then<void>((_) {}, onError: (Object _) {});
  }

  void _toggle(int workoutExerciseId) {
    setState(() {
      if (!_expanded.remove(workoutExerciseId)) {
        _expanded.add(workoutExerciseId);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final scheme = Theme.of(context).colorScheme;

    return FutureBuilder<WorkoutDetail?>(
      future: _detail,
      builder: (context, snap) {
        if (snap.hasError) {
          // A raw DatabaseException string is not user-facing copy; log it and
          // show a fixed subtitle, as progress.dart does (audit F7).
          debugPrint('SummaryScreen(${widget.workoutId}): ${snap.error}');
          return Scaffold(
            appBar: AppBar(title: const Text('Workout summary')),
            body: const Center(
              child: EmptyState(
                title: 'Could not load this workout',
                subtitle: 'Something went wrong reading this workout. '
                    'Pull back and try again.',
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
                        value: trimZero(fromKg(volume.totalKg, store.unit)))),
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
              _prSection(store),
              const SectionHeader('Exercises'),
              ...detail.exercises.map((view) => _exerciseCard(store, view)),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
                icon: Icon(Icons.delete_outline, color: scheme.error),
                label: Text('Delete workout',
                    style: TextStyle(color: scheme.error)),
                onPressed: () async {
                  await store.deleteWorkout(widget.workoutId);
                  if (context.mounted) Navigator.of(context).pop();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  /// The session's personal records, or nothing at all when there are none.
  ///
  /// Each row names the exercise, the previous best and the new best in the
  /// unit the user selected in Settings, plus the delta. A first-ever baseline
  /// reads "First PR" rather than "previous best 0".
  Widget _prSection(AppStore store) {
    return FutureBuilder<List<PrSummary>>(
      future: _prs,
      builder: (context, snap) {
        final scheme = Theme.of(context).colorScheme;
        final t = Theme.of(context).textTheme;
        if (snap.hasError) {
          // A failed PR query must not look like "this session had no PRs":
          // log the raw error and show a quiet inline row instead.
          debugPrint('SummaryScreen(${widget.workoutId}): PR summary failed: '
              '${snap.error}');
          return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionHeader('Personal records'),
                const SizedBox(height: 8),
                Text('Could not load personal records for this session.',
                    style: t.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 16),
              ]);
        }
        final prs = snap.data ?? const <PrSummary>[];
        if (prs.isEmpty) return const SizedBox.shrink();
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SectionHeader('Personal records'),
          const SizedBox(height: 8),
          for (final pr in prs)
            Card(
              color: scheme.tertiaryContainer,
              child: ListTile(
                leading: Icon(Icons.emoji_events,
                    color: scheme.onTertiaryContainer),
                title: Text(pr.exerciseName,
                    style: t.titleMedium
                        ?.copyWith(color: scheme.onTertiaryContainer)),
                subtitle: Text(_prDetail(pr, store.unit),
                    style: t.bodySmall
                        ?.copyWith(color: scheme.onTertiaryContainer)),
              ),
            ),
          const SizedBox(height: 16),
        ]);
      },
    );
  }

  String _prDetail(PrSummary pr, WeightUnit unit) {
    final newBest = '${trimZero(fromKg(pr.newBestKg, unit))} ${unit.label}';
    if (pr.isBaseline) return 'First PR · $newBest';
    final previous =
        '${trimZero(fromKg(pr.previousBestKg, unit))} ${unit.label}';
    final deltaKg = fromKg(pr.deltaKg, unit);
    final delta =
        '${deltaKg >= 0 ? '+' : ''}${trimZero(deltaKg)} ${unit.label}';
    return 'Previous best $previous → new best $newBest ($delta)';
  }

  /// One exercise card: the same aggregate row the summary has always shown,
  /// plus a chevron that reveals the individual sets on demand.
  Widget _exerciseCard(AppStore store, ExerciseView view) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final v = volumeOf(view.sets
        .where((s) => s.completedAt != null)
        .map((s) => (weightKg: s.weightKg, reps: s.reps, isWarmup: s.isWarmup))
        .toList());
    final expanded = _expanded.contains(view.entry.id);
    final sets = [...view.sets]
      ..sort((a, b) => a.position.compareTo(b.position));

    return Card(
      color: scheme.surfaceContainerLow,
      child: Column(children: [
        ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          leading: const TintedIconCircle(Icons.fitness_center),
          title: Text(view.exercise.name, style: t.titleMedium),
          subtitle: Text(
              '${view.exercise.muscleGroup} · ${v.sets} sets · ${v.reps} reps',
              style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            // Bounded so a large volume cannot squeeze the exercise name on a
            // narrow screen (review nutrition NIT-2).
            Flexible(
              child: Text(
                  '${trimZero(fromKg(v.totalKg, store.unit))} ${store.unit.label}',
                  style: t.labelLarge?.copyWith(color: scheme.primary),
                  textAlign: TextAlign.end,
                  overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 4),
            Semantics(
              container: true,
              button: true,
              toggled: expanded,
              label: '${expanded ? 'Collapse' : 'Expand'} sets for '
                  '${view.exercise.name}',
              onTap: () => _toggle(view.entry.id),
              child: ExcludeSemantics(
                child: IconButton(
                  icon: Icon(
                      expanded ? Icons.expand_less : Icons.expand_more,
                      color: scheme.primary),
                  tooltip: expanded ? 'Collapse sets' : 'Expand sets',
                  onPressed: () => _toggle(view.entry.id),
                ),
              ),
            ),
          ]),
        ),
        if (expanded) ...[
          Divider(height: 1, color: scheme.outlineVariant),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final set in sets) _setRow(store, set),
              ],
            ),
          ),
        ],
      ]),
    );
  }

  /// A read-only set line. Incomplete sets are still listed — a set the user
  /// logged but never ticked off is real data — but they are labelled
  /// "Not completed" and dimmed so they are never read as performed work.
  Widget _setRow(AppStore store, WorkoutSet set) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final done = set.completedAt != null;
    final weight = trimZero(fromKg(set.weightKg, store.unit));
    final detail = '$weight ${store.unit.label} × ${set.reps} reps';
    final status = done ? 'Completed' : 'Not completed';
    final prLabel = set.isPr
        ? ', personal record'
            '${set.prE1rmKg == null ? '' : ' at ${trimZero(fromKg(set.prE1rmKg!, store.unit))} ${store.unit.label} estimated 1RM'}'
        : '';

    return Semantics(
      container: true,
      label: 'Set ${set.position + 1}, $detail'
          '${set.isWarmup ? ', warm-up' : ''}$prLabel, ${status.toLowerCase()}',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            SizedBox(
              width: 28,
              child: Text('${set.position + 1}',
                  style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
            ),
            Expanded(
              child: Text(detail,
                  style: t.bodyMedium?.copyWith(
                      color: done ? scheme.onSurface : scheme.onSurfaceVariant)),
            ),
            if (set.isPr) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text('PR',
                    style: t.labelSmall
                        ?.copyWith(color: scheme.onTertiaryContainer)),
              ),
            ],
            if (set.isWarmup) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text('Warm-up',
                    style: t.labelSmall
                        ?.copyWith(color: scheme.onSecondaryContainer)),
              ),
            ],
            const SizedBox(width: 8),
            Text(status,
                style: t.labelSmall?.copyWith(
                    color: done ? scheme.primary : scheme.outline)),
          ]),
        ),
      ),
    );
  }
}
