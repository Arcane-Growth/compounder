import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../data/store.dart';
import '../domain/domain.dart';
import '../services/backup.dart';
import '../services/notify.dart';
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

  @override
  void initState() {
    super.initState();
    final store = context.read<AppStore>();
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
    for (final c in [baseUrl, apiKey, model, goalCal, goalProtein, goalCarbs, goalFat]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final notify = context.read<NotifyService>();
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;

    void snack(String text) =>
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

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
                Text('Your connection powers meal photo analysis and the coach. '
                    'Data is sent only to this endpoint — never anywhere else.',
                    style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 12),
                TextField(
                    controller: baseUrl,
                    decoration: const InputDecoration(labelText: 'Base URL', hintText: 'http://…/v1')),
                const SizedBox(height: 12),
                TextField(
                  controller: apiKey,
                  obscureText: !showApiKey,
                  decoration: InputDecoration(
                    labelText: 'API token',
                    suffixIcon: IconButton(
                      icon: Icon(showApiKey ? Icons.visibility_off : Icons.visibility),
                      onPressed: () => setState(() => showApiKey = !showApiKey),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                    controller: model,
                    decoration: const InputDecoration(
                        labelText: 'Model', hintText: 'any vision + tool-calling model')),
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
                          decoration: const InputDecoration(labelText: 'kcal'))),
                  const SizedBox(width: 8),
                  Expanded(
                      child: TextField(
                          controller: goalProtein,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'Protein g'))),
                  const SizedBox(width: 8),
                  Expanded(
                      child: TextField(
                          controller: goalCarbs,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'Carbs g'))),
                  const SizedBox(width: 8),
                  Expanded(
                      child: TextField(
                          controller: goalFat,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'Fat g'))),
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
                      child: Text('Default rest between sets: ${store.restSeconds}s',
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
                        hour: store.coachMinutes ~/ 60, minute: store.coachMinutes % 60),
                  );
                  if (picked != null) {
                    await store.setCoach(minutes: picked.hour * 60 + picked.minute);
                    await notify.rescheduleDaily(store);
                  }
                },
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.notifications_active_outlined, size: 18),
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
                  child: Text('No pending reminders. Ask your coach to set one.',
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
                Text('Everything lives on this device. Export one JSON backup, or restore from one.',
                    style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
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
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  icon: const Icon(Icons.file_upload_outlined),
                  label: const Text('Import backup (replaces local data)'),
                  onPressed: () async {
                    final picked = await FilePicker.platform
                        .pickFiles(type: FileType.custom, allowedExtensions: ['json']);
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
              'Compounder v0.2.0 · MIT · Open source, no tracking, no ads.',
              style: t.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
