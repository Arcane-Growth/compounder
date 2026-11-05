import 'dart:io';

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
          const ScreenIntro(
            eyebrow: 'FUEL THE COMPOUND',
            title: 'Snap it,\ntrack it.',
            subtitle:
                'Point your AI at a photo of the plate and review the macros before anything is saved.',
          ),
          const SizedBox(height: 20),
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
                  subtitle: formatDateTime(meal.timestamp),
                  trailing: '${trimZero(meal.calories)} kcal\n'
                      'P ${trimZero(meal.protein)} · C ${trimZero(meal.carbs)} · F ${trimZero(meal.fat)}',
                  onLongPress: () => store.deleteMeal(meal.id),
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
          ChatClient(ai.baseUrl, ai.apiKey, ai.model), bytes, 'image/jpeg', store.meals);
      if (!context.mounted) return;
      Navigator.of(context).pop();
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ReviewScreen(draft: draft, imagePath: file.path)));
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

class ReviewScreen extends StatefulWidget {
  final Draft draft;
  final String imagePath;
  const ReviewScreen({super.key, required this.draft, required this.imagePath});

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  late final TextEditingController dish = TextEditingController(text: widget.draft.dish);
  late final TextEditingController calories =
      TextEditingController(text: widget.draft.calories.round().toString());
  late final TextEditingController protein =
      TextEditingController(text: widget.draft.protein.round().toString());
  late final TextEditingController carbs =
      TextEditingController(text: widget.draft.carbs.round().toString());
  late final TextEditingController fat =
      TextEditingController(text: widget.draft.fat.round().toString());

  @override
  void dispose() {
    for (final c in [dish, calories, protein, carbs, fat]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.read<AppStore>();
    return Scaffold(
      appBar: AppBar(title: const Text('Review meal')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Image.file(File(widget.imagePath), height: 240, fit: BoxFit.cover),
          ),
          const SizedBox(height: 20),
          const SectionHeader('Confirm before saving'),
          const SizedBox(height: 8),
          TextField(controller: dish, decoration: const InputDecoration(labelText: 'Dish')),
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
            label: const Text('Save meal'),
            onPressed: () async {
              await store.addMeal(Meal(
                id: 0,
                timestamp: DateTime.now().millisecondsSinceEpoch,
                imagePath: widget.imagePath,
                dish: dish.text.trim().isEmpty ? 'Meal' : dish.text.trim(),
                calories: double.tryParse(calories.text) ?? 0,
                protein: double.tryParse(protein.text) ?? 0,
                carbs: double.tryParse(carbs.text) ?? 0,
                fat: double.tryParse(fat.text) ?? 0,
                foods: widget.draft.foods,
                isAuto: true,
              ));
              if (context.mounted) Navigator.of(context).pop();
            },
          ),
        ],
      ),
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
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                for (final meal in store.meals)
                  CardRow(
                    icon: Icons.dining,
                    title: meal.dish,
                    subtitle:
                        '${formatDateTime(meal.timestamp)} · ${trimZero(meal.calories)} kcal',
                    onLongPress: () => store.deleteMeal(meal.id),
                  ),
              ],
            ),
    );
  }
}
