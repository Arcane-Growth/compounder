import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../data/store.dart';
import '../domain/domain.dart';
import '../llm/llm.dart';
import 'widgets.dart';

class MacrosTab extends StatelessWidget {
  const MacrosTab({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final totals = store.todayTotals();
    final goals = store.goals;
    final now = DateTime.now();
    final startOfDay = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
    final todays = store.meals.where((m) => m.timestamp >= startOfDay).toList();

    return Scaffold(
      appBar: AppBar(
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
        onPressed: () => _capture(context, store),
        icon: const Icon(Icons.photo_camera),
        label: const Text('Log meal'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 96),
        children: [
          Card(
            color: scheme.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(children: [
                _goalRow(context, 'Calories', totals.calories, goals.calories, 'kcal'),
                _goalRow(context, 'Protein', totals.protein, goals.protein, 'g'),
                _goalRow(context, 'Carbs', totals.carbs, goals.carbs, 'g'),
                _goalRow(context, 'Fat', totals.fat, goals.fat, 'g'),
              ]),
            ),
          ),
          const SizedBox(height: 20),
          const SectionHeader("Today"),
          const SizedBox(height: 8),
          if (todays.isEmpty)
            const EmptyState(
              title: 'Nothing logged yet today',
              subtitle: 'Tap "Log meal" to photograph a plate and let your AI draft the macros.',
              icon: Icons.restaurant,
            )
          else
            ...todays.map((meal) => CardRow(
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

  Future<void> _capture(BuildContext context, AppStore store) async {
    final ai = store.ai;
    if (!ai.configured) {
      _snack(context, 'Configure your AI endpoint in Settings to analyze meal photos.');
      return;
    }
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_camera),
            title: const Text('Take a photo'),
            onTap: () => Navigator.of(sheetContext).pop(ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Choose from gallery'),
            onTap: () => Navigator.of(sheetContext).pop(ImageSource.gallery),
          ),
        ]),
      ),
    );
    if (source == null) return;
    final picked = await ImagePicker().pickImage(
        source: source, maxWidth: 1280, imageQuality: 82);
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
  late final TextEditingController calories =
      TextEditingController(text: widget.draft.calories.round().toString());
  late final TextEditingController protein =
      TextEditingController(text: widget.draft.protein.round().toString());
  late final TextEditingController carbs =
      TextEditingController(text: widget.draft.carbs.round().toString());
  late final TextEditingController fat =
      TextEditingController(text: widget.draft.fat.round().toString());

  bool get _isEdit => widget.existing != null;

  @override
  void dispose() {
    for (final c in [dish, description, calories, protein, carbs, fat]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save(AppStore store) async {
    final existing = widget.existing;
    final note = description.text.trim();
    final meal = Meal(
      // Edit mode keeps the row identity; new meals get 0 so SQLite assigns it.
      id: existing?.id ?? 0,
      timestamp: existing?.timestamp ?? DateTime.now().millisecondsSinceEpoch,
      imagePath: widget.imagePath,
      dish: dish.text.trim().isEmpty ? 'Meal' : dish.text.trim(),
      description: note.isEmpty ? null : note,
      calories: double.tryParse(calories.text) ?? 0,
      protein: double.tryParse(protein.text) ?? 0,
      carbs: double.tryParse(carbs.text) ?? 0,
      fat: double.tryParse(fat.text) ?? 0,
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
          ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: MealPhoto(widget.imagePath,
                height: 240, fit: BoxFit.cover, iconSize: 44),
          ),
          const SizedBox(height: 20),
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
                    controller: calories,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'kcal'))),
            const SizedBox(width: 8),
            Expanded(
                child: TextField(
                    controller: protein,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Protein g'))),
            const SizedBox(width: 8),
            Expanded(
                child: TextField(
                    controller: carbs,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Carbs g'))),
            const SizedBox(width: 8),
            Expanded(
                child: TextField(
                    controller: fat,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Fat g'))),
          ]),
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
