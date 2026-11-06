import 'dart:io';

import 'package:compounder/data/store.dart';
import 'package:compounder/health/repository.dart';
import 'package:compounder/health/service.dart';
import 'package:compounder/services/notify.dart';
import 'package:compounder/ui/drawer.dart';
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
/// the test-only Ahem font. Silently falls back to the default font when the
/// Flutter SDK's material fonts are not on disk.
Future<void> _loadRoboto() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return;
  final file =
      File('$root/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf');
  if (!file.existsSync()) return;
  final bytes = await file.readAsBytes();
  final loader = FontLoader('Roboto')
    ..addFont(Future.value(ByteData.view(bytes.buffer)));
  await loader.load();
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
  // font is registered once for the whole file.
  setUpAll(_loadRoboto);

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
    testWidgets('does not overflow at textScaler 2.0 (Android max font size)',
        (tester) async {
      final scaffoldKey = GlobalKey<ScaffoldState>();
      await tester.pumpWidget(
        _drawerHost(textScaler: 2.0, scaffoldKey: scaffoldKey),
      );
      scaffoldKey.currentState!.openDrawer();
      await tester.pumpAndSettle();

      // A RenderFlex overflow is reported through FlutterError, which the test
      // binding surfaces here. This is the regression guard: before the fix the
      // header Row overflowed by 42px at 2.0 and this assertion failed.
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

    testWidgets('renders the full label at the default text scale',
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
          currentIndex: 2,
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

      // Scope to the drawer: "Mind" also labels the bottom NavigationBar.
      await tester.tap(find.descendant(
        of: find.byType(AppDrawer),
        matching: find.text('Mind'),
      ));
      await tester.pumpAndSettle();

      final stack = tester.widget<IndexedStack>(find.byType(IndexedStack));
      expect(stack.index, 3, reason: 'Mind is the fourth tab');
      expect(find.byType(Drawer), findsNothing,
          reason: 'the drawer must close after selecting a tab');
    });

    testWidgets('Settings pushes exactly one route and closes the drawer',
        (tester) async {
      await pumpShell(tester);

      await tester.tap(find.byIcon(Icons.menu).first);
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
        of: find.byType(AppDrawer),
        matching: find.text('Settings'),
      ));
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

    testWidgets('ShellNav callback is stable across tab switches',
        (tester) async {
      await pumpShell(tester);

      ShellNav nav() => tester.widget<ShellNav>(find.byType(ShellNav));
      final before = nav().openDrawer;

      // Switch tabs via the bottom bar, which rebuilds the shell.
      await tester.tap(find.text('Mind').last);
      await tester.pumpAndSettle();
      expect(tester.widget<IndexedStack>(find.byType(IndexedStack)).index, 3);

      final after = nav().openDrawer;
      // The reviewer's finding: a fresh closure per build() made
      // updateShouldNotify (identity comparison) return true on every tab
      // switch, rebuilding all five tabs. A stable tear-off compares equal.
      expect(after == before, isTrue,
          reason: 'ShellNav must not notify dependents on every rebuild');
      expect(nav().updateShouldNotify(ShellNav(
            openDrawer: before,
            child: const SizedBox(),
          )),
          isFalse);
    });
  });
}
