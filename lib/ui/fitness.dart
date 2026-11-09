import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../data/store.dart';
import '../domain/domain.dart';
import 'drawer.dart';
import 'history.dart';
import 'picker.dart';
import 'progress.dart';
import 'summary.dart';
import 'widgets.dart';
import 'workout.dart';

/// The fitness hub: start or resume a workout and jump into the existing
/// training screens.
///
/// It owns no training logic of its own — every action opens the screen that
/// already implements it ([WorkoutScreen], [HistoryScreen], [ProgressScreen],
/// [ExercisePickerScreen]) — but it does track the in-progress workout so the
/// resume affordance is accurate.
class FitnessTab extends StatefulWidget {
  const FitnessTab({super.key});

  @override
  State<FitnessTab> createState() => _FitnessTabState();
}

class _FitnessTabState extends State<FitnessTab> {
  AppStore? _store;
  Workout? _active;

  /// Whether this tab is the one the shell is showing. The shell keeps every
  /// tab mounted in an [IndexedStack], so without this flag a mutation on any
  /// other tab would still run this tab's queries.
  bool _visible = true;

  /// Coalesces a burst of store notifications into one reload.
  Timer? _debounce;

  /// Incremented for every reload; a result whose generation is stale is
  /// dropped, so two overlapping queries cannot land out of order.
  int _generation = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final store = context.read<AppStore>();
    final visible = ShellNav.of(context).visible;
    final becameVisible = visible && !_visible;
    _visible = visible;
    if (!identical(store, _store)) {
      _store?.removeListener(_scheduleReload);
      _store = store;
      store.addListener(_scheduleReload);
      // An off-screen tab must not query on first bind; it catches up in the
      // `becameVisible` branch below.
      if (_visible) _reload();
    } else if (becameVisible) {
      // The tab was off-screen while the store changed; catch up now that it
      // is visible again.
      _reload();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _store?.removeListener(_scheduleReload);
    super.dispose();
  }

  /// Debounced store listener: logging a set notifies the store several times,
  /// and each notification must not cost a query.
  void _scheduleReload() {
    if (!_visible) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), () {
      // The tab may have gone off-screen during the debounce window.
      if (_visible) _reload();
    });
  }

  Future<void> _reload() async {
    final store = _store;
    if (store == null) return;
    final generation = ++_generation;
    try {
      final active = await store.activeWorkout();
      if (!mounted || generation != _generation) return;
      setState(() => _active = active);
    } catch (_) {
      // A closed database (test teardown) or a transient query failure must
      // not take the hub down: the last known state stays on screen.
    }
  }

  Future<void> _startWorkout() async {
    final store = context.read<AppStore>();
    final name = await askWorkoutName(context);
    if (name == null || !mounted) return;
    final id = await store.createWorkout(name);
    if (!mounted) return;
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => WorkoutScreen(workoutId: id)));
    // The workout may have been finished while the screen was open.
    if (mounted) _reload();
  }

  Future<void> _openWorkout(int id) async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => WorkoutScreen(workoutId: id)));
    if (mounted) _reload();
  }

  void _push(Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final active = _active;
    final recent = store.history.take(5).toList();

    return Scaffold(
      appBar: AppBar(
        leading: const DrawerMenuButton(),
        title: Row(children: [
          TintedIconCircle(Icons.fitness_center,
              background: scheme.primary, foreground: scheme.onPrimary),
          const SizedBox(width: 10),
          // The AppBar title is bounded by the screen width; at accessibility
          // text scales an unconstrained Text overflows the Row.
          Expanded(
            child: Text(
              'Fitness',
              style: t.titleLarge,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ]),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (active != null) ...[
            Card(
              color: scheme.primaryContainer,
              child: ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                onTap: () => _openWorkout(active.id),
                leading: Icon(Icons.play_circle_fill,
                    color: scheme.onPrimaryContainer),
                title: Text(active.name,
                    style: t.titleMedium
                        ?.copyWith(color: scheme.onPrimaryContainer)),
                subtitle: Text(
                  'In progress since ${formatDateTime(active.startedAt)} · tap to resume',
                  style: TextStyle(color: scheme.onPrimaryContainer),
                ),
                trailing:
                    Icon(Icons.play_arrow, color: scheme.onPrimaryContainer),
              ),
            ),
            const SizedBox(height: 16),
          ],
          FilledButton.icon(
            onPressed: _startWorkout,
            icon: const Icon(Icons.play_arrow),
            label: Text(active == null ? 'Start workout' : 'Start another'),
          ),
          const SizedBox(height: 20),
          const SectionHeader('Train'),
          const SizedBox(height: 8),
          Card(
            color: scheme.surfaceContainerLow,
            child: Column(children: [
              ListTile(
                leading: const TintedIconCircle(Icons.history),
                title: const Text('History'),
                subtitle: const Text('Finished sessions'),
                trailing:
                    Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
                onTap: () => _push(const HistoryScreen()),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const TintedIconCircle(Icons.show_chart),
                title: const Text('Progress'),
                subtitle: const Text('Strength over time'),
                trailing:
                    Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
                onTap: () => _push(const ProgressScreen()),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const TintedIconCircle(Icons.list_alt),
                title: const Text('Exercises'),
                subtitle: const Text('Library and custom exercises'),
                trailing:
                    Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
                onTap: () =>
                    _push(const ExercisePickerScreen(title: 'Exercises')),
              ),
            ]),
          ),
          const SizedBox(height: 20),
          const SectionHeader('Recent sessions'),
          const SizedBox(height: 8),
          if (recent.isEmpty)
            const EmptyState(
              title: 'No sessions yet',
              subtitle: 'Start a workout and it will show up here.',
              icon: Icons.fitness_center,
            )
          else
            for (final row in recent)
              CardRow(
                icon: Icons.fitness_center,
                title: row.name,
                subtitle:
                    '${formatDate(row.startedAt)} · ${row.exerciseCount} exercises · ${row.setCount} sets',
                trailing:
                    '${trimZero(fromKg(row.totalKg, store.unit))} ${store.unit.label}',
                onTap: () => _push(SummaryScreen(row.workoutId)),
              ),
        ],
      ),
    );
  }
}
