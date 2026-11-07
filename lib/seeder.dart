import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'data/store.dart';

/// Seeds the bundled exercise catalog on first run, incrementally if the asset grows.
///
/// Runs from `main()` before `runApp`, so it must never throw: a malformed or
/// truncated `assets/exercises.json` would otherwise stop the app from starting
/// at all (audit F6). A bad catalog means "seed nothing", not "do not launch".
Future<void> seedExercises(AppStore store) async {
  final String raw;
  try {
    raw = await rootBundle.loadString('assets/exercises.json');
  } catch (e) {
    debugPrint('seedExercises: could not read exercises.json ($e); '
        'skipping seed');
    return;
  }
  await seedCatalog(store, raw);
}

/// Seeds [store] from the raw JSON text of the catalog.
///
/// Split out from [seedExercises] so the malformed-catalog guard is testable
/// without a real asset bundle. Never throws: a catalog that is not valid JSON,
/// not a list, or full of non-object rows seeds nothing (audit F6).
Future<void> seedCatalog(AppStore store, String raw) async {
  final List<Map<String, Object?>> catalog;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      debugPrint('seedExercises: exercises.json is not a list; skipping seed');
      return;
    }
    catalog = [
      for (final row in decoded)
        if (row is Map) row.cast<String, Object?>(),
    ];
  } catch (e) {
    debugPrint('seedExercises: could not decode exercises.json ($e); '
        'skipping seed');
    return;
  }

  final existing = store.exercises.map((e) => e.name.toLowerCase()).toSet();
  var inserted = 0;
  for (final row in catalog) {
    final name = row['name'];
    if (name is! String || name.isEmpty) continue;
    if (!existing.add(name.toLowerCase())) continue;
    await store.db.insert('exercises', {
      'name': name,
      'muscle_group': _text(row['muscle_group']) ?? 'Other',
      'equipment': _text(row['equipment']) ?? '',
      'is_custom': 0,
    });
    inserted++;
  }
  if (inserted > 0) await store.refreshAll();
}

/// Reads an optional string field without throwing on a wrong type.
String? _text(Object? value) => value is String ? value : null;
