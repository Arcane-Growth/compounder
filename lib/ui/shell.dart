import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../health/service.dart';

import 'coach.dart';
import 'drawer.dart';
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
  int _index = 0;

  // Stable callback: a fresh closure per build() would make ShellNav's
  // updateShouldNotify (identity comparison) fire on every tab switch and
  // rebuild all five tabs.
  void _openDrawer() => _scaffoldKey.currentState?.openDrawer();

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
        onSelectTab: (i) => setState(() => _index = i),
      ),
      body: ShellNav(
        openDrawer: _openDrawer,
        child: IndexedStack(
          index: _index,
          children: const [
            HomeTab(),
            MacrosTab(),
            WealthTab(),
            MindTab(),
            CoachTab(),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.fitness_center), label: 'Fitness'),
          NavigationDestination(icon: Icon(Icons.restaurant), label: 'Macros'),
          NavigationDestination(icon: Icon(Icons.insights), label: 'Wealth'),
          NavigationDestination(icon: Icon(Icons.psychology), label: 'Mind'),
          NavigationDestination(
              icon: Icon(Icons.support_agent), label: 'Coach'),
        ],
      ),
    );
  }
}
