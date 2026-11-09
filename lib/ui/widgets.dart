import 'package:flutter/material.dart';

const _seed = Color(0xFF285441);

class CompounderTheme {
  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final scheme =
        ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
    final typography = Typography.material2021(colorScheme: scheme);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      typography: typography,
      textTheme: typography.black.apply(
        bodyColor: scheme.onSurface,
        displayColor: scheme.onSurface,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
      // Full-width primary actions are the app's default (dialogs, forms).
      // Size.fromHeight(48) has an *infinite* width, so a FilledButton placed
      // in a Row (unbounded main axis) is forced to an infinite width and the
      // row overflows — in release the overflow is clipped silently instead of
      // throwing. Any FilledButton that must sit beside another widget has to
      // override minimumSize with a finite width (see CoachApprovalCard in
      // coach.dart). test/coach_approval_layout_test.dart pins this contract.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  final String text;
  const SectionHeader(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, constraints) {
      // Reserve a fixed slice for the divider and bound the label: at
      // accessibility text scales an unconstrained label overflows the Row
      // (measured 51px at 320dp/2.0).
      final maxLabelWidth =
          constraints.maxWidth > 36 ? constraints.maxWidth - 36 : 0.0;
      return Row(children: [
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxLabelWidth),
          child: Text(
            text.toUpperCase(),
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(color: scheme.primary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: Divider(color: scheme.outlineVariant)),
      ]);
    });
  }
}

class TintedIconCircle extends StatelessWidget {
  final IconData icon;
  final Color? background, foreground;
  const TintedIconCircle(this.icon,
      {super.key, this.background, this.foreground});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: background ?? scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(icon,
          size: 22, color: foreground ?? scheme.onSecondaryContainer),
    );
  }
}

class EmptyState extends StatelessWidget {
  final String title, subtitle;
  final IconData? icon;
  const EmptyState(
      {super.key, required this.title, required this.subtitle, this.icon});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
      child: Column(children: [
        if (icon != null) ...[
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: scheme.secondaryContainer,
              borderRadius: BorderRadius.circular(28),
            ),
            child: Icon(icon, size: 32, color: scheme.onSecondaryContainer),
          ),
          const SizedBox(height: 20),
        ],
        Text(title, style: t.titleMedium, textAlign: TextAlign.center),
        const SizedBox(height: 4),
        Text(subtitle,
            style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            textAlign: TextAlign.center),
      ]),
    );
  }
}

class StatCard extends StatelessWidget {
  final String label, value;
  const StatCard({super.key, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Card(
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value, style: t.titleLarge?.copyWith(color: scheme.primary)),
          const SizedBox(height: 6),
          Text(label,
              style: t.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}

class CardRow extends StatelessWidget {
  final IconData icon;
  final String title, subtitle;
  final String? trailing;
  final Widget? trailingAction;
  final bool isThreeLine;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  const CardRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.trailingAction,
    this.isThreeLine = false,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Card(
      color: scheme.surfaceContainerLow,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        onTap: onTap,
        onLongPress: onLongPress,
        isThreeLine: isThreeLine,
        leading: TintedIconCircle(icon),
        title: Text(title, style: t.titleMedium),
        subtitle: Text(subtitle,
            style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        trailing: trailing == null && trailingAction == null
            ? Icon(Icons.chevron_right, color: scheme.primary)
            : Row(mainAxisSize: MainAxisSize.min, children: [
                if (trailing != null)
                  Text(trailing!,
                      style: t.labelLarge?.copyWith(color: scheme.primary),
                      textAlign: TextAlign.end),
                if (trailingAction != null) ...[
                  if (trailing != null) const SizedBox(width: 4),
                  trailingAction!,
                ],
              ]),
      ),
    );
  }
}

String formatDate(int millis) {
  final d = DateTime.fromMillisecondsSinceEpoch(millis);
  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec'
  ];
  return '${weekdays[d.weekday - 1]}, ${months[d.month - 1]} ${d.day}, ${d.year}';
}

String formatDateTime(int millis) {
  final d = DateTime.fromMillisecondsSinceEpoch(millis);
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec'
  ];
  return '${months[d.month - 1]} ${d.day}, ${d.year} · '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

String formatDuration(int startMs, int? endMs) {
  final total =
      ((endMs ?? DateTime.now().millisecondsSinceEpoch) - startMs) ~/ 1000;
  final m = total ~/ 60, s = total % 60;
  if (m >= 60) return '${m ~/ 60}h ${m % 60}m';
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// Prompts for a workout name. Returns null when the user cancels.
///
/// Shared by the home checklist and the fitness hub so both start a workout
/// through the same dialog.
Future<String?> askWorkoutName(BuildContext context) async {
  final controller = TextEditingController(text: 'Workout');
  try {
    return await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New workout'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('Start')),
        ],
      ),
    );
  } finally {
    // The dialog's TextField no longer needs the controller once the route is
    // gone; disposing it here avoids leaking one per "new workout" prompt.
    controller.dispose();
  }
}
