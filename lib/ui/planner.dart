import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/store.dart';
import '../domain/plan.dart';
import 'widgets.dart';

/// Vertical pixels per hour on the day grid. 96dp keeps a 15-minute slot at
/// 24dp, so a 30-minute block is a 48dp card — the minimum touch target.
const double _hourHeight = 96;

/// Every gesture on the grid snaps to this many minutes.
const int _snapMinutes = 15;

/// A block created by tapping an empty slot starts at this length; the owner
/// resizes it afterwards by dragging the bottom edge.
const int _defaultDuration = 30;

/// Shortest block the resize handle can produce.
const int _minDuration = 15;

/// Smallest rendered card height, so a 15-minute block is still tappable.
const double _minCardHeight = 48;

/// Smallest resize-strip hit area. A card that cannot afford a full 48dp strip
/// without eating the body it has to show gets this instead.
const double _minHandleHit = 16;

/// Gap kept between the card body's text and the resize strip.
const double _minBodySlack = 2;

/// Padding around the card body's text.
const EdgeInsets _cardBodyPadding = EdgeInsets.fromLTRB(4, 2, 8, 2);

/// Chronological day planner as a direct-manipulation timeline: tap an empty
/// slot to type a one-liner, drag a block's bottom edge to resize it, drag its
/// body to move it, tap it to rename, long-press to delete with undo.
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

  /// Scrolls the grid to the current time once per day, so opening the planner
  /// lands on the part of the day the owner is actually in.
  final ScrollController _scroll = ScrollController();
  bool _scrolledToNow = false;

  /// Inline editor state. [_creatingStart] is the snapped minute of a pending
  /// new block; [_editingId] is the block being renamed. At most one is set.
  int? _creatingStart;
  int? _editingId;
  final TextEditingController _inline = TextEditingController();
  final FocusNode _inlineFocus = FocusNode();

  /// Live drag state: the block being dragged, whether the drag is a resize,
  /// and the candidate times. Kept in state so the card follows the finger and
  /// shows a duration readout before the write lands.
  int? _dragId;
  bool _resizing = false;
  int _dragStart = 0;
  int _dragEnd = 0;
  int _dragBaseStart = 0;
  int _dragBaseEnd = 0;

  /// Cumulative vertical drag distance in minutes since the gesture started.
  /// The gesture reports per-event deltas, so they must be summed before the
  /// snap is applied; snapping each event separately would lose sub-snap
  /// movement and make a slow drag never move the block.
  double _dragDelta = 0;

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
    _scroll.dispose();
    _inline.dispose();
    _inlineFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A phone locked overnight resumes on a new day; re-read the plan so the
    // "now" marker and the day label are not stale.
    if (state == AppLifecycleState.resumed) _load();
  }

  /// Last keyboard inset seen, so a rotation or a non-keyboard inset change
  /// does not yank the grid out from under the owner's scroll.
  double _lastInsetBottom = 0;

  @override
  void didChangeMetrics() {
    // The keyboard opening shrinks the grid's viewport. An inline editor opened
    // near the bottom of the day would otherwise end up behind the keyboard,
    // so re-reveal it when the keyboard inset actually grows.
    final inset = View.of(context).viewInsets.bottom;
    final grew = inset > _lastInsetBottom;
    _lastInsetBottom = inset;
    if (!grew) return;
    final start = _creatingStart ??
        (_editingId == null ? null : _blockById(_editingId!)?.startMin);
    if (start != null) _revealEditor(start);
  }

  /// Scrolls the grid so an inline editor at [startMin] sits in the upper part
  /// of the visible viewport, clear of the keyboard.
  void _revealEditor(int startMin) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final viewport = _scroll.position.viewportDimension;
      final target = _topFor(startMin) - viewport * 0.2;
      _scroll.jumpTo(
          target.clamp(0.0, _scroll.position.maxScrollExtent).toDouble());
    });
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
      _scrollToNow();
    } catch (_) {
      // A closed database (test teardown) or a transient query failure must not
      // take the screen down: the last known plan stays on screen.
      if (!mounted || generation != _generation) return;
      setState(() => _loaded = true);
    }
  }

  /// Jumps the grid to the current time once per selected day. Runs after the
  /// frame that laid the scroll view out, so [ScrollController.position] is
  /// attached; a no-op for a past or future day.
  void _scrollToNow() {
    if (_scrolledToNow) return;
    final now = _now();
    if (planDayKey(_day) != planDayKey(now)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      // Only mark it done once the controller is actually attached; otherwise a
      // load that lands before layout would never retry the scroll.
      _scrolledToNow = true;
      final minute = now.hour * 60 + now.minute;
      final target = minute / 60 * _hourHeight - 160;
      _scroll.jumpTo(
          target.clamp(0.0, _scroll.position.maxScrollExtent).toDouble());
    });
  }

  void _setDay(DateTime day) {
    setState(() {
      _day = DateTime(day.year, day.month, day.day);
      _blocks = const [];
      _loaded = false;
      _scrolledToNow = false;
      _creatingStart = null;
      _editingId = null;
      _dragId = null;
      _inline.clear();
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

  // ------------------------------------------------------------ inline entry

  /// Opens the inline one-liner at [startMin]. Any editor already open is
  /// committed first, so typed text is never silently dropped.
  void _startCreate(int startMin) {
    if (_creatingStart != null) {
      _commitCreate();
    } else if (_editingId != null) {
      final block = _blockById(_editingId!);
      if (block != null) _commitEdit(block);
    }
    final start = _snap(startMin);
    setState(() {
      _creatingStart = start;
      _editingId = null;
      _inline.text = '';
    });
    _revealEditor(start);
  }

  /// Commits the pending new block. The whole create path is tap, type, Enter:
  /// the title comes from the inline field and the duration is the default.
  Future<void> _commitCreate() async {
    final start = _creatingStart;
    if (start == null) return;
    final title = _inline.text.trim();
    final end = _clampInt(start + _defaultDuration, 0, minutesPerDay);
    // Clear the editor synchronously so a second tap on the grid cannot race
    // this commit.
    setState(() => _creatingStart = null);
    _inlineFocus.unfocus();
    if (title.isEmpty) return;
    final error = planBlockError(title: title, startMin: start, endMin: end);
    if (error != null) {
      // Too long: keep the text so the owner can shorten it, and keep the
      // keyboard up so the field is still focused.
      setState(() => _creatingStart = start);
      _inlineFocus.requestFocus();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error)));
      }
      return;
    }
    await _runWrite(
        context,
        () => _store!.createPlanBlock(
            day: _day, title: title, startMin: start, endMin: end));
  }

  /// Opens the inline editor on [block] with its current title. An editor
  /// already open on another block is committed first.
  void _startEdit(PlanBlock block) {
    if (_creatingStart != null) {
      _commitCreate();
    } else if (_editingId != null && _editingId != block.id) {
      final current = _blockById(_editingId!);
      if (current != null) _commitEdit(current);
    }
    setState(() {
      _editingId = block.id;
      _creatingStart = null;
      _inline.text = block.title;
    });
    _revealEditor(block.startMin);
  }

  /// Renames [block] in place. An emptied field reverts to the stored title
  /// rather than deleting the block.
  Future<void> _commitEdit(PlanBlock block) async {
    final title = _inline.text.trim();
    setState(() => _editingId = null);
    _inlineFocus.unfocus();
    if (title.isEmpty || title == block.title) return;
    final error = planBlockError(
        title: title, startMin: block.startMin, endMin: block.endMin);
    if (error != null) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error)));
      }
      return;
    }
    await _runWrite(
        context, () => _store!.updatePlanBlock(block.id, title: title));
  }

  void _cancelInline() {
    setState(() {
      _creatingStart = null;
      _editingId = null;
    });
    _inline.clear();
    _inlineFocus.unfocus();
  }

  // ------------------------------------------------------------------ drags

  void _beginDrag(PlanBlock block, {required bool resize}) {
    // Commit any open inline editor first: starting a drag must not silently
    // drop typed text (the tap paths already commit before switching).
    if (_creatingStart != null) {
      _commitCreate();
    } else if (_editingId != null) {
      final current = _blockById(_editingId!);
      if (current != null) _commitEdit(current);
    }
    setState(() {
      _dragId = block.id;
      _resizing = resize;
      _dragStart = block.startMin;
      _dragEnd = block.endMin;
      _dragBaseStart = block.startMin;
      _dragBaseEnd = block.endMin;
      _dragDelta = 0;
      _creatingStart = null;
      _editingId = null;
    });
  }

  /// Applies a cumulative drag delta (in minutes, from the gesture start) to
  /// the live candidate times, snapped to [_snapMinutes]. A resize moves the
  /// end only; a move shifts the whole block and keeps its duration.
  void _updateDrag(double deltaMinutes) {
    if (_dragId == null) return;
    _dragDelta += deltaMinutes;
    final delta = (_dragDelta / _snapMinutes).round() * _snapMinutes;
    // Always recompute from the base, including when the cumulative delta snaps
    // back to zero: a drag that returns to its origin must restore the original
    // times, not leave the block at the last intermediate position.
    setState(() {
      if (_resizing) {
        _dragEnd = _clampInt(
            _dragBaseEnd + delta, _dragStart + _minDuration, minutesPerDay);
      } else {
        final duration = _dragBaseEnd - _dragBaseStart;
        final start =
            _clampInt(_dragBaseStart + delta, 0, minutesPerDay - duration);
        _dragStart = start;
        _dragEnd = start + duration;
      }
    });
  }

  /// Persists the dragged times. A drag that snapped back to the original
  /// times writes nothing.
  Future<void> _endDrag() async {
    final id = _dragId;
    final start = _dragStart;
    final end = _dragEnd;
    final changed = start != _dragBaseStart || end != _dragBaseEnd;
    setState(() {
      _dragId = null;
      _resizing = false;
    });
    if (id == null || !changed) return;
    await _runWrite(context,
        () => _store!.updatePlanBlock(id, startMin: start, endMin: end));
  }

  // ----------------------------------------------------------------- writes

  /// Runs a store write and reports a failure to the user instead of dropping
  /// the future, matching the habit screen's contract. Returns whether the
  /// write succeeded, so callers do not announce success after a failure.
  Future<bool> _runWrite(
      BuildContext context, Future<void> Function() write) async {
    String? message;
    try {
      await write();
    } on StoreException catch (e) {
      message = e.message;
    } catch (_) {
      message = 'Could not save that change.';
    }
    if (!mounted) return message == null;
    await _load();
    if (message != null && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
    return message == null;
  }

  /// Deletes [block] immediately and offers an undo snackbar instead of a
  /// confirmation dialog: the common path stays one gesture. The day the block
  /// belonged to is captured here, so an undo after a day switch restores it to
  /// the original day rather than the day now on screen.
  Future<void> _deleteBlock(BuildContext context, PlanBlock block) async {
    final messenger = ScaffoldMessenger.of(context);
    final day = _day;
    final ok =
        await _runWrite(context, () => _store!.deletePlanBlock(block.id));
    if (!mounted || !ok) return;
    messenger.showSnackBar(SnackBar(
      content: Text('Deleted "${block.title}"'),
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () => _undoDelete(block, day),
      ),
    ));
  }

  /// Recreates a deleted block on [day] with its original title, times, done
  /// state, position and creation time.
  Future<void> _undoDelete(PlanBlock block, DateTime day) async {
    final store = _store;
    if (store == null) return;
    await _runWrite(context, () async {
      final id = await store.createPlanBlock(
          day: day,
          title: block.title,
          startMin: block.startMin,
          endMin: block.endMin,
          position: block.position,
          createdAt: block.createdAt);
      if (block.done) await store.setPlanBlockDone(id, true);
    });
  }

  PlanBlock? _blockById(int id) {
    for (final block in _blocks) {
      if (block.id == id) return block;
    }
    return null;
  }

  // ---------------------------------------------------------------- helpers

  /// Snaps [minute] down to the nearest [_snapMinutes] boundary inside the day.
  int _snap(int minute) => _clampInt(
      (minute ~/ _snapMinutes) * _snapMinutes, 0, minutesPerDay - _minDuration);

  /// The minute offset for a y position inside the grid.
  int _minuteAt(double dy) => (dy / _hourHeight * 60).floor();

  int _clampInt(int value, int low, int high) =>
      value < low ? low : (value > high ? high : value);

  double _topFor(int minute) => minute / 60 * _hourHeight;

  // ------------------------------------------------------------------ build

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
      body: Column(children: [
        _dayBar(context),
        if (_loaded && _blocks.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              'Nothing planned for this day. Tap a time to add a block.',
              style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        Expanded(
            child: _timeline(context, isToday: isToday, nowMinute: nowMinute)),
        if (_blocks.isNotEmpty) _progress(context),
      ]),
    );
  }

  Widget _dayBar(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Row(children: [
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
    ]);
  }

  Widget _progress(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 10),
      child: Text(
        '${_blocks.where((b) => b.done).length} of ${_blocks.length} '
        'blocks done',
        style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
  }

  /// The full-day grid with the day's blocks positioned on it. The grid is the
  /// bottom layer, so a tap on a block reaches the block and a tap on empty
  /// space reaches the grid.
  Widget _timeline(BuildContext context,
      {required bool isToday, required int nowMinute}) {
    final ordered = chronological(_blocks);
    final editing = _editingId == null ? null : _blockById(_editingId!);
    return SingleChildScrollView(
      controller: _scroll,
      child: SizedBox(
        height: minutesPerDay / 60 * _hourHeight,
        child: Stack(children: [
          // The grid is static between drags; a repaint boundary keeps the
          // per-event drag rebuild from repainting the 73-widget grid.
          RepaintBoundary(child: _grid(context)),
          if (isToday) _nowLine(context, nowMinute),
          for (final block in ordered) _positionedBlock(context, block),
          if (_creatingStart != null)
            _positionedEditor(context,
                start: _creatingStart!,
                end: _clampInt(
                    _creatingStart! + _defaultDuration, 0, minutesPerDay)),
          if (editing != null)
            _positionedEditor(context,
                block: editing, start: editing.startMin, end: editing.endMin),
        ]),
      ),
    );
  }

  /// Hour lines, half-hour ticks and hour labels. Tapping anywhere on it opens
  /// the inline one-liner at the snapped minute under the finger.
  Widget _grid(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return GestureDetector(
      key: const ValueKey('plan-grid'),
      behavior: HitTestBehavior.opaque,
      onTapUp: (details) => _startCreate(_minuteAt(details.localPosition.dy)),
      child: Stack(children: [
        for (var hour = 0; hour <= 24; hour++)
          Positioned(
            // The 24:00 divider sits on the grid's last pixel so it is not
            // clipped by the Stack.
            top: hour == 24 ? _gridHeight - 1 : _topFor(hour * 60),
            left: 0,
            right: 0,
            child: Divider(
              height: 1,
              thickness: 1,
              color: scheme.outlineVariant.withValues(alpha: 0.6),
            ),
          ),
        for (var hour = 0; hour < 24; hour++)
          Positioned(
            top: _topFor(hour * 60 + 30),
            left: 56,
            right: 0,
            child: Divider(
              height: 1,
              thickness: 1,
              color: scheme.outlineVariant.withValues(alpha: 0.25),
            ),
          ),
        for (var hour = 0; hour <= 24; hour++)
          Positioned(
            top: hour == 24 ? _gridHeight - 14 : _topFor(hour * 60) + 2,
            left: 4,
            child: Text(
              formatPlanTime(hour * 60),
              style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
      ]),
    );
  }

  /// The "now" marker, drawn above the grid and below the blocks. Ignored by
  /// hit testing so it never swallows a tap meant for the grid.
  Widget _nowLine(BuildContext context, int nowMinute) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Positioned(
      top: _topFor(nowMinute),
      left: 0,
      right: 0,
      child: IgnorePointer(
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
      ),
    );
  }

  /// Full grid height in logical pixels.
  double get _gridHeight => minutesPerDay / 60 * _hourHeight;

  /// Clamps a card's top so its bottom stays inside the grid. Without this a
  /// block or editor at 23:45 is laid out past the grid's extent and clipped by
  /// the Stack, leaving its resize handle unreachable.
  double _clampTop(double top, double height) =>
      top.clamp(0.0, (_gridHeight - height).clamp(0.0, _gridHeight)).toDouble();

  /// Height of one line of [style] at the current text scale, plus a pixel of
  /// headroom so paragraph rounding cannot push the last line past the body.
  double _lineHeight(BuildContext context, TextStyle? style) {
    final painter = TextPainter(
      text: TextSpan(text: '00:00', style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final height = painter.height.ceilToDouble() + 1;
    painter.dispose();
    return height;
  }

  /// Body content height for the two card layouts at the current text scale:
  /// the one-line compact row and the two-line column.
  ({double compact, double column}) _bodyContentHeights(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final title = _lineHeight(context, t.bodyMedium);
    final label = _lineHeight(context, t.labelSmall);
    final times = _lineHeight(context, t.bodySmall);
    return (
      compact: math.max(title, label) + _cardBodyPadding.vertical,
      column: title + 2 + times + _cardBodyPadding.vertical,
    );
  }

  /// Card height for a [duration]-minute block. A card is never shorter than
  /// its own text: at large text scales a 30-minute block has to grow past its
  /// slot, otherwise the body would have to clip the title or the time label.
  double _cardHeight(BuildContext context, int duration) {
    final content = _bodyContentHeights(context).compact;
    final needed = content + _minHandleHit + _minBodySlack;
    return math.max(_topFor(duration), math.max(_minCardHeight, needed));
  }

  Widget _positionedBlock(BuildContext context, PlanBlock block) {
    final dragging = _dragId == block.id;
    final start = dragging ? _dragStart : block.startMin;
    final end = dragging ? _dragEnd : block.endMin;
    final height = _cardHeight(context, end - start);
    return Positioned(
      top: _clampTop(_topFor(start), height),
      left: 56,
      right: 8,
      height: height,
      child: _blockCard(context, block, height: height, dragging: dragging),
    );
  }

  Widget _positionedEditor(BuildContext context,
      {PlanBlock? block, required int start, required int end}) {
    final height = _topFor(end - start).clamp(64.0, double.infinity).toDouble();
    return Positioned(
      top: _clampTop(_topFor(start), height),
      left: 56,
      right: 8,
      height: height,
      child: _inlineEditor(context, block: block, start: start, end: end),
    );
  }

  /// A block card: done toggle on the left, title and times in the middle, a
  /// resize strip along the bottom edge. The body drags to move, taps to
  /// rename, long-presses to delete.
  Widget _blockCard(BuildContext context, PlanBlock block,
      {required double height, required bool dragging}) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final now = _now();
    final current = planDayKey(_day) == planDayKey(now) &&
        now.hour * 60 + now.minute >= block.startMin &&
        now.hour * 60 + now.minute < block.endMin;
    final start = dragging ? _dragStart : block.startMin;
    final end = dragging ? _dragEnd : block.endMin;
    final duration = end - start;
    final timeLabel = '${formatPlanTime(start)}–${formatPlanTime(end)} · '
        '${formatPlanDuration(duration)}';
    // The body is what the user reads, so the layout is chosen from the body
    // height left after the resize strip — not from the card height, which is
    // what let a 35-53 minute card clip its own time label. The strip keeps
    // 48dp whenever the card can afford it and shrinks to [_minHandleHit]
    // before it would eat the text.
    final content = _bodyContentHeights(context);
    final columnFits = height >= content.column + 2 + 48 + _minBodySlack;
    final compact = !columnFits;
    final bodyContent = columnFits ? content.column : content.compact;
    final handleHit = (height - bodyContent - _minBodySlack)
        .clamp(_minHandleHit, 48.0)
        .toDouble();

    return Semantics(
      label: '${block.title}, ${formatPlanTime(start)} to '
          '${formatPlanTime(end)}, ${formatPlanDuration(duration)}'
          '${block.done ? ', done' : ''}',
      button: true,
      child: Material(
        key: ValueKey('plan-card-${block.id}'),
        color: current ? scheme.primaryContainer : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: Stack(children: [
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 44,
            child: _doneToggle(context, block, current: current),
          ),
          Positioned(
            left: 44,
            top: 0,
            right: 0,
            bottom: handleHit,
            child: GestureDetector(
              key: ValueKey('plan-block-${block.id}'),
              behavior: HitTestBehavior.opaque,
              dragStartBehavior: DragStartBehavior.down,
              onTap: () => _startEdit(block),
              onLongPress: () => _deleteBlock(context, block),
              onVerticalDragStart: (_) => _beginDrag(block, resize: false),
              onVerticalDragUpdate: (details) =>
                  _updateDrag(details.primaryDelta! / _hourHeight * 60),
              onVerticalDragEnd: (_) => _endDrag(),
              child: ClipRect(
                child: OverflowBox(
                  alignment: Alignment.topLeft,
                  maxHeight: double.infinity,
                  child: Padding(
                    padding: _cardBodyPadding,
                    child: compact
                        // A card that cannot host two lines puts the time
                        // beside the title on one line.
                        ? Row(children: [
                            Expanded(
                              flex: 2,
                              child: Text(
                                block.title,
                                style: t.bodyMedium?.copyWith(
                                  decoration: block.done
                                      ? TextDecoration.lineThrough
                                      : null,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              flex: 3,
                              child: Text(
                                dragging
                                    ? formatPlanDuration(duration)
                                    : timeLabel,
                                key: dragging
                                    ? ValueKey('plan-drag-readout-${block.id}')
                                    : null,
                                style: t.labelSmall?.copyWith(
                                    color: current
                                        ? scheme.onPrimaryContainer
                                        : scheme.onSurfaceVariant),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ])
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                block.title,
                                style: t.bodyMedium?.copyWith(
                                  decoration: block.done
                                      ? TextDecoration.lineThrough
                                      : null,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                dragging
                                    ? formatPlanDuration(duration)
                                    : timeLabel,
                                key: dragging
                                    ? ValueKey('plan-drag-readout-${block.id}')
                                    : null,
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
                ),
              ),
            ),
          ),
          Positioned(
            left: 44,
            right: 0,
            bottom: 0,
            height: handleHit,
            child: Semantics(
              label: 'Resize ${block.title}',
              onIncrease: () => _resizeBy(block, _snapMinutes),
              onDecrease: () => _resizeBy(block, -_snapMinutes),
              child: GestureDetector(
                key: ValueKey('plan-resize-${block.id}'),
                behavior: HitTestBehavior.opaque,
                dragStartBehavior: DragStartBehavior.down,
                // The strip is part of the card, so a tap on it renames too
                // instead of being a dead zone.
                onTap: () => _startEdit(block),
                onVerticalDragStart: (_) => _beginDrag(block, resize: true),
                onVerticalDragUpdate: (details) =>
                    _updateDrag(details.primaryDelta! / _hourHeight * 60),
                onVerticalDragEnd: (_) => _endDrag(),
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Container(
                      width: 28,
                      height: 3,
                      decoration: BoxDecoration(
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  /// Screen-reader resize: extends or shrinks [block] by [deltaMinutes],
  /// clamped to the day and the minimum duration.
  Future<void> _resizeBy(PlanBlock block, int deltaMinutes) async {
    final end = _clampInt(block.endMin + deltaMinutes,
        block.startMin + _minDuration, minutesPerDay);
    if (end == block.endMin) return;
    await _runWrite(
        context, () => _store!.updatePlanBlock(block.id, endMin: end));
  }

  /// One-tap done toggle. Spans the card's full height so the target is at
  /// least 48dp tall on a default-length block.
  Widget _doneToggle(BuildContext context, PlanBlock block,
      {required bool current}) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      // Name the control and report its state, so a screen reader announces
      // "Deep work, checked" rather than just the title.
      label: block.title,
      button: true,
      checked: block.done,
      child: InkResponse(
        key: ValueKey('plan-done-${block.id}'),
        radius: 24,
        onTap: () => _runWrite(
            context, () => _store!.setPlanBlockDone(block.id, !block.done)),
        child: Center(
          child: Icon(
            block.done ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 20,
            color: current ? scheme.onPrimaryContainer : scheme.primary,
          ),
        ),
      ),
    );
  }

  /// The inline one-liner. Rendered in place on the grid — no dialog, no sheet.
  /// Enter commits; the close button cancels.
  Widget _inlineEditor(BuildContext context,
      {PlanBlock? block, required int start, required int end}) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: OverflowBox(
        alignment: Alignment.topLeft,
        maxHeight: double.infinity,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(children: [
            Text(
              formatPlanTime(start),
              style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                key: const ValueKey('plan-inline'),
                controller: _inline,
                focusNode: _inlineFocus,
                autofocus: true,
                textInputAction: TextInputAction.done,
                maxLength: planTitleMaxLength,
                buildCounter: (_,
                        {required currentLength,
                        required isFocused,
                        required maxLength}) =>
                    null,
                style: t.bodyMedium,
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: 'What is this?',
                ),
                onSubmitted: (_) =>
                    block == null ? _commitCreate() : _commitEdit(block),
              ),
            ),
            if (block != null)
              IconButton(
                key: ValueKey('plan-inline-done-${block.id}'),
                tooltip: block.done ? 'Mark not done' : 'Mark done',
                icon: Icon(block.done
                    ? Icons.check_circle
                    : Icons.radio_button_unchecked),
                onPressed: () => _runWrite(context,
                    () => _store!.setPlanBlockDone(block.id, !block.done)),
              ),
            IconButton(
              key: const ValueKey('plan-inline-cancel'),
              tooltip: 'Cancel',
              icon: const Icon(Icons.close),
              onPressed: _cancelInline,
            ),
          ]),
        ),
      ),
    );
  }
}
