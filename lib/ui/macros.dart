import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../data/store.dart';
import '../domain/domain.dart';
import '../llm/llm.dart';
import 'drawer.dart';
import 'meal_entry.dart';
import 'widgets.dart';

/// How the user chose to log a meal from the "Log meal" sheet.
enum _MealSource { camera, gallery, manual }

class MacrosTab extends StatefulWidget {
  const MacrosTab({super.key});

  @override
  State<MacrosTab> createState() => _MacrosTabState();
}

class _MacrosTabState extends State<MacrosTab> {
  /// The day whose totals and meal list are shown. Defaults to today and is
  /// clamped to today: future days have nothing logged yet.
  DateTime _day = localMidnight(DateTime.now());

  /// Monday of the week shown in the tracker. It follows [_day] so the day view
  /// and the week view can never disagree about which week is on screen.
  DateTime _weekStart = weekStartFor(DateTime.now());

  NutritionMetric _metric = NutritionMetric.calories;

  DateTime get _today => localMidnight(DateTime.now());

  bool get _isToday => _day == _today;

  /// Steps the selected day by [delta] calendar days. Calendar arithmetic, not
  /// `Duration(days: 1)`: across a DST boundary a 24-hour step lands on 23:00
  /// or 01:00 and stops being a day key.
  void _stepDay(int delta) {
    final next = DateTime(_day.year, _day.month, _day.day + delta);
    if (next.isAfter(_today)) return;
    setState(() {
      _day = next;
      _weekStart = weekStartFor(next);
    });
  }

  /// Steps the shown week by [delta] weeks and keeps the day view on the same
  /// weekday inside it, clamped to today so a future day is never selected.
  void _stepWeek(int delta) {
    final nextWeek =
        DateTime(_weekStart.year, _weekStart.month, _weekStart.day + 7 * delta);
    if (nextWeek.isAfter(weekStartFor(_today))) return;
    var nextDay = DateTime(_day.year, _day.month, _day.day + 7 * delta);
    if (nextDay.isAfter(_today)) nextDay = _today;
    setState(() {
      _weekStart = weekStartFor(nextWeek);
      _day = nextDay;
    });
  }

