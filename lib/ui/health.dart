import 'dart:io';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../health/models.dart';
import '../health/service.dart';
import 'widgets.dart';

class HealthDataScreen extends StatefulWidget {
  const HealthDataScreen({super.key});

  @override
  State<HealthDataScreen> createState() => _HealthDataScreenState();
}

class _HealthDataScreenState extends State<HealthDataScreen> {
  int _days = 14;
  bool _busy = false;
  String? _error;

  Future<
      ({
        Map<String, dynamic> overview,
        Map<String, dynamic> status,
        List<HealthDayStat> sleep,
        List<HealthDayStat> resting,
        List<HealthDayStat> steps,
        List<HealthDayStat> heart,
      })> _load(HealthService service) async {
    final now = DateTime.now();
    final from = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: _days - 1));
    final to =
        DateTime(now.year, now.month, now.day).add(const Duration(days: 1));
    final fromMs = from.millisecondsSinceEpoch;
    final toMs = to.millisecondsSinceEpoch;
    return (
      overview: await service.repository.overview(from: fromMs, to: toMs),
      status: await service.status(),
      sleep:
          await service.repository.daily(type: 'SLEEP', from: fromMs, to: toMs),
      resting: await service.repository
          .daily(type: 'RESTING_HEART_RATE', from: fromMs, to: toMs),
      steps:
          await service.repository.daily(type: 'STEPS', from: fromMs, to: toMs),
      heart: await service.repository
          .daily(type: 'HEART_RATE', from: fromMs, to: toMs),
    );
  }

  Future<void> _sync(HealthService service) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await service.syncNow();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connect(HealthService service) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await service.connect(categories: service.categories);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<HealthService>();
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final enabled = service.enabled;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Body data'),
        actions: [
          if (enabled)
            IconButton(
              tooltip: 'Sync now',
              onPressed: _busy ? null : () => _sync(service),
              icon: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.sync),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const ScreenIntro(
            eyebrow: 'HEALTH CONNECT',
            title: 'Your body, on your device.',
            subtitle:
                'Sleep, heart rate, activity and more — imported from Health Connect and shared only with your coach.',
          ),
          const SizedBox(height: 20),
          if (!enabled) ...[
            Card(
              color: scheme.surfaceContainerLow,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Connect Health Connect', style: t.titleMedium),
                    const SizedBox(height: 8),
                    Text(
                      'Compounder reads the health data you approve on this Android device. '
                      'Nothing is uploaded except the summaries you ask your coach about.',
                      style: t.bodyMedium
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _busy ? null : () => _connect(service),
                      icon: const Icon(Icons.link),
                      label: const Text('Connect'),
                    ),
                  ],
                ),
              ),
            ),
          ] else
            FutureBuilder(
              future: _load(service),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                      child: Padding(
                          padding: EdgeInsets.all(40),
                          child: CircularProgressIndicator()));
                }
                if (snapshot.hasError) {
                  return EmptyState(
                    title: 'Could not read health data',
                    subtitle: snapshot.error.toString(),
                    icon: Icons.error_outline,
                  );
                }
                final data = snapshot.data!;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(children: [
                      Expanded(
                        child: SegmentedButton<int>(
                          segments: const [
                            ButtonSegment(value: 7, label: Text('7d')),
                            ButtonSegment(value: 14, label: Text('14d')),
                            ButtonSegment(value: 30, label: Text('30d')),
                          ],
                          selected: {_days},
                          onSelectionChanged: (s) =>
                              setState(() => _days = s.first),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 16),
                    _syncCard(context, service, data.status),
                    const SizedBox(height: 16),
                    _sleepCard(context, data.overview, data.sleep),
                    const SizedBox(height: 16),
                    _heartCard(
                        context, data.overview, data.heart, data.resting),
                    const SizedBox(height: 16),
                    _activityCard(context, data.overview, data.steps),
                    const SizedBox(height: 16),
                    _bodyCard(context, data.overview),
                    const SizedBox(height: 16),
                    _metricsCard(context, data.status),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: TextStyle(color: scheme.error)),
                    ],
                  ],
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _syncCard(BuildContext context, HealthService service,
      Map<String, dynamic> status) {
    final scheme = Theme.of(context).colorScheme;
    final last = status['lastSync'] as String?;
    final err = status['lastError'] as String?;
    return Card(
      color: scheme.surfaceContainerLow,
      child: ListTile(
        leading: Icon(service.syncing ? Icons.sync : Icons.health_and_safety,
            color: scheme.primary),
        title: Text(last == null
            ? 'Not synced yet'
            : 'Last sync ${last.replaceFirst('T', ' ').split('.').first}'),
        subtitle: Text(err ??
            'Connected to Health Connect. Pulls new data when you open the app.'),
        trailing: service.syncing
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2))
            : IconButton(
                icon: const Icon(Icons.sync), onPressed: () => _sync(service)),
      ),
    );
  }

  Widget _sleepCard(BuildContext context, Map<String, dynamic> overview,
      List<HealthDayStat> sleep) {
    final scheme = Theme.of(context).colorScheme;
    final sleepData = overview['sleep'] as Map<String, dynamic>?;
    final last = sleepData?['lastNight'] as Map<String, dynamic>?;
    return Card(
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.bedtime, color: scheme.primary),
              const SizedBox(width: 8),
              Text('Sleep', style: Theme.of(context).textTheme.titleMedium),
            ]),
            const SizedBox(height: 8),
            if (last == null)
              const Text('No sleep data in this range.')
            else
              Wrap(spacing: 16, runSpacing: 8, children: [
                _stat('Last night', '${last['asleepMinutes'] ?? '—'} min'),
                _stat('Bedtime', '${last['bedtime'] ?? '—'}'),
                _stat('Wake', '${last['wake'] ?? '—'}'),
                _stat('Efficiency', '${last['efficiencyPercent'] ?? '—'}%'),
                _stat('Deep',
                    '${(last['stages'] as Map?)?['SLEEP_DEEP'] ?? 0} min'),
                _stat('REM',
                    '${(last['stages'] as Map?)?['SLEEP_REM'] ?? 0} min'),
              ]),
            const SizedBox(height: 16),
            if (sleep.isNotEmpty)
              SizedBox(
                height: 120,
                child: BarChart(
                  BarChartData(
                    barGroups: [
                      for (var i = 0; i < sleep.length; i++)
                        BarChartGroupData(x: i, barRods: [
                          BarChartRodData(
                              toY: sleep[i].sum,
                              width: 8,
                              borderRadius: BorderRadius.circular(3),
                              color: scheme.primary),
                        ]),
                    ],
                    titlesData: const FlTitlesData(show: false),
                    gridData: const FlGridData(show: false),
                    borderData: FlBorderData(show: false),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _heartCard(BuildContext context, Map<String, dynamic> overview,
      List<HealthDayStat> heart, List<HealthDayStat> resting) {
    final scheme = Theme.of(context).colorScheme;
    final heartData = overview['heart'] as Map<String, dynamic>?;
    final restingLatest =
        heartData?['restingHeartRate'] as Map<String, dynamic>?;
    return Card(
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.favorite, color: scheme.primary),
              const SizedBox(width: 8),
              Text('Heart', style: Theme.of(context).textTheme.titleMedium),
            ]),
            const SizedBox(height: 8),
            Wrap(spacing: 16, runSpacing: 8, children: [
              _stat(
                  'Resting HR',
                  restingLatest == null
                      ? '—'
                      : '${restingLatest['value']} bpm'),
              _stat(
                  'Latest HR',
                  heart.isEmpty
                      ? '—'
                      : '${heart.last.avg?.round() ?? '—'} bpm'),
              _stat(
                  'HR range',
                  heart.isEmpty
                      ? '—'
                      : '${heart.last.min?.round()}–${heart.last.max?.round()} bpm'),
            ]),
            const SizedBox(height: 16),
            if (resting.isNotEmpty)
              SizedBox(
                height: 120,
                child: LineChart(
                  LineChartData(
                    lineBarsData: [
                      LineChartBarData(
                        spots: [
                          for (var i = 0; i < resting.length; i++)
                            FlSpot(
                                i.toDouble(), resting[i].avg ?? resting[i].sum),
                        ],
                        isCurved: true,
                        dotData: const FlDotData(show: false),
                        color: scheme.primary,
                        barWidth: 3,
                      ),
                    ],
                    titlesData: const FlTitlesData(show: false),
                    gridData: const FlGridData(show: false),
                    borderData: FlBorderData(show: false),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _activityCard(BuildContext context, Map<String, dynamic> overview,
      List<HealthDayStat> steps) {
    final scheme = Theme.of(context).colorScheme;
    final activity = overview['activity'] as Map<String, dynamic>?;
    return Card(
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.directions_walk, color: scheme.primary),
              const SizedBox(width: 8),
              Text('Activity', style: Theme.of(context).textTheme.titleMedium),
            ]),
            const SizedBox(height: 8),
            Wrap(spacing: 16, runSpacing: 8, children: [
              _stat('Steps', '${activity?['stepsTotal'] ?? '—'}'),
              _stat('Distance', '${activity?['distanceMeters'] ?? '—'} m'),
              _stat('Active kcal', '${activity?['activeCalories'] ?? '—'}'),
              _stat('Workouts', '${activity?['workoutCount'] ?? 0}'),
            ]),
            const SizedBox(height: 16),
            if (steps.isNotEmpty)
              SizedBox(
                height: 120,
                child: BarChart(
                  BarChartData(
                    barGroups: [
                      for (var i = 0; i < steps.length; i++)
                        BarChartGroupData(x: i, barRods: [
                          BarChartRodData(
                              toY: steps[i].sum,
                              width: 8,
                              borderRadius: BorderRadius.circular(3),
                              color: scheme.tertiary),
                        ]),
                    ],
                    titlesData: const FlTitlesData(show: false),
                    gridData: const FlGridData(show: false),
                    borderData: FlBorderData(show: false),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _bodyCard(BuildContext context, Map<String, dynamic> overview) {
    final scheme = Theme.of(context).colorScheme;
    final body = overview['body'] as Map<String, dynamic>?;
    final vitals = overview['vitals'] as Map<String, dynamic>?;
    Widget? latest(Map<String, dynamic>? m, String label, String unit) {
      if (m == null) return null;
      return _stat(label, '${m['value'] ?? '—'} $unit');
    }

    final items = <Widget>[
      for (final item in [
        latest(body?['weightKg'] as Map<String, dynamic>?, 'Weight', 'kg'),
        latest(
            body?['bodyFatPercent'] as Map<String, dynamic>?, 'Body fat', '%'),
        latest(body?['leanMassKg'] as Map<String, dynamic>?, 'Lean mass', 'kg'),
        latest(vitals?['bloodOxygen'] as Map<String, dynamic>?, 'SpO2', '%'),
        latest(vitals?['respiratoryRate'] as Map<String, dynamic>?, 'Resp.',
            '/min'),
        latest(
            vitals?['bodyTemperatureC'] as Map<String, dynamic>?, 'Temp', '°C'),
        latest(
            vitals?['systolic'] as Map<String, dynamic>?, 'Systolic', 'mmHg'),
        latest(
            vitals?['diastolic'] as Map<String, dynamic>?, 'Diastolic', 'mmHg'),
        latest(vitals?['bloodGlucose'] as Map<String, dynamic>?, 'Glucose',
            'mg/dL'),
      ])
        if (item != null) item,
    ];
    return Card(
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.monitor_heart, color: scheme.primary),
              const SizedBox(width: 8),
              Text('Body & vitals',
                  style: Theme.of(context).textTheme.titleMedium),
            ]),
            const SizedBox(height: 8),
            if (items.isEmpty)
              const Text('No body or vital measurements in this range.')
            else
              Wrap(spacing: 16, runSpacing: 8, children: items),
          ],
        ),
      ),
    );
  }

  Widget _metricsCard(BuildContext context, Map<String, dynamic> status) {
    final scheme = Theme.of(context).colorScheme;
    final available = (status['available'] as List?) ?? [];
    return Card(
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Imported metrics',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (available.isEmpty)
              const Text('Nothing imported yet.')
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final m in available)
                    Chip(label: Text('${m['label']} (${m['records'] ?? 0})')),
                ],
              ),
            const SizedBox(height: 12),
            Text(
              'Only the summaries you ask your coach about are sent to your AI endpoint. '
              'You can revoke access any time in Health Connect settings.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(String label, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 12)),
          Text(value,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        ],
      );
}

