import 'dart:convert';

import 'package:flutter/services.dart';

import 'data/store.dart';

/// Seeds the bundled exercise catalog on first run, incrementally if the asset grows.
Future<void> seedExercises(AppStore store) async {
  final raw = await rootBundle.loadString('assets/exercises.json');
  final catalog = (jsonDecode(raw) as List).cast<Map<String, Object?>>();
  final existing = store.exercises.map((e) => e.name.toLowerCase()).toSet();
  var inserted = 0;
  for (final row in catalog) {
    final name = row['name'] as String;
    if (existing.contains(name.toLowerCase())) continue;
    await store.db.insert('exercises', {
      'name': name,
      'muscle_group': row['muscle_group'] as String? ?? 'Other',
      'equipment': row['equipment'] as String? ?? '',
      'is_custom': 0,
    });
    inserted++;
  }
  if (inserted > 0) await store.refreshAll();
}
