import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../data/store.dart';
import '../domain/habits.dart';
import 'widgets.dart';

/// Habit tracker: today's checklist grouped by cadence, with per-habit progress
/// against the current period target, a streak, and full CRUD.
///
/// No reminders or scheduling engine: the user checks off the days they
/// actually did the habit, and the screen reports progress for the period that
/// contains today.
class HabitsScreen extends StatefulWidget {
  const HabitsScreen({super.key, this.now});

  /// Injectable clock, so the regression test can resume on a new day without
  /// waiting for real midnight. Defaults to [DateTime.now].
  final DateTime Function()? now;

  @override
  State<HabitsScreen> createState() => _HabitsScreenState();
}

class _HabitsScreenState extends State<HabitsScreen>
    with WidgetsBindingObserver {
  /// The day the checklist is showing. Held in state rather than read in
  /// [build]: an app left open across midnight would otherwise keep yesterday's
  /// checklist until some unrelated rebuild happened.
  DateTime _today = DateTime.now();

  DateTime _now() => widget.now?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    _today = _now();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A phone locked overnight resumes on a new day; follow the calendar so the
    // checkboxes and the progress line are not stale.
    if (state == AppLifecycleState.resumed) _refreshToday();
  }

  void _refreshToday() {
    final now = _now();
    if (habitDayKey(now) == habitDayKey(_today)) return;
    setState(() => _today = now);
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final today = _today;
    final active = store.habits.where((h) => !h.archived).toList();
    final archived = store.habits.where((h) => h.archived).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Habits'),
        actions: [
          IconButton(
            key: const ValueKey('habits-add'),
            icon: const Icon(Icons.add),
            tooltip: 'Add habit',
            onPressed: () => _editHabit(context, store, null),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (active.isEmpty && archived.isEmpty)
            const EmptyState(
              icon: Icons.checklist_rtl,
              title: 'No habits yet',
              subtitle:
                  'Add a habit and check off the days you do it. Progress and streaks build from there.',
            ),
          for (final cadence in HabitCadence.values)
            ..._section(
              context,
              store,
              active
                  .where((h) => HabitCadence.parse(h.cadence) == cadence)
                  .toList(),
              cadence,
              today,
            ),
          if (archived.isNotEmpty) ...[
            const SizedBox(height: 16),
            const SectionHeader('Archived'),
            for (final habit in archived) _archivedTile(context, store, habit),
          ],
        ],
      ),
    );
  }

  List<Widget> _section(BuildContext context, AppStore store,
      List<Habit> habits, HabitCadence cadence, DateTime today) {
    if (habits.isEmpty) return const [];
    return [
      const SizedBox(height: 8),
      SectionHeader(switch (cadence) {
        HabitCadence.daily => 'Daily',
        HabitCadence.weekly => 'Weekly',
        HabitCadence.monthly => 'Monthly',
      }),
      for (final habit in habits) _habitTile(context, store, habit, today),
    ];
  }

  Widget _habitTile(
      BuildContext context, AppStore store, Habit habit, DateTime today) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final cadence = HabitCadence.parse(habit.cadence) ?? HabitCadence.daily;
    final completions =
        store.habitCompletions.where((c) => c.habitId == habit.id).toList();
    final progress = habitProgress(habit, completions, today: today);
    final doneToday =
        completions.any((c) => c.day == habitDayKey(today) && c.count > 0);

    return Card(
      color: scheme.surfaceContainerLow,
      child: ListTile(
        leading: Checkbox(
          key: ValueKey('habit-check-${habit.id}'),
          value: doneToday,
          onChanged: (_) => _runWrite(
              context, () => store.toggleHabitCompletion(habit.id, today)),
        ),
        title: Text(habit.name),
        subtitle: Text(
          '${progress.completedDays}/${habit.target} ${cadence.periodWord}'
          ' · streak ${progress.streak}',
          style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        onTap: () => _runWrite(
            context, () => store.toggleHabitCompletion(habit.id, today)),
        trailing: PopupMenuButton<String>(
          key: ValueKey('habit-menu-${habit.id}'),
          tooltip: 'Habit actions',
          onSelected: (value) async {
            switch (value) {
              case 'edit':
                await _editHabit(context, store, habit);
              case 'archive':
                await _runWrite(
                    context, () => store.updateHabit(habit.id, archived: true));
              case 'delete':
                await _deleteHabit(context, store, habit);
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'edit', child: Text('Edit')),
            PopupMenuItem(value: 'archive', child: Text('Archive')),
            PopupMenuItem(value: 'delete', child: Text('Delete')),
          ],
        ),
      ),
    );
  }

  Widget _archivedTile(BuildContext context, AppStore store, Habit habit) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.surfaceContainerLow,
      child: ListTile(
        title: Text(habit.name),
        subtitle: Text('Archived · ${habit.target}× '
            '${(HabitCadence.parse(habit.cadence) ?? HabitCadence.daily).periodWord}'),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(
            key: ValueKey('habit-restore-${habit.id}'),
            icon: const Icon(Icons.unarchive_outlined),
            tooltip: 'Restore habit',
            onPressed: () => _runWrite(
                context, () => store.updateHabit(habit.id, archived: false)),
          ),
          IconButton(
            key: ValueKey('habit-delete-${habit.id}'),
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Delete habit',
            onPressed: () => _deleteHabit(context, store, habit),
          ),
        ]),
      ),
    );
  }
}