  Future<void> _pickDay() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(2000),
      lastDate: _today,
    );
    if (picked == null || !mounted) return;
    final day = localMidnight(picked);
    setState(() {
      _day = day;
      _weekStart = weekStartFor(day);
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final goals = store.goals;
    final nutritionGoals = NutritionGoals(
      calories: goals.calories,
      protein: goals.protein,
      carbs: goals.carbs,
      fat: goals.fat,
    );
    final day = nutritionDayFor(store.meals, _day, nutritionGoals);
    final dayMeals = mealsOnDay(store.meals, _day);
    final week = weeklyNutrition(store.meals, _weekStart, nutritionGoals);

    return Scaffold(
      appBar: AppBar(
        leading: const DrawerMenuButton(),
        title: Row(children: [
          TintedIconCircle(Icons.restaurant,
              background: scheme.primary, foreground: scheme.onPrimary),
          const SizedBox(width: 10),
          Text('Macros', style: t.titleLarge),
        ]),
        actions: [
          IconButton(
            icon: const Icon(Icons.photo_library_outlined),
            tooltip: 'Meal gallery',
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const GalleryScreen())),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'log-meal',
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        onPressed: () => _logMeal(context, store),
        icon: const Icon(Icons.add),
        label: const Text('Log meal'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 96),
        children: [
          _dayNavCard(context),
          const SizedBox(height: 12),
          Card(
            color: scheme.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(children: [
                _goalRow(context, 'Calories', day.totals.calories,
                    goals.calories, 'kcal'),
                _goalRow(context, 'Protein', day.totals.protein, goals.protein,
                    'g'),
                _goalRow(context, 'Carbs', day.totals.carbs, goals.carbs, 'g'),
                _goalRow(context, 'Fat', day.totals.fat, goals.fat, 'g'),
              ]),
            ),
          ),
          const SizedBox(height: 20),
          _weeklyCard(context, week, nutritionGoals),
          const SizedBox(height: 20),
          SectionHeader(_isToday ? 'Today' : formatDate(_day.millisecondsSinceEpoch)),
          const SizedBox(height: 8),
          if (dayMeals.isEmpty)
            EmptyState(
              title: 'Nothing logged on this day',
              subtitle:
                  'Tap "Log meal" to add one — you can back-date it to this day.',
              icon: Icons.restaurant,
            )
          else
            ...dayMeals.map((meal) => CardRow(
                  icon: Icons.dining,
                  title: meal.dish,
                  subtitle: _mealSubtitle(meal),
                  isThreeLine: (meal.description ?? '').trim().isNotEmpty,
                  trailing: '${trimZero(meal.calories)} kcal\n'
                      'P ${trimZero(meal.protein)} · C ${trimZero(meal.carbs)} · F ${trimZero(meal.fat)}',
                  // Tap opens the full record (with edit/delete in its app bar);
                  // long-press raises the same Edit/Delete sheet as the gallery.
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => MealDetailScreen(mealId: meal.id))),
                  onLongPress: () => _mealActions(context, store, meal),
                )),
        ],
      ),
    );
  }

  /// Date header: previous/next day, plus a calendar picker. Next-day is
  /// disabled on today so the user cannot wander into empty future days.
  Widget _dayNavCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Card(
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(children: [
          IconButton(
            key: const ValueKey('macros-prev-day'),
            tooltip: 'Previous day',
            icon: const Icon(Icons.chevron_left),
            onPressed: () => _stepDay(-1),
          ),
          Expanded(
            child: InkWell(
              onTap: _pickDay,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(children: [
                  Text(formatDate(_day.millisecondsSinceEpoch),
                      style: t.titleMedium, textAlign: TextAlign.center),
                  if (_isToday)
                    Text('Today',
                        style: t.labelSmall?.copyWith(color: scheme.primary)),
                ]),
              ),
            ),
          ),
          IconButton(
            key: const ValueKey('macros-next-day'),
            tooltip: 'Next day',
            icon: const Icon(Icons.chevron_right),
            onPressed: _isToday ? null : () => _stepDay(1),
          ),
          IconButton(
            key: const ValueKey('macros-pick-day'),
            tooltip: 'Pick a date',
            icon: const Icon(Icons.calendar_today_outlined),
            onPressed: _pickDay,
          ),
        ]),
      ),
    );
  }

  Widget _goalRow(BuildContext context, String label, double value, double goal, String unit) {
    final scheme = Theme.of(context).colorScheme;
    final fraction = goal <= 0 ? 0.0 : (value / goal).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(label, style: Theme.of(context).textTheme.titleSmall)),
          Text('${trimZero(value)} / ${trimZero(goal)} $unit',
              style: Theme.of(context).textTheme.labelLarge),
        ]),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: fraction,
            minHeight: 8,
            backgroundColor: scheme.surfaceContainerHighest,
          ),
        ),
      ]),
    );
  }

  /// Weekly tracker: seven bars against the saved goal for the selected
  /// metric, a numeric over/under summary, and one labelled chip per day.
  ///
  /// Over/under is never conveyed by colour alone: every bar has a chip with a
  /// signed number and a ▲/▼/= glyph, and each chip carries a semantic label
  /// ("Monday: 2100 kcal, 100 over goal") that mirrors the bar.
  Widget _weeklyCard(
      BuildContext context, List<NutritionDay> week, NutritionGoals goals) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final isCurrentWeek = _weekStart == weekStartFor(_today);
    final goal = _metric.goalOf(goals);
    final values = [for (final d in week) _metric.valueOf(d.totals)];
    final peak = [goal, ...values].reduce(math.max);
    final maxY = peak <= 0 ? 1.0 : peak * 1.15;
    final summary = summarizeWeek(week, _metric);

    return Card(
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(
                  'Week of ${formatDate(_weekStart.millisecondsSinceEpoch)}',
                  style: t.titleMedium),
            ),
            IconButton(
              key: const ValueKey('macros-prev-week'),
              tooltip: 'Previous week',
              icon: const Icon(Icons.chevron_left),
              onPressed: () => _stepWeek(-1),
            ),
            IconButton(
              key: const ValueKey('macros-next-week'),
              tooltip: 'Next week',
              icon: const Icon(Icons.chevron_right),
              onPressed: isCurrentWeek ? null : () => _stepWeek(1),
            ),
          ]),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final metric in NutritionMetric.values)
              ChoiceChip(
                key: ValueKey('macros-metric-${metric.name}'),
                label: Text(metric.label),
                selected: _metric == metric,
                onSelected: (_) => setState(() => _metric = metric),
              ),
          ]),
          const SizedBox(height: 12),
          Semantics(
            container: true,
            label: 'Weekly ${_metric.label} chart, ${week.length} days, '
                'goal ${trimZero(goal)} ${_metric.unit} per day',
            child: ExcludeSemantics(
              child: SizedBox(
                height: 150,
                child: BarChart(
                  BarChartData(
                    minY: 0,
                    maxY: maxY,
                    alignment: BarChartAlignment.spaceAround,
                    barGroups: [
                      for (var i = 0; i < week.length; i++)
                        BarChartGroupData(x: i, barRods: [
                          BarChartRodData(
                            toY: values[i],
                            width: 14,
                            borderRadius: BorderRadius.circular(3),
                            // The part above the goal is drawn in the error
                            // colour; the chip below carries the same fact as
                            // text, so colour is never the only signal.
                            rodStackItems: values[i] > goal
                                ? [
                                    BarChartRodStackItem(0, goal, scheme.primary),
                                    BarChartRodStackItem(
                                        goal, values[i], scheme.error),
                                  ]
                                : [BarChartRodStackItem(0, values[i], scheme.primary)],
                          ),
                        ]),
                    ],
                    extraLinesData: ExtraLinesData(horizontalLines: [
                      HorizontalLine(
                        y: goal,
                        color: scheme.onSurfaceVariant,
                        strokeWidth: 1,
                        dashArray: const [4, 4],
                        label: HorizontalLineLabel(
                          show: true,
                          alignment: Alignment.topRight,
                          style: TextStyle(
                              fontSize: 9, color: scheme.onSurfaceVariant),
                          labelResolver: (_) => 'goal ${trimZero(goal)}',
                        ),
                      ),
                    ]),
                    titlesData: FlTitlesData(
                      leftTitles: const AxisTitles(),
                      topTitles: const AxisTitles(),
                      rightTitles: const AxisTitles(),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 18,
                          getTitlesWidget: (value, meta) {
                            final i = value.toInt();
                            if (i < 0 || i >= week.length) {
                              return const SizedBox.shrink();
                            }
                            return Text(_weekdayShort(week[i].day),
                                style: const TextStyle(fontSize: 10));
                          },
                        ),
                      ),
                    ),
                    gridData: const FlGridData(show: false),
                    borderData: FlBorderData(show: false),
                    barTouchData: BarTouchData(enabled: false),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${summary.over} over · ${summary.under} under · '
            '${summary.unlogged} not logged',
            style: t.labelLarge,
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final d in week) _dayChip(context, d),
          ]),
        ]),
      ),
    );
  }

  /// Text counterpart of one bar: day, value and signed over/under.
  Widget _dayChip(BuildContext context, NutritionDay day) {
    final scheme = Theme.of(context).colorScheme;
    final value = _metric.valueOf(day.totals);
    final delta = day.deltaFor(_metric);
    final weekday = _weekdayShort(day.day);
    final longDay = _weekdayLong(day.day);
    final unit = _metric.unit;
    final String text;
    final String semantics;
    if (!day.logged) {
      text = '$weekday —';
      semantics = '$longDay: nothing logged';
    } else if (delta > 0) {
      text = '$weekday ${trimZero(value)} ▲${trimZero(delta)}';
      semantics =
          '$longDay: ${trimZero(value)} $unit, ${trimZero(delta)} over goal';
    } else if (delta < 0) {
      text = '$weekday ${trimZero(value)} ▼${trimZero(-delta)}';
      semantics =
          '$longDay: ${trimZero(value)} $unit, ${trimZero(-delta)} under goal';
    } else {
      text = '$weekday ${trimZero(value)} =';
      semantics = '$longDay: ${trimZero(value)} $unit, exactly on goal';
    }
    return Semantics(
      container: true,
      label: semantics,
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(text, style: Theme.of(context).textTheme.labelSmall),
      ),
    );
  }

  /// Entry point for logging a meal. Manual entry is offered first-class and
  /// never touches the AI endpoint; the photo paths still need one configured.
  Future<void> _logMeal(BuildContext context, AppStore store) async {
    final source = await showModalBottomSheet<_MealSource>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_camera),
            title: const Text('Take a photo'),
            subtitle: const Text('Let your AI draft the macros'),
            onTap: () => Navigator.of(sheetContext).pop(_MealSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Choose from gallery'),
            subtitle: const Text('Let your AI draft the macros'),
            onTap: () => Navigator.of(sheetContext).pop(_MealSource.gallery),
          ),
          ListTile(
            leading: const Icon(Icons.edit_note),
            title: const Text('Enter manually'),
            subtitle: const Text('Type the macros yourself — no photo or AI needed'),
            onTap: () => Navigator.of(sheetContext).pop(_MealSource.manual),
          ),
        ]),
      ),
    );
    if (source == null || !context.mounted) return;

    if (source == _MealSource.manual) {
      // Pre-fill the day being viewed so a meal logged from a past date lands
      // on that date instead of silently vanishing into today.
      await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ManualMealScreen(
              initialDate: _isToday ? null : _day)));
      return;
    }

    final ai = store.ai;
    if (!ai.configured) {
      _snack(context, 'Configure your AI endpoint in Settings to analyze meal photos.');
      return;
    }
    final picked = await ImagePicker().pickImage(
        source: source == _MealSource.camera
            ? ImageSource.camera
            : ImageSource.gallery,
        maxWidth: 1280,
        imageQuality: 82);
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    if (!context.mounted) return;

    // Optional description *before* the vision call: the user sees the shot they
    // just took and can name the dish or the portion. Returning null means they
    // backed out, so nothing is analyzed or saved; an empty string is the
    // photo-only flow and behaves exactly like it always did.
    final note = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _DescribeMealSheet(bytes: bytes),
    );
    if (note == null || !context.mounted) return;
    final description = note.trim();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _AnalyzingSheet(),
    );
    try {
      final dir = await getApplicationDocumentsDirectory();
      final mealsDir = Directory(p.join(dir.path, 'meals'));
      await mealsDir.create(recursive: true);
      final file =
          File(p.join(mealsDir.path, 'meal-${DateTime.now().millisecondsSinceEpoch}.jpg'));
      await file.writeAsBytes(bytes);

      final draft = await analyzeMealPhoto(
          ChatClient(ai.baseUrl, ai.apiKey, ai.model), bytes, 'image/jpeg', store.meals,
          note: description.isEmpty ? null : description);
      if (!context.mounted) return;
      Navigator.of(context).pop();
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ReviewScreen(
              draft: draft,
              imagePath: file.path,
              description: description)));
    } catch (e) {
      if (!context.mounted) return;
      Navigator.of(context).pop();
      _snack(context, 'Analysis failed: $e');
    }
  }

  void _snack(BuildContext context, String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }
}

