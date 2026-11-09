import 'dart:io';

import 'package:compounder/data/store.dart';
import 'package:compounder/health/repository.dart';
import 'package:compounder/health/service.dart';
import 'package:compounder/services/notify.dart';
import 'package:compounder/ui/drawer.dart';
import 'package:compounder/ui/habits.dart';
import 'package:compounder/ui/heatmap.dart';
import 'package:compounder/ui/planner.dart';
import 'package:compounder/ui/settings.dart';
import 'package:compounder/ui/shell.dart';
import 'package:compounder/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Health plugin stub: the drawer/shell never needs real Health Connect data,
/// but the shell's post-frame `syncIfDue()` must not touch platform channels.
class _StubHealthSource implements HealthSource {
  @override
  Future<void> configure() async {}

  @override
  Future<HealthConnectSdkStatus?> sdkStatus() async =>
      HealthConnectSdkStatus.sdkAvailable;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<void> install() async {}

  @override
  bool isTypeAvailable(HealthDataType type) => true;

  @override
  Future<bool> requestAuthorization(List<HealthDataType> types) async => true;

  @override
  Future<bool?> hasPermissions(List<HealthDataType> types) async => true;

  @override
  Future<bool> isHistoryAvailable() async => true;

  @override
  Future<bool> isHistoryAuthorized() async => false;

  @override
  Future<bool> requestHistoryAuthorization() async => true;

  @override
  Future<List<HealthDataPoint>> fetch({
    required HealthDataType type,
    required DateTime start,
    required DateTime end,
  }) async =>
      const [];

  @override
  Future<void> revokePermissions() async {}
}

/// Loads the real Roboto face so text measurement matches a device instead of
/// the test-only Ahem font.
///
/// Returns `null` on success, or a human-readable reason when the face could
/// not be loaded. The caller turns a non-null reason into an explicit skip: a
/// silent fallback to Ahem would quietly weaken the font-dependent assertions
/// below (Ahem is much wider than Roboto, so `didExceedMaxLines` and the 212dp
/// width bound would stop meaning anything).
Future<String?> _loadRoboto() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) {
    return 'FLUTTER_ROOT is unset, so the SDK material fonts cannot be found';
  }
  final file =
      File('$root/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf');
  if (!file.existsSync()) {
    return 'Roboto-Regular.ttf is missing at ${file.path}';
  }
  final bytes = await file.readAsBytes();
  final loader = FontLoader('Roboto')
    ..addFont(Future.value(ByteData.view(bytes.buffer)));
  await loader.load();
  return null;
}

/// Marks the current test skipped, with the recorded reason, when the real
/// Roboto face could not be loaded. Returns true so the caller can bail out
/// before running font-dependent assertions.
///
/// `markTestSkipped` records the skip and prints the reason, but it does *not*
/// stop the test body, so the caller must `return` immediately.
bool _skipWithoutRoboto(String? fontLoadFailure) {
  if (fontLoadFailure == null) return false;
  markTestSkipped('font-dependent assertion skipped: $fontLoadFailure');
  return true;
}

