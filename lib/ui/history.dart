import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/store.dart';
import '../domain/domain.dart';
import 'summary.dart';
import 'widgets.dart';

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    return Scaffold(
      appBar: AppBar(title: const Text('History')),
      body: store.history.isEmpty
          ? const Center(
              child: EmptyState(
                title: 'No finished workouts',
                subtitle: 'Finish a workout and it will appear here.',
                icon: Icons.history,
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                for (final row in store.history)
                  CardRow(
                    icon: Icons.fitness_center,
                    title: row.name,
                    subtitle:
                        '${formatDate(row.startedAt)} · ${formatDuration(row.startedAt, row.endedAt)}'
                        '${row.prCount > 0 ? ' · ${row.prCount} ${row.prCount == 1 ? 'PR' : 'PRs'}' : ''}',
                    trailing:
                        '${trimZero(fromKg(row.totalKg, store.unit))} ${store.unit.label}',
                    onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => SummaryScreen(row.workoutId))),
                  ),
              ],
            ),
    );
  }
}