/// Runs a store write from a UI callback and reports a failure to the user.
///
/// The callbacks used to fire the write and drop the future, so a
/// [StoreException] vanished without a trace (review habit MINOR-3).
Future<void> _runWrite(
    BuildContext context, Future<void> Function() write) async {
  String? message;
  try {
    await write();
  } on StoreException catch (e) {
    message = e.message;
  } catch (_) {
    message = 'Could not save that change.';
  }
  if (message == null || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

/// Add ([habit] null) or edit a habit. Validation lives here so the dialog can
/// show the error inline; the store re-validates as the single write boundary.
Future<void> _editHabit(
    BuildContext context, AppStore store, Habit? habit) async {
  final name = TextEditingController(text: habit?.name ?? '');
  final target = TextEditingController(text: '${habit?.target ?? 1}');
  var cadence = HabitCadence.parse(habit?.cadence) ?? HabitCadence.daily;
  String? error;

  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: Text(habit == null ? 'New habit' : 'Edit habit'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              key: const ValueKey('habit-name'),
              controller: name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Habit name'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<HabitCadence>(
              key: const ValueKey('habit-cadence'),
              initialValue: cadence,
              decoration: const InputDecoration(labelText: 'Cadence'),
              items: const [
                DropdownMenuItem(
                    value: HabitCadence.daily, child: Text('Daily')),
                DropdownMenuItem(
                    value: HabitCadence.weekly, child: Text('Weekly')),
                DropdownMenuItem(
                    value: HabitCadence.monthly, child: Text('Monthly')),
              ],
              onChanged: (v) => setDialogState(() => cadence = v ?? cadence),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('habit-target'),
              controller: target,
              keyboardType: TextInputType.number,
              decoration:
                  const InputDecoration(labelText: 'Target days per period'),
            ),
            if (error != null) ...[
              const SizedBox(height: 12),
              Text(error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final days = int.tryParse(target.text.trim());
              if (name.text.trim().isEmpty) {
                setDialogState(() => error = 'Enter a habit name.');
                return;
              }
              if (days == null || days < 1) {
                setDialogState(() =>
                    error = 'Target must be a whole number of at least 1.');
                return;
              }
              try {
                if (habit == null) {
                  await store.createHabit(name.text, cadence.name, days);
                } else {
                  await store.updateHabit(habit.id,
                      name: name.text, cadence: cadence.name, target: days);
                }
                if (context.mounted) Navigator.pop(context);
              } on StoreException catch (e) {
                // The dialog can be dismissed while the write is in flight;
                // setDialogState on a disposed State throws.
                if (context.mounted) setDialogState(() => error = e.message);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
  name.dispose();
  target.dispose();
}

Future<void> _deleteHabit(
    BuildContext context, AppStore store, Habit habit) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Delete "${habit.name}"?'),
      content: const Text(
          'Its completion history will be deleted too. Archive it instead to keep the history.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete')),
      ],
    ),
  );
  if (confirmed == true && context.mounted) {
    await _runWrite(context, () => store.deleteHabit(habit.id));
  }
}