const _weekdayShortNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _weekdayLongNames = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday'
];

String _weekdayShort(DateTime day) => _weekdayShortNames[day.weekday - 1];
String _weekdayLong(DateTime day) => _weekdayLongNames[day.weekday - 1];


class _AnalyzingSheet extends StatelessWidget {
  const _AnalyzingSheet();

  @override
  Widget build(BuildContext context) {
    return const AlertDialog(
      content: Row(children: [
        CircularProgressIndicator(),
        SizedBox(width: 16),
        Text('Your AI is reading the plate…'),
      ]),
    );
  }
}

/// Bottom sheet shown between "photo taken" and "analyze it".
///
/// Pops with the typed text (possibly empty) when the user taps Analyze, or
/// with null when they cancel, so the caller can tell "no note" apart from
/// "abandoned".
class _DescribeMealSheet extends StatefulWidget {
  final Uint8List bytes;
  const _DescribeMealSheet({required this.bytes});

  @override
  State<_DescribeMealSheet> createState() => _DescribeMealSheetState();
}

class _DescribeMealSheetState extends State<_DescribeMealSheet> {
  final TextEditingController controller = TextEditingController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void _analyze() => Navigator.of(context).pop(controller.text);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.memory(widget.bytes,
                      width: 64,
                      height: 64,
                      fit: BoxFit.cover,
                      cacheWidth: 192),
                ),
                const SizedBox(width: 12),
                Expanded(
                    child: Text('Describe this meal', style: t.titleMedium)),
              ]),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _analyze(),
                decoration: const InputDecoration(
                  labelText: 'Description (optional)',
                  hintText: 'e.g. two slices, extra cheese',
                  helperText:
                      'Gives your AI the portion size. Leave it blank to analyze the photo alone.',
                  helperMaxLines: 2,
                ),
              ),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _analyze,
                    icon: const Icon(Icons.auto_awesome),
                    label: const Text('Analyze'),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

