import 'package:flutter/material.dart';

import 'coach.dart';
import 'home.dart';
import 'macros.dart';
import 'mind.dart';
import 'wealth.dart';

class ShellScreen extends StatefulWidget {
  const ShellScreen({super.key});

  @override
  State<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends State<ShellScreen> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [
          HomeTab(),
          MacrosTab(),
          WealthTab(),
          MindTab(),
          CoachTab(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.fitness_center), label: 'Health'),
          NavigationDestination(icon: Icon(Icons.restaurant), label: 'Macros'),
          NavigationDestination(icon: Icon(Icons.insights), label: 'Wealth'),
          NavigationDestination(icon: Icon(Icons.psychology), label: 'Mind'),
          NavigationDestination(icon: Icon(Icons.support_agent), label: 'Coach'),
        ],
      ),
    );
  }
}
