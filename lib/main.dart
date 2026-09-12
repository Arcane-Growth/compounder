import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data/store.dart';
import 'seeder.dart';
import 'services/notify.dart';
import 'ui/shell.dart';
import 'ui/widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final store = await AppStore.open(prefs);
  await seedExercises(store);
  final notify = NotifyService();
  // Never block startup on notification scheduling: it can touch the network
  // to polish the digest text, and the user's endpoint may be unreachable.
  unawaited(notify.rescheduleDaily(store));
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: store),
        Provider.value(value: notify),
      ],
      child: const CompounderApp(),
    ),
  );
}

class CompounderApp extends StatelessWidget {
  const CompounderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Compounder',
      debugShowCheckedModeBanner: false,
      theme: CompounderTheme.light(),
      darkTheme: CompounderTheme.dark(),
      themeMode: ThemeMode.system,
      home: const ShellScreen(),
    );
  }
}