class ReviewScreen extends StatefulWidget {
  final Draft draft;
  final String imagePath;

  /// Note typed before analysis; pre-fills the description field so the text
  /// the user typed survives into the saved meal.
  final String description;

  /// Non-null when this screen is editing a meal that is already saved.
  final Meal? existing;

  const ReviewScreen({
    super.key,
    required this.draft,
    required this.imagePath,
    this.description = '',
    this.existing,
  });

  /// Edit mode: pre-fills every field from [meal] so saving updates that row
  /// (via `store.updateMeal`) instead of inserting a duplicate.
  factory ReviewScreen.edit(Meal meal) => ReviewScreen(
        draft: Draft(meal.dish, meal.foods, meal.calories, meal.protein,
            meal.carbs, meal.fat),
        imagePath: meal.imagePath,
        description: meal.description ?? '',
        existing: meal,
      );

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  late final TextEditingController dish = TextEditingController(text: widget.draft.dish);
  late final TextEditingController description =
      TextEditingController(text: widget.description);
  // Pre-filled with the stored value at display precision, not `.round()`:
  // rounding here silently rewrote 32.4 g as 32 g on a no-op save (review
  // BLOCKER-1).
  late final TextEditingController protein =
      TextEditingController(text: trimZero(widget.draft.protein));
  late final TextEditingController carbs =
      TextEditingController(text: trimZero(widget.draft.carbs));
  late final TextEditingController fat =
      TextEditingController(text: trimZero(widget.draft.fat));