class HealthSummaryCard extends StatelessWidget {
  const HealthSummaryCard({super.key});

  @override
  Widget build(BuildContext context) {
    if (!Platform.isAndroid) return const SizedBox.shrink();
    final service = context.watch<HealthService>();
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    if (!service.enabled) {
      return Card(
        color: scheme.surfaceContainerLow,
        child: ListTile(
          leading: Icon(Icons.health_and_safety, color: scheme.primary),
          title: const Text('Connect Health Connect'),
          subtitle: const Text(
              'Bring sleep, heart rate and activity into your coach.'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const HealthDataScreen())),
        ),
      );
    }
    return FutureBuilder<Map<String, dynamic>>(
      future: service.todaySummary(),
      builder: (context, snap) {
        final data = snap.data;
        final sleep = data?['sleep'] as Map<String, dynamic>?;
        final last = sleep?['lastNight'] as Map<String, dynamic>?;
        final heart = data?['heart'] as Map<String, dynamic>?;
        final resting = heart?['restingHeartRate'] as Map<String, dynamic>?;
        final activity = data?['activity'] as Map<String, dynamic>?;
        final steps = (activity?['stepsDaily'] as List?)?.isNotEmpty == true
            ? (activity!['stepsDaily'] as List).last
            : null;
        return Card(
          color: scheme.surfaceContainerLow,
          child: ListTile(
            leading: Icon(Icons.health_and_safety, color: scheme.primary),
            title: Text('Body today', style: t.titleMedium),
            subtitle: Text([
              if (last != null) 'Sleep ${last['asleepMinutes']} min',
              if (resting != null) 'Resting HR ${resting['value']} bpm',
              if (steps is Map) 'Steps ${steps['value']}',
              if (last == null && resting == null && steps == null) 'Syncing…',
            ].join(' · ')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const HealthDataScreen())),
          ),
        );
      },
    );
  }
}

class HealthRationaleScreen extends StatelessWidget {
  const HealthRationaleScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('How health data is used')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const ScreenIntro(
            eyebrow: 'PRIVACY',
            title: 'Your health data stays yours.',
            subtitle:
                'Compounder reads only what you approve in Health Connect and keeps it on this device.',
          ),
          const SizedBox(height: 20),
          Text('What Compounder reads', style: t.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Sleep stages, heart rate, resting heart rate, HRV, steps, distance, calories, workouts, '
            'body measurements and vitals — only the categories you enable in Settings. Compounder '
            'never writes to Health Connect.',
            style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          Text('Where it goes', style: t.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Imported records are stored in the local Compounder database. When you ask the coach a '
            'question, summarized health data is sent to the AI endpoint you configured in Settings. '
            'No Google account, cloud sync, analytics or ads are involved.',
            style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          Text('Your controls', style: t.titleMedium),
          const SizedBox(height: 8),
          Text(
            'You can revoke any permission in Health Connect → App permissions, disconnect the '
            'integration in Compounder Settings, or delete all imported health records without '
            'affecting the original data in Health Connect.',
            style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          Text(
            'Raw health samples are kept for two years; older data is compacted into permanent '
            'daily summaries. Backups include the imported health data.',
            style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
