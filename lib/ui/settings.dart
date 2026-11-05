import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../data/store.dart';
import '../domain/domain.dart';
import '../health/categories.dart';
import '../health/service.dart';
import '../services/backup.dart';
import '../services/notify.dart';
import 'health.dart';
import 'widgets.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController baseUrl;
  late final TextEditingController apiKey;
  late final TextEditingController model;
  late final TextEditingController goalCal;
  late final TextEditingController goalProtein;
  late final TextEditingController goalCarbs;
  late final TextEditingController goalFat;
  bool showApiKey = false;
  late Set<HealthCategory> healthCategories;
  late bool healthAutoSync;
  late bool healthHistory;
  HealthAvailability? healthAvailability;
  bool healthBusy = false;

  @override
  void initState() {
    super.initState();
    final store = context.read<AppStore>();
    final health = context.read<HealthService>();
    healthCategories = {...health.categories};
    healthAutoSync = health.autoSync;
    healthHistory = health.historyRequested;
    health.availability().then((value) {
      if (mounted) setState(() => healthAvailability = value);
    });
    final ai = store.ai;
    final goals = store.goals;
    baseUrl = TextEditingController(text: ai.baseUrl);
    apiKey = TextEditingController(text: ai.apiKey);
    model = TextEditingController(text: ai.model);
    goalCal = TextEditingController(text: goals.calories.round().toString());
    goalProtein = TextEditingController(text: goals.protein.round().toString());
    goalCarbs = TextEditingController(text: goals.carbs.round().toString());
    goalFat = TextEditingController(text: goals.fat.round().toString());
  }

  @override
  void dispose() {
    for (final c in [
      baseUrl,
      apiKey,
      model,
      goalCal,
      goalProtein,
      goalCarbs,
      goalFat
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final health = context.watch<HealthService>();
    final notify = context.read<NotifyService>();
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;

    void snack(String text) => ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text)));

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const ScreenIntro(
            eyebrow: 'MAKE IT YOURS',
            title: 'Your life, your settings.',
            subtitle: 'Bring your own AI, keep your own data.',
          ),
          const SizedBox(height: 20),
          const SectionHeader('Bring your own AI'),
          const SizedBox(height: 8),
          Card(
            color: scheme.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(children: [
                Text(
                    'Your connection powers meal photo analysis and the coach. '
                    'Data is sent only to this endpoint — never anywhere else.',
                    style:
                        t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 12),
                TextField(
                    controller: baseUrl,
                    decoration: const InputDecoration(
                        labelText: 'Base URL', hintText: 'http://…/v1')),
                const SizedBox(height: 12),
                TextField(
                  controller: apiKey,
                  obscureText: !showApiKey,
                  decoration: InputDecoration(
                    labelText: 'API token',
                    suffixIcon: IconButton(
                      icon: Icon(
                          showApiKey ? Icons.visibility_off : Icons.visibility),
                      onPressed: () => setState(() => showApiKey = !showApiKey),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                    controller: model,
                    decoration: const InputDecoration(
                        labelText: 'Model',
                        hintText: 'any vision + tool-calling model')),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () async {
                    await store.saveAi(AiSettings(
                      baseUrl: baseUrl.text.trim(),
                      apiKey: apiKey.text.trim(),
                      model: model.text.trim(),
                    ));
                    if (context.mounted) snack('AI settings saved');
                  },
                  child: const Text('Save AI settings'),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 16),
          const SectionHeader('Daily goals'),
          const SizedBox(height: 8),
          Card(
            color: scheme.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(children: [
                Row(children: [
                  Expanded(
                      child: TextField(
                          controller: goalCal,
                          keyboardType: TextInputType.number,
                          decoration:
                              const InputDecoration(labelText: 'kcal'))),
                  const SizedBox(width: 8),
                  Expanded(
                      child: TextField(
                          controller: goalProtein,
                          keyboardType: TextInputType.number,
                          decoration:
                              const InputDecoration(labelText: 'Protein g'))),
                  const SizedBox(width: 8),
                  Expanded(
                      child: TextField(
                          controller: goalCarbs,
                          keyboardType: TextInputType.number,
                          decoration:
                              const InputDecoration(labelText: 'Carbs g'))),
                  const SizedBox(width: 8),
                  Expanded(
                      child: TextField(
                          controller: goalFat,
                          keyboardType: TextInputType.number,
                          decoration:
                              const InputDecoration(labelText: 'Fat g'))),
                ]),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () async {
                    await store.saveGoals(MacroGoals(
                      calories: double.tryParse(goalCal.text) ?? 2000,
                      protein: double.tryParse(goalProtein.text) ?? 150,
                      carbs: double.tryParse(goalCarbs.text) ?? 250,
                      fat: double.tryParse(goalFat.text) ?? 70,
                    ));
                    if (context.mounted) snack('Goals saved');
                  },
                  child: const Text('Save goals'),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 16),
          const SectionHeader('Training'),
          const SizedBox(height: 8),
          Card(
            color: scheme.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(children: [
                Row(children: [
                  Expanded(
                    child: ChoiceChip(
                      label: const Text('Kilograms (kg)'),
                      selected: store.unit == WeightUnit.kg,
                      onSelected: (_) => store.setUnit(WeightUnit.kg),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ChoiceChip(
                      label: const Text('Pounds (lb)'),
                      selected: store.unit == WeightUnit.lb,
                      onSelected: (_) => store.setUnit(WeightUnit.lb),
                    ),
                  ),
                ]),
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(
                      child: Text(
                          'Default rest between sets: ${store.restSeconds}s',
                          style: t.bodyMedium)),
                  SizedBox(
                    width: 180,
                    child: Slider(
                      value: store.restSeconds.toDouble(),
                      max: 600,
                      divisions: 39,
                      label: '${store.restSeconds}s',
                      onChanged: (v) => store.setRestSeconds(v.round()),
                    ),
                  ),
                ]),
              ]),
            ),
          ),
          const SizedBox(height: 16),
          const SectionHeader('Health data (Android)'),
          const SizedBox(height: 8),
          Card(
            color: scheme.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Read sleep, heart rate, activity, body and vitals from Google Health Connect. '
                      'The data stays in the local database; only the summaries you ask the coach about '
                      'are sent to your AI endpoint.',
                      style: t.bodyMedium
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      switch (healthAvailability) {
                        null => 'Checking Health Connect…',
                        HealthAvailability.unsupported =>
                          'Health Connect is not available on this device.',
                        HealthAvailability.installRequired =>
                          'Health Connect needs to be installed or updated.',
                        HealthAvailability.available =>
                          'Health Connect is available.',
                      },
                      style: t.bodySmall,
                    ),
                    if (healthAvailability ==
                        HealthAvailability.installRequired) ...[
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: healthBusy
                            ? null
                            : () async {
                                await health.installHealthConnect();
                                final value = await health.availability();
                                if (mounted) {
                                  setState(() => healthAvailability = value);
                                }
                              },
                        icon: const Icon(Icons.download),
                        label: const Text('Install Health Connect'),
                      ),
                    ],
                    const SizedBox(height: 12),
                    for (final category in HealthCategory.values)
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: healthCategories.contains(category),
                        title: Text(category.label),
                        subtitle: Text(category.description),
                        onChanged: healthBusy
                            ? null
                            : (value) async {
                                setState(() {
                                  if (value == true) {
                                    healthCategories.add(category);
                                  } else {
                                    healthCategories.remove(category);
                                  }
                                });
                                await health.saveCategories(healthCategories);
                              },
                      ),
                    SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Import full history'),
                      subtitle: const Text(
                          'Ask Health Connect for data older than 30 days.'),
                      value: healthHistory,
                      onChanged: healthBusy
                          ? null
                          : (value) async {
                              setState(() => healthHistory = value);
                              if (value && health.enabled) {
                                try {
                                  await health.requestHistoryAccess();
                                  if (context.mounted) {
                                    snack('Full history access granted');
                                  }
                                } catch (e) {
                                  if (mounted) {
                                    setState(() => healthHistory = false);
                                  }
                                  await health.setHistoryRequested(false);
                                  if (context.mounted) snack(e.toString());
                                }
                              } else if (!value) {
                                await health.setHistoryRequested(false);
                              }
                            },
                    ),
                    SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Sync when the app opens'),
                      subtitle: const Text(
                          'No background worker; syncs on launch/resume and on demand.'),
                      value: healthAutoSync,
                      onChanged: healthBusy
                          ? null
                          : (value) async {
                              setState(() => healthAutoSync = value);
                              await health.setAutoSync(value);
                            },
                    ),
                    const SizedBox(height: 8),
                    if (!health.enabled)
                      FilledButton.icon(
                        onPressed: healthBusy ||
                                healthAvailability !=
                                    HealthAvailability.available
                            ? null
                            : () async {
                                setState(() => healthBusy = true);
                                try {
                                  await health.connect(
                                    categories: healthCategories,
                                    requestHistory: healthHistory,
                                  );
                                  if (context.mounted) {
                                    snack('Health Connect connected');
                                  }
                                } catch (e) {
                                  if (context.mounted) snack(e.toString());
                                } finally {
                                  if (mounted) {
                                    setState(() => healthBusy = false);
                                  }
                                }
                              },
                        icon: const Icon(Icons.link),
                        label: const Text('Connect Health Connect'),
                      )
                    else ...[
                      FutureBuilder<DateTime?>(
                        future: health.repository.lastSync(),
                        builder: (context, snapshot) => Text(
                          snapshot.data == null
                              ? 'Not synced yet.'
                              : 'Last sync: ${formatDateTime(snapshot.data!.millisecondsSinceEpoch)}',
                          style: t.bodySmall,
                        ),
                      ),
                      if (health.lastError != null) ...[
                        const SizedBox(height: 4),
                        Text(health.lastError!,
                            style: t.bodySmall?.copyWith(color: scheme.error)),
                      ],
                      const SizedBox(height: 8),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        FilledButton.icon(
                          onPressed: healthBusy || health.syncing
                              ? null
                              : () async {
                                  setState(() => healthBusy = true);
                                  try {
                                    final result = await health.syncNow();
                                    if (context.mounted) {
                                      snack(result.ok
                                          ? 'Synced ${result.records} health records'
                                          : 'Synced with ${result.errors.length} error(s)');
                                    }
                                  } catch (e) {
                                    if (context.mounted) snack(e.toString());
                                  } finally {
                                    if (mounted) {
                                      setState(() => healthBusy = false);
                                    }
                                  }
                                },
                          icon: const Icon(Icons.sync),
                          label: const Text('Sync now'),
                        ),
                        OutlinedButton.icon(
                          onPressed: healthBusy
                              ? null
                              : () async {
                                  setState(() => healthBusy = true);
                                  try {
                                    await health.connect(
                                      categories: healthCategories,
                                      requestHistory: healthHistory,
                                    );
                                    if (context.mounted) {
                                      snack('Health permissions updated');
                                    }
                                  } catch (e) {
                                    if (context.mounted) snack(e.toString());
                                  } finally {
                                    if (mounted) {
                                      setState(() => healthBusy = false);
                                    }
                                  }
                                },
                          icon: const Icon(Icons.lock_open),
                          label: const Text('Update permissions'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => const HealthDataScreen())),
                          icon: const Icon(Icons.monitor_heart),
                          label: const Text('View data'),
                        ),
                      ]),
                      const SizedBox(height: 8),
                      Row(children: [
                        TextButton.icon(
                          onPressed: healthBusy
                              ? null
                              : () async {
                                  await health.disconnect();
                                  if (context.mounted) {
                                    snack('Health Connect disconnected');
                                  }
                                },
                          icon: const Icon(Icons.link_off),
                          label: const Text('Disconnect'),
                        ),
                        TextButton.icon(
                          onPressed: healthBusy
                              ? null
                              : () async {
                                  final ok = await showDialog<bool>(
                                    context: context,
                                    builder: (context) => AlertDialog(
                                      title: const Text(
                                          'Delete imported health data?'),
                                      content: const Text(
                                          'This removes every Health Connect record imported into Compounder. '
                                          'Your Health Connect data is not affected.'),
                                      actions: [
                                        TextButton(
                                            onPressed: () =>
                                                Navigator.pop(context, false),
                                            child: const Text('Cancel')),
                                        FilledButton(
                                            onPressed: () =>
                                                Navigator.pop(context, true),
                                            child: const Text('Delete')),
                                      ],
                                    ),
                                  );
                                  if (ok == true) {
                                    await health.deleteAllData();
                                    if (context.mounted) {
                                      snack('Imported health data deleted');
                                    }
                                  }
                                },
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('Delete imported data'),
                        ),
                      ]),
                    ],
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const HealthRationaleScreen())),
                      icon: const Icon(Icons.privacy_tip_outlined),
                      label: const Text('How health data is used'),
                    ),
                  ]),
            ),
          ),
          const SizedBox(height: 16),
          const SectionHeader('Daily coach'),
          const SizedBox(height: 8),
          Card(
            color: scheme.surfaceContainerLow,
            child: Column(children: [
              SwitchListTile(
                title: const Text('A daily check-in'),
                subtitle: Text(
                    'One coach message across workouts, meals, money and mood. Scheduled on this device — no Google services.'),
                value: store.coachEnabled,
                onChanged: (v) async {
                  await store.setCoach(enabled: v);
                  await notify.rescheduleDaily(store);
                },
              ),
              ListTile(
                title: const Text('Delivery time'),
                trailing: Text(
                    '${store.coachMinutes ~/ 60}:${(store.coachMinutes % 60).toString().padLeft(2, '0')}',
                    style: t.titleMedium?.copyWith(color: scheme.primary)),
                onTap: () async {
                  final picked = await showTimePicker(
                    context: context,
                    initialTime: TimeOfDay(
                        hour: store.coachMinutes ~/ 60,
                        minute: store.coachMinutes % 60),
                  );
                  if (picked != null) {
                    await store.setCoach(
                        minutes: picked.hour * 60 + picked.minute);
                    await notify.rescheduleDaily(store);
                  }
                },
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: OutlinedButton.icon(
                  icon:
                      const Icon(Icons.notifications_active_outlined, size: 18),
                  label: const Text('Send test notification'),
                  onPressed: () async {
                    await notify.testNotification(store);
                    if (context.mounted) snack('Coach notification sent');
                  },
                ),
              ),
            ]),
          ),
          const SizedBox(height: 16),
          const SectionHeader('Reminders'),
          const SizedBox(height: 8),
          Card(
            color: scheme.surfaceContainerLow,
            child: Column(children: [
              if (store.reminders.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text(
                      'No pending reminders. Ask your coach to set one.',
                      style: TextStyle(fontSize: 13)),
                )
              else
                for (final r in store.reminders)
                  ListTile(
                    leading: const Icon(Icons.notifications_outlined),
                    title: Text(r.text),
                    subtitle: Text(formatDateTime(r.dueAt)),
                    trailing: IconButton(
                      icon: Icon(Icons.delete_outline, color: scheme.outline),
                      onPressed: () async {
                        await notify.cancelReminder(r.id);
                        await store.deleteReminder(r.id);
                      },
                    ),
                  ),
            ]),
          ),
          const SizedBox(height: 16),
          const SectionHeader('Your data'),
          const SizedBox(height: 8),
          Card(
            color: scheme.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(children: [
                Text(
                    'Everything lives on this device. Export one JSON backup, or restore from one.',
                    style:
                        t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 12),
                FilledButton.icon(
                  icon: const Icon(Icons.ios_share),
                  label: const Text('Export backup'),
                  onPressed: () async {
                    try {
                      final path = await BackupService.export(store);
                      await Share.shareXFiles([XFile(path)],
                          subject: 'Compounder backup');
                    } catch (e) {
                      snack('Export failed: $e');
                    }
                  },
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48)),
                  icon: const Icon(Icons.file_upload_outlined),
                  label: const Text('Import backup (replaces local data)'),
                  onPressed: () async {
                    final picked = await FilePicker.platform.pickFiles(
                        type: FileType.custom, allowedExtensions: ['json']);
                    final path = picked?.files.single.path;
                    if (path == null || !context.mounted) return;
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Import backup?'),
                        content: const Text(
                            'Importing replaces all workouts, meals, accounts and mind data on this device.'),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('Cancel')),
                          FilledButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('Import')),
                        ],
                      ),
                    );
                    if (ok != true) return;
                    try {
                      await BackupService.import(store, path);
                      if (context.mounted) snack('Backup imported');
                    } catch (e) {
                      if (context.mounted) snack('Import failed: $e');
                    }
                  },
                ),
              ]),
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: Text(
              'Compounder v0.3.0 · MIT · Open source, no tracking, no ads.',
              style: t.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