  /// The macro fields exactly as they were pre-filled. A save that leaves them
  /// untouched must not rewrite the stored row: a coach-logged 600 kcal /
  /// 0-0-0 meal would otherwise be stored as 0 kcal (review BLOCKER-1).
  late final String _initialProtein = protein.text;
  late final String _initialCarbs = carbs.text;
  late final String _initialFat = fat.text;

  bool get _isEdit => widget.existing != null;

  /// True once the user has actually edited a macro field.
  bool get _macrosChanged =>
      protein.text != _initialProtein ||
      carbs.text != _initialCarbs ||
      fat.text != _initialFat;

  double get _protein => parseMacroGrams(protein.text);
  double get _carbs => parseMacroGrams(carbs.text);
  double get _fat => parseMacroGrams(fat.text);

  @override
  void dispose() {
    for (final c in [dish, description, protein, carbs, fat]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save(AppStore store) async {
    final existing = widget.existing;
    final note = description.text.trim();
    // Calories are derived from macros only when the user actually edited a
    // macro field. A no-op save in edit mode keeps the stored nutrition
    // byte-identical, so a coach/AI estimate the macros cannot explain (600
    // kcal with 0/0/0 macros) survives instead of being rewritten to 0 kcal
    // (review BLOCKER-1).
    final double calories;
    final double proteinGrams;
    final double carbsGrams;
    final double fatGrams;
    if (existing != null && !_macrosChanged) {
      calories = existing.calories;
      proteinGrams = existing.protein;
      carbsGrams = existing.carbs;
      fatGrams = existing.fat;
    } else {
      calories = caloriesFromMacros(_protein, _carbs, _fat);
      proteinGrams = _protein;
      carbsGrams = _carbs;
      fatGrams = _fat;
    }
    final meal = Meal(
      // Edit mode keeps the row identity; new meals get 0 so SQLite assigns it.
      id: existing?.id ?? 0,
      timestamp: existing?.timestamp ?? DateTime.now().millisecondsSinceEpoch,
      imagePath: widget.imagePath,
      dish: dish.text.trim().isEmpty ? 'Meal' : dish.text.trim(),
      description: note.isEmpty ? null : note,
      calories: calories,
      protein: proteinGrams,
      carbs: carbsGrams,
      fat: fatGrams,
      foods: existing?.foods ?? widget.draft.foods,
      isAuto: existing?.isAuto ?? true,
    );
    if (existing == null) {
      await store.addMeal(meal);
    } else {
      await store.updateMeal(meal);
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.read<AppStore>();
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'Edit meal' : 'Review meal')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // A manual meal has no photo; the 240px placeholder would just be a
          // large empty block, so the whole photo area is omitted.
          if (widget.imagePath.isNotEmpty) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: MealPhoto(widget.imagePath,
                  height: 240, fit: BoxFit.cover, iconSize: 44),
            ),
            const SizedBox(height: 20),
          ],
          SectionHeader(_isEdit ? 'Edit the details' : 'Confirm before saving'),
          const SizedBox(height: 8),
          TextField(controller: dish, decoration: const InputDecoration(labelText: 'Dish')),
          const SizedBox(height: 12),
          TextField(
            controller: description,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Description (optional)',
              hintText: 'e.g. two slices, extra cheese',
            ),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
                child: TextField(
                    controller: protein,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: 'Protein g'))),
            const SizedBox(width: 8),
            Expanded(
                child: TextField(
                    controller: carbs,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: 'Carbs g'))),
            const SizedBox(width: 8),
            Expanded(
                child: TextField(
                    controller: fat,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: 'Fat g'))),
          ]),
          const SizedBox(height: 12),
          MacroCalorieSummary(
            protein: _protein,
            carbs: _carbs,
            fat: _fat,
            // Edit mode compares against the stored row; a fresh AI draft
            // compares against the model's own estimate.
            referenceCalories:
                _isEdit ? widget.existing!.calories : widget.draft.calories,
            referenceLabel: _isEdit ? 'stored' : 'AI estimate',
            // Saving keeps the stored figure while the macros are untouched.
            keepStoredCalories: _isEdit && !_macrosChanged,
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            icon: const Icon(Icons.save),
            label: Text(_isEdit ? 'Save changes' : 'Save meal'),
            onPressed: () => _save(store),
          ),
          if (_isEdit) ...[
            const SizedBox(height: 12),
            Text(
              'Saving updates the meal you already logged — it does not create a second one.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }
}

/// Photo for a saved meal, with a placeholder whenever there is nothing to
/// show. `Image.file(File(''))` throws, so an empty path must never reach it;
/// coach-logged meals (`lib/coach/tools.dart`) always have an empty path.
class MealPhoto extends StatelessWidget {
  final String path;
  final int? cacheWidth;
  final double? height;
  final BoxFit fit;
  final double iconSize;
  const MealPhoto(this.path,
      {super.key,
      this.cacheWidth,
      this.height,
      this.fit = BoxFit.cover,
      this.iconSize = 32});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget placeholder() => SizedBox(
          height: height,
          child: ColoredBox(
            color: scheme.surfaceContainerHighest,
            child: Center(
              child: Icon(Icons.restaurant_outlined,
                  size: iconSize, color: scheme.onSurfaceVariant),
            ),
          ),
        );
    if (path.isEmpty || !File(path).existsSync()) return placeholder();
    return Image.file(
      File(path),
      height: height,
      fit: fit,
      cacheWidth: cacheWidth,
      errorBuilder: (context, error, stackTrace) => placeholder(),
    );
  }
}

