import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../health/service.dart';

import 'coach.dart';
import 'drawer.dart';
import 'fitness.dart';
import 'home.dart';
import 'macros.dart';
import 'mind.dart';
import 'wealth.dart';

class ShellScreen extends StatefulWidget {
  const ShellScreen({super.key});

  @override
  State<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends State<ShellScreen> with WidgetsBindingObserver {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  int _index = tabHome;

  /// Every tab the shell keeps mounted, in [tabHome]..[tabMind] order.
  static const _tabs = <Widget>[
    HomeTab(),
    FitnessTab(),
    MacrosTab(),
    WealthTab(),
    CoachTab(),
    MindTab(),
  ];

  // Stable callbacks: a fresh closure per build() would make ShellNav's
  // updateShouldNotify (identity comparison) fire on every tab switch and
  // rebuild every tab.
  void _openDrawer() => _scaffoldKey.currentState?.openDrawer();

  // Same stability requirement for the tab switch callback: HomeTab's pillar
  // checklist and the drawer both call it.
  void _selectTab(int i) => setState(() => _index = i);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<HealthService>().syncIfDue();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      context.read<HealthService>().syncIfDue();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      drawer: AppDrawer(
        currentIndex: _index,
        onSelectTab: _selectTab,
      ),
      body: IndexedStack(
        index: _index,
        children: [
          // Each tab gets its own ShellNav so `visible` describes that tab
          // rather than the shell: HomeTab and FitnessTab both poll the store
          // and must know whether they are the one on screen.
          for (var i = 0; i < shellTabCount; i++)
            ShellNav(
              openDrawer: _openDrawer,
              selectTab: _selectTab,
              visible: _index == i,
              child: _tabs[i],
            ),
        ],
      ),
      bottomNavigationBar: ShellBottomBar(
        // Mind is drawer-only, so no bottom-bar destination is selected while
        // it is on screen.
        selectedIndex: _index <= tabCoach ? _index : -1,
        onSelect: _selectTab,
      ),
    );
  }
}

/// The five primary destinations shown in the bottom bar.
///
/// Mind is deliberately absent: it is reachable from the drawer only. Flutter's
/// [NavigationBar] asserts `0 <= selectedIndex < destinations.length`, so it
/// cannot express "nothing selected" while a drawer-only tab is on screen; this
/// bar can, which keeps the highlight honest instead of lighting up Home.
class ShellBottomBar extends StatelessWidget {
  /// Bottom-bar order. Indices are the shell tab indices [tabHome]..[tabCoach].
  static const destinations = <DrawerDestination>[
    DrawerDestination(Icons.home, 'Home'),
    DrawerDestination(Icons.fitness_center, 'Fitness'),
    DrawerDestination(Icons.restaurant, 'Macros'),
    DrawerDestination(Icons.insights, 'Wealth'),
    DrawerDestination(Icons.support_agent, 'Coach'),
  ];

  /// The selected destination, or -1 when a drawer-only tab is showing.
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  const ShellBottomBar({
    super.key,
    required this.selectedIndex,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainer,
      elevation: 3,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              for (var i = 0; i < destinations.length; i++)
                Expanded(
                  child: _BarDestination(
                    icon: destinations[i].icon,
                    label: destinations[i].label,
                    selected: i == selectedIndex,
                    onTap: () => onSelect(i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BarDestination extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _BarDestination({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final color =
        selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      // excludeSemantics drops the InkWell's own semantics, so the tap action
      // must be declared here or screen readers cannot activate the tab.
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 32,
                decoration: BoxDecoration(
                  color: selected ? scheme.secondaryContainer : null,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, size: 24, color: color),
              ),
              const SizedBox(height: 4),
              // The bar is bounded by the screen width; at accessibility text
              // scales an unconstrained label overflows its fifth of the row.
              Text(
                label,
                style: t.labelMedium?.copyWith(color: color),
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