Widget _drawerHost({
  required double textScaler,
  required GlobalKey<ScaffoldState> scaffoldKey,
  int currentIndex = 0,
  ValueChanged<int>? onSelectTab,
}) =>
    MaterialApp(
      theme: CompounderTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScaler)),
        child: child!,
      ),
      home: Scaffold(
        key: scaffoldKey,
        drawer: AppDrawer(
          currentIndex: currentIndex,
          onSelectTab: onSelectTab ?? (_) {},
        ),
      ),
    );

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  // Real I/O cannot be awaited inside testWidgets' fake-async zone, so the
  // font is registered once for the whole file. A failure here is recorded
  // rather than swallowed: the font-dependent assertions below are skipped
  // with that reason, and the font-independent overflow guard still runs.
  String? fontLoadFailure;
  setUpAll(() async {
    fontLoadFailure = await _loadRoboto();
  });

  late AppStore store;
  late HealthService health;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final path = '${await databaseFactory.getDatabasesPath()}/drawer_a11y.db';
    await databaseFactory.deleteDatabase(path);
    store = await AppStore.open(prefs, path: path);
    health = HealthService(
      store: store,
      repository: HealthRepository(store.db),
      source: _StubHealthSource(),
    );
  });

  tearDown(() async {
    await store.db.close();
  });

  group('drawer header accessibility', () {
    // Font-independent: a RenderFlex overflow is reported through FlutterError
    // regardless of which face is used, so this regression guard always runs.
    // Before the fix the header Row overflowed by 42px at 2.0 and this failed.
    testWidgets('does not overflow at textScaler 2.0 (Android max font size)',
        (tester) async {
      final scaffoldKey = GlobalKey<ScaffoldState>();
      await tester.pumpWidget(
        _drawerHost(textScaler: 2.0, scaffoldKey: scaffoldKey),
      );
      scaffoldKey.currentState!.openDrawer();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull,
          reason: 'drawer header must not overflow at textScaler 2.0');
    });

    // Font-dependent: these numbers only mean something with a real face.
    // Under Ahem the label is far wider than Roboto, so the width bound would
    // pass vacuously and the ellipsis check would stop testing the real case.
    testWidgets('constrains and ellipsizes the label at textScaler 2.0',
        (tester) async {
      if (_skipWithoutRoboto(fontLoadFailure)) return;

      final scaffoldKey = GlobalKey<ScaffoldState>();
      await tester.pumpWidget(
        _drawerHost(textScaler: 2.0, scaffoldKey: scaffoldKey),
      );
      scaffoldKey.currentState!.openDrawer();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull,
          reason: 'drawer header must not overflow at textScaler 2.0');

      // Positive proof the label is constrained rather than merely lucky: the
      // drawer is 304dp wide with 20dp side padding, 40dp logo and 12dp gap,
      // leaving 212dp for the label.
      final label = find.text('Compounder');
      expect(label, findsOneWidget);
      final size = tester.getSize(label);
      expect(size.width, lessThanOrEqualTo(212.0),
          reason: 'label must fit the space left by the logo');
      expect(size.height, lessThanOrEqualTo(60.0),
          reason: 'label must stay on one line at 2.0');

      // At 2.0 the word is wider than the slot, so it must be ellipsized
      // rather than clipped or overflowed.
      final paragraph =
          tester.renderObject<RenderParagraph>(find.text('Compounder'));
      expect(paragraph.didExceedMaxLines, isTrue,
          reason: 'the label should be ellipsized at 2.0, not silently clipped');
    });

    // Font-independent: overflow/maxLines are widget properties, not metrics.
    testWidgets('declares a single ellipsized line at the default text scale',
        (tester) async {
      final scaffoldKey = GlobalKey<ScaffoldState>();
      await tester.pumpWidget(
        _drawerHost(textScaler: 1.0, scaffoldKey: scaffoldKey),
      );
      scaffoldKey.currentState!.openDrawer();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final text = tester.widget<Text>(find.text('Compounder'));
      expect(text.overflow, TextOverflow.ellipsis);
      expect(text.maxLines, 1);
    });

    // Font-dependent: whether the whole word fits at 1.0 is a metrics question.
    testWidgets('renders the full label at the default text scale',
        (tester) async {
      if (_skipWithoutRoboto(fontLoadFailure)) return;

      final scaffoldKey = GlobalKey<ScaffoldState>();
      await tester.pumpWidget(
        _drawerHost(textScaler: 1.0, scaffoldKey: scaffoldKey),
      );
      scaffoldKey.currentState!.openDrawer();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // At 1.0 the whole word fits, so nothing is clipped.
      final paragraph = tester.renderObject<RenderParagraph>(
          find.text('Compounder'));
      expect(paragraph.didExceedMaxLines, isFalse);
    });

    testWidgets('marks the current tab with a non-colour cue', (tester) async {
      final scaffoldKey = GlobalKey<ScaffoldState>();
      await tester.pumpWidget(
        _drawerHost(
          textScaler: 1.0,
          scaffoldKey: scaffoldKey,
          currentIndex: tabWealth,
        ),
      );
      scaffoldKey.currentState!.openDrawer();
      await tester.pumpAndSettle();

      // WCAG 1.4.1: the selected tab must not be signalled by tint alone.
      expect(find.byIcon(Icons.check), findsOneWidget);
      final tile = tester.widget<ListTile>(
        find.ancestor(of: find.text('Wealth'), matching: find.byType(ListTile)),
      );
      expect(tile.selected, isTrue);
      expect(tile.trailing, isNotNull);
    });
  });

  group('shell drawer navigation', () {
    Future<void> pumpShell(WidgetTester tester) async {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: store),
            ChangeNotifierProvider.value(value: health),
            Provider.value(value: NotifyService()),
          ],
          child: MaterialApp(
            theme: CompounderTheme.light(),
            home: const ShellScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('selecting a drawer destination switches the tab and closes it',
        (tester) async {
      await pumpShell(tester);

      await tester.tap(find.byIcon(Icons.menu).first);
      await tester.pumpAndSettle();
      expect(find.byType(AppDrawer), findsOneWidget);

      // Mind is drawer-only: it has no bottom-bar destination to collide with.
      await tester.tap(find.descendant(
        of: find.byType(AppDrawer),
        matching: find.text('Mind'),
      ));
      await tester.pumpAndSettle();

      final stack = tester.widget<IndexedStack>(find.byType(IndexedStack));
      expect(stack.index, tabMind, reason: 'Mind is drawer-only at index 5');
      expect(find.byType(Drawer), findsNothing,
          reason: 'the drawer must close after selecting a tab');
    });

    testWidgets('Settings pushes exactly one route and closes the drawer',
        (tester) async {
      await pumpShell(tester);

      await tester.tap(find.byIcon(Icons.menu).first);
      await tester.pumpAndSettle();
      // The drawer now lists Day planner above Activity/Habits/Settings, so
      // Settings can sit below the fold at the test surface height. Scroll it
      // into view before tapping; a missed tap would leave the drawer open.
      final settingsItem = find.descendant(
        of: find.byType(AppDrawer),
        matching: find.text('Settings'),
      );
      await tester.ensureVisible(settingsItem);
      await tester.pumpAndSettle();
      await tester.tap(settingsItem);
      await tester.pumpAndSettle();

      expect(find.byType(Drawer), findsNothing);
      // Exactly one Settings route on the stack, counting offstage routes.
      expect(
        find.byType(SettingsScreen, skipOffstage: false),
        findsOneWidget,
        reason: 'Settings must be pushed exactly once',
      );
      expect(find.text('Settings'), findsWidgets);
    });

    testWidgets('Habits pushes exactly one route and closes the drawer',
        (tester) async {
      await pumpShell(tester);

      await tester.tap(find.byIcon(Icons.menu).first);
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
        of: find.byType(AppDrawer),
        matching: find.text('Habits'),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(Drawer), findsNothing);
      expect(
        find.byType(HabitsScreen, skipOffstage: false),
        findsOneWidget,
        reason: 'Habits must be pushed exactly once',
      );
    });

    testWidgets('Activity pushes exactly one route and closes the drawer',
        (tester) async {
      await pumpShell(tester);

      await tester.tap(find.byIcon(Icons.menu).first);
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
        of: find.byType(AppDrawer),
        matching: find.text('Activity'),
      ));
      await tester.pumpAndSettle();
      // HeatmapScreen loads its aggregate query in initState; let the real
      // sqflite work finish so no fake timer outlives the test.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();

      expect(find.byType(Drawer), findsNothing);
      expect(
        find.byType(HeatmapScreen, skipOffstage: false),
        findsOneWidget,
        reason: 'Activity must be pushed exactly once',
      );
    });

    testWidgets('Day planner pushes exactly one route and closes the drawer',
        (tester) async {
      await pumpShell(tester);

      await tester.tap(find.byIcon(Icons.menu).first);
      await tester.pumpAndSettle();
      // Day planner sits above Activity/Habits/Settings, so it can sit below
      // the fold at the test surface height. Scroll it into view before
      // tapping; a missed tap would leave the drawer open.
      final plannerItem = find.descendant(
        of: find.byType(AppDrawer),
        matching: find.text('Day planner'),
      );
      await tester.ensureVisible(plannerItem);
      await tester.pumpAndSettle();
      await tester.tap(plannerItem);
      await tester.pumpAndSettle();
      // PlannerScreen loads its day query in didChangeDependencies; let the
      // real sqflite work finish so no fake timer outlives the test.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();

      expect(find.byType(Drawer), findsNothing);
      expect(
        find.byType(PlannerScreen, skipOffstage: false),
        findsOneWidget,
        reason: 'Day planner must be pushed exactly once',
      );
    });

    testWidgets('ShellNav callback is stable across tab switches',
        (tester) async {
      await pumpShell(tester);

      // The shell wraps each tab in its own ShellNav so `visible` describes
      // that tab; the first one belongs to HomeTab.
      ShellNav nav() => tester.widget<ShellNav>(find.byType(ShellNav).first);
      final before = nav().openDrawer;
      final beforeSelect = nav().selectTab;

      // Switch tabs via the bottom bar, which rebuilds the shell.
      await tester.tap(find.descendant(
        of: find.byType(ShellBottomBar),
        matching: find.text('Fitness'),
      ));
      await tester.pumpAndSettle();
      // FitnessTab queries the store when it becomes visible; let the real
      // sqflite work finish so no fake timer outlives the test.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      expect(tester.widget<IndexedStack>(find.byType(IndexedStack)).index,
          tabFitness);

      final after = nav().openDrawer;
      // The reviewer's finding: a fresh closure per build() made
      // updateShouldNotify (identity comparison) return true on every tab
      // switch, rebuilding all five tabs. A stable tear-off compares equal.
      expect(after == before, isTrue,
          reason: 'ShellNav must not notify dependents on every rebuild');
      expect(nav().selectTab == beforeSelect, isTrue,
          reason: 'the tab-switch callback must be stable too');
      expect(nav().updateShouldNotify(ShellNav(
            openDrawer: before,
            selectTab: beforeSelect,
            // The shell now also carries the active-tab visibility flag; a
            // rebuild that changes only the tab must not notify dependents.
            visible: nav().visible,
            child: const SizedBox(),
          )),
          isFalse);
    });
  });
}
