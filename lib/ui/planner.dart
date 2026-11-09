import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/store.dart';
import '../domain/plan.dart';
import 'widgets.dart';

/// Chronological day planner: a timed to-do list for one local day, with day
/// navigation, add/edit/delete, a done toggle and a "now" marker on today.
///
/// Planning the day is one of the app's five pillars, so this screen is the
/// place the Home checklist's "Day plan" row and the "Plan your day" card lead
/// to. Blocks are stored by local day key and minute offsets (see
/// [PlanBlock]), never by epoch timestamp, so a block cannot drift across a
/// timezone or DST boundary.
class PlannerScreen extends StatefulWidget {
  const PlannerScreen({super.key, this.now, this.initialDay, this.loadBlocks});

  /// Injectable clock for tests. Defaults to [DateTime.now].
  final DateTime Function()? now;

  /// The day to open on. Defaults to today.
  final DateTime? initialDay;

  /// Injectable day query, mirroring [now]. Defaults to
  /// [AppStore.planBlocksForDay]; tests use it to control query latency so a
  /// stale result can be made to land after a newer one.
  final Future<List<PlanBlock>> Function(DateTime day)? loadBlocks;

  @override
  State<PlannerScreen> createState() => _PlannerScreenState();
}

class _PlannerScreenState extends State<PlannerScreen>
    with WidgetsBindingObserver {
  AppStore? _store;
  late DateTime _day;
  List<PlanBlock> _blocks = const [];
  bool _loaded = false;

  /// Invalidates in-flight day queries. Two rapid day shifts (or a slow DB) can
  /// otherwise let the earlier query land last and paint the wrong day's blocks
  /// under the selected date header. Same guard as `HomeTab._reload`.
  int _generation = 0;

  /// Keeps the "now" marker honest on a screen left open. Cancelled in
  /// [dispose], so it cannot outlive the route.
  Timer? _clock;

  /// Whether the selected day was showing "now" at the last tick. A screen
  /// left open across midnight must rebuild once when this flips, otherwise
  /// yesterday's plan keeps a stale "Now 23:59" marker after the day rolls
  /// over. Initialised from the opening day so the first tick after midnight
  /// still detects the transition.
  bool _showedToday = false;

  DateTime _now() => widget.now?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    final now = _now();
    final initial = widget.initialDay ?? now;
    _day = DateTime(initial.year, initial.month, initial.day);
    _showedToday = planDayKey(_day) == planDayKey(now);
    WidgetsBinding.instance.addObserver(this);
    _clock = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!mounted) return;
      final showingToday = planDayKey(_day) == planDayKey(_now());
      if (showingToday != _showedToday) {
        // The day rolled over (or the user moved between today and another
        // day): rebuild once so the marker appears or clears.
        _showedToday = showingToday;
        setState(() {});
        return;
      }
      // Within the same day, only a day showing "now" needs the minute tick;
      // a past or future day's marker never moves.
      if (!showingToday) return;
      setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final store = context.read<AppStore>();
    if (!identical(store, _store)) {
      _store = store;
      _load();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clock?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A phone locked overnight resumes on a new day; re-read the plan so the
    // "now" marker and the day label are not stale.
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final store = _store;
    if (store == null) return;
    final generation = ++_generation;
    final day = _day;
    final load = widget.loadBlocks;
    try {
      final blocks =
          load != null ? await load(day) : await store.planBlocksForDay(day);
      if (!mounted || generation != _generation) return;
      setState(() {
        _blocks = blocks;
        _loaded = true;
      });
    } catch (_) {
      // A closed database (test teardown) or a transient query failure must not
      // take the screen down: the last known plan stays on screen.
      if (!mounted || generation != _generation) return;
      setState(() => _loaded = true);
    }
  }

  void _setDay(DateTime day) {
    setState(() {
      _day = DateTime(day.year, day.month, day.day);
      _blocks = const [];
      _loaded = false;
    });
    _load();
  }

  /// Calendar arithmetic, never `Duration(days: 1)`: a 24-hour step lands on
  /// 23:00 or 01:00 across a DST boundary and would skip or repeat a day.
  void _shiftDay(int delta) =>
      _setDay(DateTime(_day.year, _day.month, _day.day + delta));

  Future<void> _pickDay() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) _setDay(picked);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final now = _now();
    final isToday = planDayKey(_day) == planDayKey(now);
    final nowMinute = now.hour * 60 + now.minute;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Day planner'),
        actions: [
          IconButton(
            key: const ValueKey('plan-today'),
            icon: const Icon(Icons.today),
            tooltip: 'Go to today',
            onPressed: () => _setDay(_now()),
          ),
          IconButton(
            key: const ValueKey('plan-pick-day'),
            icon: const Icon(Icons.calendar_month),
            tooltip: 'Pick a day',
            onPressed: _pickDay,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('plan-add'),
        onPressed: () => _editBlock(context, null),
        icon: const Icon(Icons.add),
        label: const Text('Add block'),
        tooltip: 'Add block',
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
        children: [
          Row(children: [
            IconButton(
              key: const ValueKey('plan-prev'),
              icon: const Icon(Icons.chevron_left),
              tooltip: 'Previous day',
              onPressed: () => _shiftDay(-1),
            ),
            Expanded(
              child: Text(
                formatDate(_day.millisecondsSinceEpoch),
                style: t.titleMedium,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              key: const ValueKey('plan-next'),
              icon: const Icon(Icons.chevron_right),
              tooltip: 'Next day',
              onPressed: () => _shiftDay(1),
            ),
          ]),
          const SizedBox(height: 8),
          if (_loaded && _blocks.isEmpty)
            const EmptyState(
              icon: Icons.event_note,
              title: 'Nothing planned for this day',
              subtitle: 'Add a block to plan your day.',
            )
          else
            ..._timeline(context, isToday: isToday, nowMinute: nowMinute),
          if (_blocks.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              '${_blocks.where((b) => b.done).length} of ${_blocks.length} '
              'blocks done',
              style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }

  /// The day's blocks in chronological order, with a "now" marker inserted at
  /// the current minute when the screen is showing today.
  List<Widget> _timeline(BuildContext context,
      {required bool isToday, required int nowMinute}) {
    final ordered = chronological(_blocks);
    final widgets = <Widget>[];
    var markerPlaced = false;
    for (final block in ordered) {
      if (isToday && !markerPlaced && block.endMin > nowMinute) {
        widgets.add(_nowMarker(context, nowMinute));
        markerPlaced = true;
      }
      widgets.add(_blockTile(context, block,
          current: isToday &&
              nowMinute >= block.startMin &&
              nowMinute < block.endMin));
    }
    if (isToday && !markerPlaced) {
      widgets.add(_nowMarker(context, nowMinute));
    }
    return widgets;
  }

  Widget _nowMarker(BuildContext context, int nowMinute) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Semantics(
        label: 'Current time ${formatPlanTime(nowMinute)}',
        child: Row(children: [
          Expanded(child: Divider(color: scheme.primary, height: 1)),
          Flexible(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                'Now ${formatPlanTime(nowMinute)}',
                style: t.labelSmall?.copyWith(color: scheme.primary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          Expanded(child: Divider(color: scheme.primary, height: 1)),
        ]),
      ),
    );
  }

  Widget _blockTile(BuildContext context, PlanBlock block,
      {required bool current}) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final timeLabel = '${formatPlanTime(block.startMin)}–'
        '${formatPlanTime(block.endMin)} · '
        '${formatPlanDuration(block.durationMinutes)}';
    return Card(
      color: current ? scheme.primaryContainer : scheme.surfaceContainerLow,
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        onTap: () => _editBlock(context, block),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            MergeSemantics(
              child: Semantics(
                // Name the control, not the action: the checkbox already
                // reports its checked state, so "Mark X done, checked" would
                // announce the action and the state twice.
                label: block.title,
                child: Checkbox(
                  key: ValueKey('plan-done-${block.id}'),
                  value: block.done,
                  onChanged: (value) => _runWrite(context,
                      () => _store!.setPlanBlockDone(block.id, value ?? false)),
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    block.title,
                    style: t.titleMedium?.copyWith(
                      decoration:
                          block.done ? TextDecoration.lineThrough : null,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    current ? 'Now · $timeLabel' : timeLabel,
                    style: t.bodySmall?.copyWith(
                        color: current
                            ? scheme.onPrimaryContainer
                            : scheme.onSurfaceVariant),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              key: ValueKey('plan-menu-${block.id}'),
              tooltip: 'Block actions',
              onSelected: (value) async {
                switch (value) {
                  case 'edit':
                    await _editBlock(context, block);
                  case 'delete':
                    await _deleteBlock(context, block);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('Edit')),
                PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
          ]),
        ),
      ),
    );
  }

  /// Runs a store write and reports a failure to the user instead of dropping
  /// the future, matching the habit screen's contract.
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
    if (!mounted) return;
    await _load();
    if (message != null && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _deleteBlock(BuildContext context, PlanBlock block) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${block.title}"?'),
        content: const Text('This block will be removed from the day.'),
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
    if (confirmed != true || !context.mounted) return;
    await _runWrite(context, () => _store!.deletePlanBlock(block.id));
  }

  /// Add ([block] null) or edit a block. Validation lives in the dialog so it
  /// can show the error inline; the store re-validates as the single write
  /// boundary.
  Future<void> _editBlock(BuildContext context, PlanBlock? block) async {
    final store = _store;
    if (store == null) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _BlockEditorDialog(block: block, day: _day, store: store),
    );
    if (mounted) await _load();
  }
}

/// Add/edit dialog. A StatefulWidget owns the [TextEditingController] so it is
/// disposed with the route, not while the dialog is still animating out (which
/// threw "A TextEditingController was used after being disposed").
class _BlockEditorDialog extends StatefulWidget {
  final PlanBlock? block;
  final DateTime day;
  final AppStore store;

  const _BlockEditorDialog({
    required this.block,
    required this.day,
    required this.store,
  });

  @override
  State<_BlockEditorDialog> createState() => _BlockEditorDialogState();
}

class _BlockEditorDialogState extends State<_BlockEditorDialog> {
  late final TextEditingController _title;
  late int _start;
  late int _end;
  String? _error;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.block?.title ?? '');
    _start = widget.block?.startMin ?? 9 * 60;
    _end = widget.block?.endMin ?? 10 * 60;
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _pick(bool isStart) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
          hour: (isStart ? _start : _end) ~/ 60,
          minute: (isStart ? _start : _end) % 60),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (isStart) {
        _start = picked.hour * 60 + picked.minute;
      } else {
        _end = picked.hour * 60 + picked.minute;
      }
    });
  }

  Future<void> _save() async {
    final message =
        planBlockError(title: _title.text, startMin: _start, endMin: _end);
    if (message != null) {
      setState(() => _error = message);
      return;
    }
    try {
      final block = widget.block;
      if (block == null) {
        await widget.store.createPlanBlock(
            day: widget.day,
            title: _title.text,
            startMin: _start,
            endMin: _end);
      } else {
        await widget.store.updatePlanBlock(block.id,
            title: _title.text, startMin: _start, endMin: _end);
      }
      if (mounted) Navigator.pop(context);
    } on StoreException catch (e) {
      // The dialog can be dismissed while the write is in flight; setState on
      // a disposed State throws.
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      // A closed or failed database throws something that is not a
      // StoreException; report it instead of leaving the dialog open silently.
      if (mounted) setState(() => _error = 'Could not save that block.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.block == null ? 'New block' : 'Edit block'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            key: const ValueKey('plan-title'),
            controller: _title,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Title'),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            key: const ValueKey('plan-start'),
            onPressed: () => _pick(true),
            child: Text('Start ${formatPlanTime(_start)}'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            key: const ValueKey('plan-end'),
            onPressed: () => _pick(false),
            child: Text('End ${formatPlanTime(_end)}'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('plan-save'),
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
