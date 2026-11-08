import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../data/store.dart';
import '../domain/domain.dart';
import 'widgets.dart';

/// Read-only calorie readout derived from the macro fields.
///
/// Calories are never an independent input: the value shown here is always
/// [caloriesFromMacros] of the current protein/carbs/fat fields. When a
/// previously recorded figure exists ([referenceCalories] — the stored value
/// in edit mode, or the AI draft before saving) and it disagrees with the
/// computed value, both are shown so the earlier estimate is never silently
/// rewritten.
class MacroCalorieSummary extends StatelessWidget {
  final double protein;
  final double carbs;
  final double fat;

  /// The figure already on record, if any.
  final double? referenceCalories;

  /// How to name [referenceCalories] in the comparison line ("stored",
  /// "AI estimate").
  final String referenceLabel;

  /// True when saving will keep [referenceCalories] because the macro fields
  /// have not been edited (edit mode). The readout then says so explicitly
  /// instead of leaving the user to guess which figure wins.
  final bool keepStoredCalories;

  const MacroCalorieSummary({
    super.key,
    required this.protein,
    required this.carbs,
    required this.fat,
    this.referenceCalories,
    this.referenceLabel = 'stored',
    this.keepStoredCalories = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final computed = caloriesFromMacros(protein, carbs, fat);
    final reference = referenceCalories;
    // Compare the real figures, not their rounded forms: a 0.4 kcal
    // difference used to be rewritten with no disclosure at all (review
    // BLOCKER-1).
    final differs = reference != null && reference != computed;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(children: [
          Icon(Icons.local_fire_department_outlined, color: scheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Text('${computed.round()} kcal',
                style: t.titleMedium?.copyWith(color: scheme.primary)),
          ),
          Text('calculated',
              style: t.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
        ]),
      ),
      const SizedBox(height: 6),
      Text(
        'Calculated from macros: 4 kcal/g protein, 4 kcal/g carbs, '
        '9 kcal/g fat. Calories are not edited directly.',
        style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      ),
      if (differs) ...[
        const SizedBox(height: 6),
        Text(
          '$referenceLabel ${reference.round()} kcal · '
          '4/4/9 gives ${computed.round()} kcal',
          style: t.bodySmall?.copyWith(color: scheme.tertiary),
        ),
      ],
      if (keepStoredCalories && differs) ...[
        const SizedBox(height: 6),
        Text(
          'Macros unchanged — saving keeps the $referenceLabel '
          '${reference.round()} kcal.',
          style: t.bodySmall?.copyWith(color: scheme.tertiary),
        ),
      ],
    ]);
  }
}

/// Manual meal entry: no photo and no AI endpoint required.
///
/// Saves a [Meal] with an empty `imagePath` and `isAuto: false`, which is the
/// same shape coach-logged meals use, so no schema change is involved.
class ManualMealScreen extends StatefulWidget {
  /// Day to pre-fill when the Macros tab is showing a past date. Null means
  /// "today, at the current time".
  final DateTime? initialDate;

  const ManualMealScreen({super.key, this.initialDate});

  @override
  State<ManualMealScreen> createState() => _ManualMealScreenState();
}

class _ManualMealScreenState extends State<ManualMealScreen> {
  final TextEditingController dish = TextEditingController();
  final TextEditingController description = TextEditingController();
  final TextEditingController protein = TextEditingController();
  final TextEditingController carbs = TextEditingController();
  final TextEditingController fat = TextEditingController();

  /// Defaults to now; the date picker can back-date the meal. When the Macros
  /// tab is showing a past day, that day is pre-filled instead.
  late DateTime timestamp = widget.initialDate ?? DateTime.now();

  double get _protein => parseMacroGrams(protein.text);
  double get _carbs => parseMacroGrams(carbs.text);
  double get _fat => parseMacroGrams(fat.text);

  /// A meal needs at least a name or one non-zero macro. Saving an empty form
  /// used to create a 0 kcal "Meal" row by accident (review nutrition NIT-3).
  bool get _hasContent =>
      dish.text.trim().isNotEmpty || _protein > 0 || _carbs > 0 || _fat > 0;

  @override
  void dispose() {
    for (final c in [dish, description, protein, carbs, fat]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final initial = timestamp.isAfter(today) ? today : timestamp;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: today,
    );
    if (picked == null || !mounted) return;
    setState(() {
      // Keep the time of day so meals logged on the same date still order
      // sensibly; only the calendar day changes.
      timestamp = DateTime(picked.year, picked.month, picked.day,
          timestamp.hour, timestamp.minute);
    });
  }

  Future<void> _save(AppStore store) async {
    final note = description.text.trim();
    final meal = Meal(
      id: 0,
      timestamp: timestamp.millisecondsSinceEpoch,
      imagePath: '',
      dish: dish.text.trim().isEmpty ? 'Meal' : dish.text.trim(),
      description: note.isEmpty ? null : note,
      calories: caloriesFromMacros(_protein, _carbs, _fat),
      protein: _protein,
      carbs: _carbs,
      fat: _fat,
      isAuto: false,
    );
    await store.addMeal(meal);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.read<AppStore>();
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Log meal manually')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SectionHeader('What did you eat?'),
          const SizedBox(height: 8),
          TextField(
            controller: dish,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Dish'),
          ),
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
          InkWell(
            onTap: _pickDate,
            borderRadius: BorderRadius.circular(12),
            child: InputDecorator(
              decoration: const InputDecoration(
                labelText: 'Date',
                suffixIcon: Icon(Icons.calendar_today_outlined),
              ),
              child: Text(formatDateTime(timestamp.millisecondsSinceEpoch)),
            ),
          ),
          const SizedBox(height: 20),
          const SectionHeader('Macros'),
          const SizedBox(height: 8),
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
          MacroCalorieSummary(protein: _protein, carbs: _carbs, fat: _fat),
          const SizedBox(height: 20),
          FilledButton.icon(
            icon: const Icon(Icons.save),
            label: const Text('Save meal'),
            onPressed: _hasContent ? () => _save(store) : null,
          ),
          const SizedBox(height: 12),
          Text(
            'No photo needed — this meal is saved with your macros and the '
            'calories they imply.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
