import 'package:flutter/material.dart';

import 'habits.dart';
import 'heatmap.dart';
import 'planner.dart';
import 'settings.dart';

/// Exposes the shell's drawer opener to the tab screens so the hamburger can
/// live in each tab's AppBar without threading a callback through five
/// constructors.
class ShellNav extends InheritedWidget {
  final VoidCallback openDrawer;

  /// Switches the shell's tab. Nullable so widget tests can mount a tab with
  /// only [openDrawer]; the app always supplies it.
  final ValueChanged<int>? selectTab;

  /// Whether the tab wrapped by this widget is the one currently on screen.
  ///
  /// The shell keeps every tab mounted in an [IndexedStack], so a tab cannot
  /// infer visibility from its own lifecycle. Tabs that poll the store use
  /// this to skip work while they are off-screen. Defaults to true so a tab
  /// mounted on its own (widget tests, a future single-tab route) still loads.
  final bool visible;

  const ShellNav({
    super.key,
    required this.openDrawer,
    this.selectTab,
    this.visible = true,
    required super.child,
  });

  static ShellNav of(BuildContext context) {
    final nav = context.dependOnInheritedWidgetOfExactType<ShellNav>();
    assert(nav != null, 'ShellNav not found above this widget');
    return nav!;
  }

  @override
  bool updateShouldNotify(ShellNav oldWidget) =>
      openDrawer != oldWidget.openDrawer ||
      selectTab != oldWidget.selectTab ||
      visible != oldWidget.visible;
}

/// Shell tab indices.
///
/// The bottom bar shows [tabHome]..[tabCoach] in that order. [tabMind] is
/// drawer-only: it stays mounted in the shell's IndexedStack at its own index
/// so its state survives navigation, but it has no bottom-bar destination.
const int tabHome = 0;
const int tabFitness = 1;
const int tabMacros = 2;
const int tabWealth = 3;
const int tabCoach = 4;
const int tabMind = 5;

/// Number of tabs the shell keeps mounted.
const int shellTabCount = 6;

/// A single destination listed in the app drawer.
class DrawerDestination {
  final IconData icon;
  final String label;
  const DrawerDestination(this.icon, this.label);
}

/// Shared navigation drawer for every shell tab plus Settings.
///
/// Owned by the shell's [Scaffold] so there is exactly one drawer instance.
/// Standard [Drawer] behaviour keeps it closed until the hamburger is tapped.
class AppDrawer extends StatelessWidget {
  /// Drawer order matches the shell's IndexedStack indices exactly, so the
  /// `selected` marker and the tab switch cannot drift apart.
  static const destinations = <DrawerDestination>[
    DrawerDestination(Icons.home, 'Home'),
    DrawerDestination(Icons.fitness_center, 'Fitness'),
    DrawerDestination(Icons.restaurant, 'Macros'),
    DrawerDestination(Icons.insights, 'Wealth'),
    DrawerDestination(Icons.support_agent, 'Coach'),
    DrawerDestination(Icons.psychology, 'Mind'),
  ];

  final int currentIndex;
  final ValueChanged<int> onSelectTab;

  const AppDrawer({
    super.key,
    required this.currentIndex,
    required this.onSelectTab,
  });

  void _selectTab(BuildContext context, int index) {
    // Safe to pop then act without awaiting: Navigator.pop() is synchronous and
    // removes the drawer's LocalHistoryEntry before the next tap can land, and
    // the route transition's IgnorePointer blocks taps mid-animation.
    Navigator.of(context).pop();
    onSelectTab(index);
  }

  void _openSettings(BuildContext context) {
    // Same invariant as _selectTab: pop is synchronous, so the push below
    // cannot race a second tap.
    Navigator.of(context).pop();
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
  }

  void _openHabits(BuildContext context) {
    // Same invariant as _openSettings: pop is synchronous, so the push below
    // cannot race a second tap.
    Navigator.of(context).pop();
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const HabitsScreen()));
  }

  void _openActivity(BuildContext context) {
    Navigator.of(context).pop();
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const HeatmapScreen()));
  }

  void _openPlanner(BuildContext context) {
    // Same invariant as _openSettings: pop is synchronous, so the push below
    // cannot race a second tap.
    Navigator.of(context).pop();
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const PlannerScreen()));
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
                // The drawer is a fixed 304dp wide, so the label must be
                // constrained: at accessibility text scales (Android's font
                // slider reaches 2.0) an unconstrained Text overflows the Row.
                Expanded(
                  child: Text(
                    'Compounder',
                    style: t.titleLarge,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
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
                // The tint alone is a colour-only cue (WCAG 1.4.1); the check
                // mark gives sighted users a non-colour indicator of the
                // current tab. Screen readers already get `selected`.
                trailing: i == currentIndex
                    ? Icon(Icons.check, color: scheme.onSecondaryContainer)
                    : null,
                onTap: () => _selectTab(context, i),
              ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.event_note),
              title: const Text('Day planner'),
              onTap: () => _openPlanner(context),
            ),
            ListTile(
              leading: const Icon(Icons.grid_on),
              title: const Text('Activity'),
              onTap: () => _openActivity(context),
            ),
            ListTile(
              leading: const Icon(Icons.checklist_rtl),
              title: const Text('Habits'),
              onTap: () => _openHabits(context),
            ),
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