class GalleryScreen extends StatelessWidget {
  const GalleryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    return Scaffold(
      appBar: AppBar(title: const Text('Meal gallery')),
      body: store.meals.isEmpty
          ? const Center(
              child: EmptyState(
                title: 'No meals yet',
                subtitle: 'Photos of logged meals will gather here.',
                icon: Icons.photo_library_outlined,
              ),
            )
          : GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 200,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 0.8,
              ),
              itemCount: store.meals.length,
              itemBuilder: (context, i) {
                final meal = store.meals[i];
                return _MealThumb(
                  meal: meal,
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => MealDetailScreen(mealId: meal.id))),
                  onLongPress: () => _mealActions(context, store, meal),
                );
              },
            ),
    );
  }
}

/// One square-ish gallery tile: photo on top, dish + kcal on a scrim.
class _MealThumb extends StatelessWidget {
  final Meal meal;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  const _MealThumb(
      {required this.meal, required this.onTap, required this.onLongPress});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label:
          '${meal.dish}, ${trimZero(meal.calories)} kcal, ${formatDateTime(meal.timestamp)}',
      onTap: onTap,
      onLongPress: onLongPress,
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        onLongPress: onLongPress,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Stack(fit: StackFit.expand, children: [
            // cacheWidth decodes a thumbnail, not the full-resolution photo.
            MealPhoto(meal.imagePath, cacheWidth: 400),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.center,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black54],
                ),
              ),
            ),
            Positioned(
              left: 8,
              right: 8,
              bottom: 8,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(meal.dish,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600)),
                  Text('${trimZero(meal.calories)} kcal',
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 11)),
                ],
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Full meal record: photo, description, macros and when it was logged.
class MealDetailScreen extends StatelessWidget {
  final int mealId;
  const MealDetailScreen({super.key, required this.mealId});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final matches = store.meals.where((m) => m.id == mealId).toList();
    if (matches.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Meal')),
        body: const Center(
          child: EmptyState(
            title: 'Meal removed',
            subtitle: 'This meal is no longer in your log.',
            icon: Icons.delete_outline,
          ),
        ),
      );
    }
    final meal = matches.first;
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final note = (meal.description ?? '').trim();
    return Scaffold(
      appBar: AppBar(
        title: Text(meal.dish),
        actions: [
          IconButton(
            tooltip: 'Edit meal',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => ReviewScreen.edit(meal))),
          ),
          IconButton(
            tooltip: 'Delete meal',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              final deleted = await _confirmDeleteMeal(context, meal);
              if (!deleted || !context.mounted) return;
              await store.deleteMeal(meal.id);
              if (context.mounted) Navigator.of(context).pop();
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: MealPhoto(meal.imagePath,
                height: 240, fit: BoxFit.cover, iconSize: 44),
          ),
          const SizedBox(height: 20),
          Text(formatDateTime(meal.timestamp),
              style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 16),
          const SectionHeader('Macros'),
          const SizedBox(height: 8),
          Wrap(spacing: 16, runSpacing: 12, children: [
            _detailStat(context, 'Calories', '${trimZero(meal.calories)} kcal'),
            _detailStat(context, 'Protein', '${trimZero(meal.protein)} g'),
            _detailStat(context, 'Carbs', '${trimZero(meal.carbs)} g'),
            _detailStat(context, 'Fat', '${trimZero(meal.fat)} g'),
          ]),
          const SizedBox(height: 20),
          const SectionHeader('Description'),
          const SizedBox(height: 8),
          Text(
            note.isEmpty ? 'No description added.' : note,
            style: t.bodyMedium?.copyWith(
                color: note.isEmpty ? scheme.onSurfaceVariant : null),
          ),
          if (meal.foods.isNotEmpty) ...[
            const SizedBox(height: 20),
            const SectionHeader('Items'),
            const SizedBox(height: 8),
            for (final food in meal.foods)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Expanded(child: Text(food.name, style: t.bodyMedium)),
                  Text('${trimZero(food.calories)} kcal',
                      style: t.labelLarge?.copyWith(color: scheme.primary)),
                ]),
              ),
          ],
        ],
      ),
    );
  }

  Widget _detailStat(BuildContext context, String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(value,
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(color: scheme.primary)),
      Text(label,
          style: Theme.of(context)
              .textTheme
              .labelMedium
              ?.copyWith(color: scheme.onSurfaceVariant)),
    ]);
  }
}

