import 'dart:io';

import 'package:compounder/ui/macros.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
          body: Center(child: SizedBox(width: 120, height: 120, child: child))),
    );

void main() {
  group('MealPhoto', () {
    testWidgets('an empty path renders the placeholder instead of throwing',
        (tester) async {
      // Coach-logged meals are stored with image_path '' (lib/coach/tools.dart),
      // and Image.file(File('')) throws — so this must never reach Image.file.
      await tester.pumpWidget(_host(const MealPhoto('')));
      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.restaurant_outlined), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('a path that no longer exists on disk renders the placeholder',
        (tester) async {
      final missing =
          '${Directory.systemTemp.path}/compounder-nonexistent-meal.jpg';
      expect(File(missing).existsSync(), isFalse);
      await tester.pumpWidget(_host(MealPhoto(missing)));
      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.restaurant_outlined), findsOneWidget);
    });
  });
}
