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
    return Row(children: [
      Text(text.toUpperCase(),
          style: Theme.of(context)
              .textTheme
              .labelMedium
              ?.copyWith(color: scheme.primary)),
      const SizedBox(width: 12),
      Expanded(child: Divider(color: scheme.outlineVariant)),
    ]);
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
