import 'package:flutter/material.dart';

import 'settings.dart';

/// Exposes the shell's drawer opener to the tab screens so the hamburger can
/// live in each tab's AppBar without threading a callback through five
/// constructors.
class ShellNav extends InheritedWidget {
  final VoidCallback openDrawer;

  const ShellNav({
    super.key,
    required this.openDrawer,
    required super.child,
  });

  static ShellNav of(BuildContext context) {
    final nav = context.dependOnInheritedWidgetOfExactType<ShellNav>();
    assert(nav != null, 'ShellNav not found above this widget');
    return nav!;
  }

  @override
  bool updateShouldNotify(ShellNav oldWidget) =>
      openDrawer != oldWidget.openDrawer;
}

/// A single destination listed in the app drawer.
class DrawerDestination {
  final IconData icon;
  final String label;
  const DrawerDestination(this.icon, this.label);
}

/// Shared navigation drawer for the five shell tabs plus Settings.
///
/// Owned by the shell's [Scaffold] so there is exactly one drawer instance.
/// Standard [Drawer] behaviour keeps it closed until the hamburger is tapped.
class AppDrawer extends StatelessWidget {
  static const destinations = <DrawerDestination>[
    DrawerDestination(Icons.fitness_center, 'Fitness'),
    DrawerDestination(Icons.restaurant, 'Macros'),
    DrawerDestination(Icons.insights, 'Wealth'),
    DrawerDestination(Icons.psychology, 'Mind'),
    DrawerDestination(Icons.support_agent, 'Coach'),
  ];

  final int currentIndex;
  final ValueChanged<int> onSelectTab;

  const AppDrawer({
    super.key,
    required this.currentIndex,
    required this.onSelectTab,
  });

  void _selectTab(BuildContext context, int index) {
    Navigator.of(context).pop();
    onSelectTab(index);
  }

  void _openSettings(BuildContext context) {
    Navigator.of(context).pop();
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
              child: Row(children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.eco, size: 22, color: scheme.onPrimary),
                ),
                const SizedBox(width: 12),
                Text('Compounder', style: t.titleLarge),
              ]),
            ),
            const Divider(height: 1),
            for (var i = 0; i < destinations.length; i++)
              ListTile(
                leading: Icon(destinations[i].icon),
                title: Text(destinations[i].label),
                selected: i == currentIndex,
                selectedColor: scheme.onSecondaryContainer,
                selectedTileColor: scheme.secondaryContainer,
                onTap: () => _selectTab(context, i),
              ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.settings),
              title: const Text('Settings'),
              onTap: () => _openSettings(context),
            ),
          ],
        ),
      ),
    );
  }
}

/// AppBar leading button that opens the shell's drawer.
class DrawerMenuButton extends StatelessWidget {
  const DrawerMenuButton({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.menu),
      tooltip: 'Open menu',
      onPressed: () => ShellNav.of(context).openDrawer(),
    );
  }
}