enum _MealAction { edit, delete }

/// Date/time plus a one-line preview of the optional description.
String _mealSubtitle(Meal meal) {
  final date = formatDateTime(meal.timestamp);
  final note = (meal.description ?? '').trim();
  if (note.isEmpty) return date;
  final preview = note.length > 64 ? '${note.substring(0, 63)}…' : note;
  return '$date\n$preview';
}

/// Long-press menu for a meal. Deleting always goes through
/// [_confirmDeleteMeal]; nothing is removed from the log on a gesture alone.
Future<void> _mealActions(
    BuildContext context, AppStore store, Meal meal) async {
  final scheme = Theme.of(context).colorScheme;
  final action = await showModalBottomSheet<_MealAction>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          title: Text(meal.dish,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(
              '${formatDateTime(meal.timestamp)} · ${trimZero(meal.calories)} kcal'),
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.edit_outlined),
          title: const Text('Edit meal'),
          onTap: () => Navigator.of(sheetContext).pop(_MealAction.edit),
        ),
        ListTile(
          leading: Icon(Icons.delete_outline, color: scheme.error),
          title: Text('Delete meal', style: TextStyle(color: scheme.error)),
          onTap: () => Navigator.of(sheetContext).pop(_MealAction.delete),
        ),
      ]),
    ),
  );
  if (action == null || !context.mounted) return;

  if (action == _MealAction.edit) {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => ReviewScreen.edit(meal)));
    return;
  }

  final confirmed = await _confirmDeleteMeal(context, meal);
  if (!confirmed || !context.mounted) return;
  await store.deleteMeal(meal.id);
  if (context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Deleted "${meal.dish}"')));
  }
}

Future<bool> _confirmDeleteMeal(BuildContext context, Meal meal) async {
  final scheme = Theme.of(context).colorScheme;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Delete this meal?'),
      content: Text(
          '"${meal.dish}" will be removed from your log. This cannot be undone.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: scheme.error, foregroundColor: scheme.onError),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
