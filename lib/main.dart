import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data/store.dart';
import 'health/repository.dart';
import 'health/service.dart';
import 'seeder.dart';
import 'services/notify.dart';
import 'subscription/gateway.dart';
import 'subscription/secrets.dart';
import 'subscription/service.dart';
import 'subscription/store_gateway.dart';
import 'ui/shell.dart';
import 'ui/widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final secrets = SecureSecretStore();
  final store = await AppStore.open(prefs, secretStore: secrets);
  await seedExercises(store);
  final notify = NotifyService();
  final healthRepo = HealthRepository(store.db);
  final health = HealthService(store: store, repository: healthRepo);
  final subscription = SubscriptionService(
    store: store,
    storeGateway: InAppPurchaseStoreGateway(),
    gateway: GatewayClient(deviceTokenStore: store),
    secrets: secrets,
  );
  // Never block startup on notification scheduling or health sync: both can
  // touch slow platform services, and the AI endpoint may be unreachable.
  unawaited(notify.rescheduleDaily(store));
  unawaited(health.syncIfDue());
  // Pick up a purchase that was verified on a previous run, and refresh the
  // quota so the coach shows the right number.
  unawaited(subscription.init().then((_) => subscription.refreshEntitlement()));
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: store),
        ChangeNotifierProvider.value(value: health),
        ChangeNotifierProvider.value(value: subscription),
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
