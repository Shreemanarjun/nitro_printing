import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

/// Scrolling helpers for the app's scrollable tabs, shared by the Patrol suites.
///
/// A tab is a lazily-built `ListView`, and on the Print tab its content height
/// changes while the live preview renders. That defeats both naive approaches:
///
///   * a pure drag loop (`scrollTo`) races the shrinking scroll extent and can
///     sail past the target to the bottom of the list;
///   * a bare `ensureVisible` throws `Bad state: No element` when the target
///     has not been built yet — the print actions sit outside the ListView's
///     cache extent whenever the settings column is tall (Direct Dispatch mode
///     adds the routing field, which is enough to push them out).
///
/// So: drag only until the target mounts, then let `ensureVisible` place it.
Future<void> revealInList(
  PatrolIntegrationTester $,
  PatrolFinder target, {
  bool towardsTop = false,
  int maxDrags = 25,
}) async {
  // The app keeps every tab alive in an IndexedStack, so only the hit-testable
  // scrollables belong to the visible tab — and `first` is the tab's own list:
  // text fields carry their own Scrollable, so Direct Dispatch mode (which adds
  // the routing field) matches more than one.
  final view = find.byType(Scrollable).hitTestable().first;
  final step = Offset(0, towardsTop ? 300 : -300);
  for (var i = 0; i < maxDrags && target.evaluate().isEmpty; i++) {
    await $.tester.drag(view, step);
    await $.pumpAndTrySettle();
  }
  await $.tester.ensureVisible(target.first);
  // `pumpAndTrySettle`, not `pumpAndSettle`: tabs with a looping animation
  // (the Jobs tab's telemetry indicator) never reach a settled frame, and
  // pumpAndSettle would throw instead of scrolling.
  await $.pumpAndTrySettle();
}

/// [revealInList] followed by a tap on the target.
Future<void> tapInList(
  PatrolIntegrationTester $,
  PatrolFinder target,
) async {
  await revealInList($, target);
  await target.first.tap();
}
