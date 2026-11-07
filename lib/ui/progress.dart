import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/store.dart';
import '../domain/domain.dart';
import 'widgets.dart';

class ProgressScreen extends StatefulWidget {
  const ProgressScreen({super.key});

  @override
  State<ProgressScreen> createState() => _ProgressScreenState();
}

class _ProgressScreenState extends State<ProgressScreen> {
  int? selectedExerciseId;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final scheme = Theme.of(context).colorScheme;

    final options = <int, String>{
      for (final id in store.usageOrder) id: store.exercises.firstWhere((e) => e.id == id).name,
    };
    for (final e in store.exercises) {
      options.putIfAbsent(e.id, () => e.name);
    }
    final exerciseId = options.containsKey(selectedExerciseId)
        ? selectedExerciseId
        : options.keys.firstOrNull;

    return Scaffold(
      appBar: AppBar(title: const Text('Progress')),
      body: options.isEmpty
          ? const Center(
              child: EmptyState(
                title: 'No exercises yet',
                subtitle: 'Log a few workouts and your strength curves will show up here.',
                icon: Icons.show_chart,
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                DropdownButtonFormField<int>(
                  initialValue: exerciseId,
                  decoration: const InputDecoration(labelText: 'Exercise'),
                  items: [
                    for (final entry in options.entries.take(40))
                      DropdownMenuItem(value: entry.key, child: Text(entry.value))
                  ],
                  onChanged: (v) => setState(() => selectedExerciseId = v),
                ),
                const SizedBox(height: 20),
                FutureBuilder<List<E1RmPoint>>(
                  future: exerciseId == null ? Future.value(const <E1RmPoint>[]) : store.progressFor(exerciseId),
                  builder: (context, snap) {
                    if (snap.hasError) {
                      return const Padding(
                        padding: EdgeInsets.only(top: 40),
                        child: EmptyState(
                          title: 'Could not load progress',
                          subtitle: 'The strength history could not be read.',
                          icon: Icons.error_outline,
                        ),
                      );
                    }
                    final points = snap.data ?? const <E1RmPoint>[];
                    if (points.length < 2) {
                      return const Padding(
                        padding: EdgeInsets.only(top: 40),
                        child: EmptyState(
                          title: 'Not enough data',
                          subtitle: 'Log this exercise in at least two sessions to see a trend.',
                          icon: Icons.show_chart,
                        ),
                      );
                    }
                    final best = points.reduce((a, b) => a.valueKg >= b.valueKg ? a : b);
                    final latest = points.last;
                    final delta = deltaKg(points);
                    final minDate = points.first.date;
                    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(child: StatCard(label: 'Best e1RM (kg)', value: trimZero(best.valueKg))),
                        const SizedBox(width: 8),
                        Expanded(
                            child: StatCard(
                                label: 'Change (kg)',
                                value: '${delta >= 0 ? '+' : ''}${trimZero(delta)}')),
                      ]),
                      const SizedBox(height: 8),
                      StatCard(label: 'Latest session e1RM (kg)', value: trimZero(latest.valueKg)),
                      const SizedBox(height: 20),
                      Card(
                        color: scheme.surfaceContainerLow,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(8, 24, 24, 8),
                          child: SizedBox(
                            height: 220,
                            child: LineChart(
                              LineChartData(
                                minY: (points.map((p) => p.valueKg).reduce((a, b) => a < b ? a : b) * 0.96),
                                maxY: (points.map((p) => p.valueKg).reduce((a, b) => a > b ? a : b) * 1.04),
                                titlesData: FlTitlesData(
                                  rightTitles: const AxisTitles(),
                                  topTitles: const AxisTitles(),
                                  bottomTitles: AxisTitles(
                                    sideTitles: SideTitles(
                                      showTitles: true,
                                      reservedSize: 28,
                                      interval: (points.length / 4).ceilToDouble().clamp(1, 99),
                                      getTitlesWidget: (value, meta) {
                                        final idx = value.toInt();
                                        if (idx < 0 || idx >= points.length) return const SizedBox();
                                        return Padding(
                                          padding: const EdgeInsets.only(top: 6),
                                          child: Text(
                                            '${DateTime.fromMillisecondsSinceEpoch(points[idx].date).month}/'
                                            '${DateTime.fromMillisecondsSinceEpoch(points[idx].date).day}',
                                            style: const TextStyle(fontSize: 10),
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                ),
                                gridData: const FlGridData(show: false),
                                borderData: FlBorderData(show: false),
                                lineBarsData: [
                                  LineChartBarData(
                                    isCurved: true,
                                    curveSmoothness: 0.25,
                                    color: scheme.primary,
                                    barWidth: 3,
                                    dotData: const FlDotData(show: true),
                                    spots: [
                                      for (var i = 0; i < points.length; i++)
                                        FlSpot(i.toDouble(), points[i].valueKg)
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Estimated 1RM (Epley), one point per session, in kg. First session: '
                        '${formatDate(minDate)}',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ]);
                  },
                ),
              ],
            ),
    );
  }
}
