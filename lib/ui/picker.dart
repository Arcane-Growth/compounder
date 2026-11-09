import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../data/store.dart';
import 'widgets.dart';

const muscleGroups = [
  'Chest',
  'Back',
  'Shoulders',
  'Quads',
  'Hamstrings',
  'Glutes',
  'Calves',
  'Biceps',
  'Triceps',
  'Forearms',
  'Core',
  'Full Body',
  'Other',
];

const equipmentTypes = [
  'BARBELL',
  'DUMBBELL',
  'MACHINE',
  'BODYWEIGHT',
  'OTHER'
];

class ExercisePickerScreen extends StatefulWidget {
  /// AppBar title. The workout screen adds an exercise ("Add exercise"); the
  /// fitness hub opens the same list as a browsable library.
  final String title;

  const ExercisePickerScreen({super.key, this.title = 'Add exercise'});

  @override
  State<ExercisePickerScreen> createState() => _ExercisePickerScreenState();
}

class _ExercisePickerScreenState extends State<ExercisePickerScreen> {
  String query = '';

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final results = store.pickerList(query);

    final frequent = results.take(8).toList();
    final grouped = <String, List<Exercise>>{};
    for (final e in results) {
      grouped.putIfAbsent(e.muscleGroup, () => []).add(e);
    }
    final groupNames = grouped.keys.toList()
      ..sort((a, b) {
        final ia = muscleGroups.indexOf(a);
        final ib = muscleGroups.indexOf(b);
        return (ia < 0 ? 99 : ia).compareTo(ib < 0 ? 99 : ib);
      });

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Create custom exercise',
            onPressed: () => _showCreateDialog(context, store),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
            child: TextField(
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Search exercises…',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (v) => setState(() => query = v),
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                if (frequent.isNotEmpty && query.isEmpty) ...[
                  const SectionHeader('Most used'),
                  ...frequent.map((e) => _tile(context, e)),
                ],
                for (final group in groupNames) ...[
                  SectionHeader(group),
                  ...grouped[group]!.map((e) => _tile(context, e)),
                ],
                if (results.isEmpty)
                  const EmptyState(
                    title: 'Nothing found',
                    subtitle:
                        'Try another name, or create a custom exercise with the + button.',
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, Exercise e) => ListTile(
        title: Text(e.name),
        subtitle: Text(e.isCustom ? 'custom' : e.equipment.toLowerCase()),
        onTap: () => Navigator.pop(context, e.id),
      );

  void _showCreateDialog(BuildContext context, AppStore store) {
    final name = TextEditingController();
    var muscle = 'Other';
    var equipment = 'OTHER';
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Custom exercise'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: muscle,
              decoration: const InputDecoration(labelText: 'Muscle group'),
              items: [
                for (final m in muscleGroups)
                  DropdownMenuItem(value: m, child: Text(m))
              ],
              onChanged: (v) => setDialogState(() => muscle = v ?? muscle),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: equipment,
              decoration: const InputDecoration(labelText: 'Equipment'),
              items: [
                for (final m in equipmentTypes)
                  DropdownMenuItem(value: m, child: Text(m))
              ],
              onChanged: (v) =>
                  setDialogState(() => equipment = v ?? equipment),
            ),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                if (name.text.trim().isEmpty) return;
                await store.createExercise(name.text, muscle, equipment);
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
  }
}
