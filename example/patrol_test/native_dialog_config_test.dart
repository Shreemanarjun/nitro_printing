import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

import 'package:nitro_printing_example/main.dart' as app;

/// Patrol tests verifying that the *native Android print dialog* is opened
/// with exactly the configuration selected in the app.
///
/// The plugin maps PrintSettings → android.print.PrintAttributes:
///   paperSize  → MediaSize   (dialog "Paper size" spinner)
///   orientationDegrees → portrait/landscape MediaSize variant
///                              (dialog "Orientation" spinner)
///   color      → COLOR_MODE_* (dialog "Color" spinner)
///
/// Note: the Android print framework does NOT accept a preset copies count —
/// the dialog always opens at 1 copy. Copies propagation is covered by the
/// direct-dispatch and IPP tests in network_printer_test.dart instead.
///
/// Run with:
///   patrol test -t patrol_test/native_dialog_config_test.dart -d `<device>`
void main() {
  const spoolerPackage = 'com.android.printspooler';

  bool isAndroid() => !kIsWeb && Platform.isAndroid;

  Future<void> boot(PatrolIntegrationTester $) async {
    app.main();
    await $.pumpAndSettle();
    await $('Printer Status Dashboard').waitUntilVisible();
  }

  Future<void> openPrintTab(PatrolIntegrationTester $) async {
    await $('Print').tap();
    await $('Document Printing Panel').waitUntilVisible();
  }

  Future<void> scrollToAndTap(PatrolIntegrationTester $, String label) async {
    await $(label)
        .scrollTo(
          view: find.byType(Scrollable).hitTestable(),
          step: 300,
          maxScrolls: 40,
        )
        .tap();
  }

  Future<void> selectDropdownOption(
    PatrolIntegrationTester $,
    String current,
    String option,
  ) async {
    await scrollToAndTap($, current);
    await $(option).waitUntilVisible();
    await $(option).tap();
  }

  Future<void> tapFirstNative(
    PatrolIntegrationTester $,
    List<AndroidSelector> candidates, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    Object? lastError;
    for (final selector in candidates) {
      try {
        await $.platformAutomator.android.tap(selector, timeout: timeout);
        return;
      } catch (err) {
        lastError = err;
      }
    }
    throw StateError(
      'No native view matched any of the candidate selectors: $lastError',
    );
  }

  /// Opens the spooler's collapsed options panel so all preset spinners
  /// (paper size, color, orientation) become visible.
  Future<void> expandDialogOptions(PatrolIntegrationTester $) async {
    await tapFirstNative($, [
      AndroidSelector(
        resourceName: '$spoolerPackage:id/expand_collapse_handle',
      ),
      AndroidSelector(contentDescriptionContains: 'xpand'),
      AndroidSelector(contentDescriptionContains: 'ore options'),
    ], timeout: const Duration(seconds: 10));
  }

  /// Waits for the native print dialog to appear.
  Future<void> waitForSpooler(PatrolIntegrationTester $) async {
    await $.platformAutomator.android.waitUntilVisible(
      AndroidSelector(applicationPackage: spoolerPackage),
      timeout: const Duration(seconds: 15),
    );
  }

  /// Asserts a native view whose text contains one of [candidates] is
  /// visible inside the print dialog (labels vary slightly across Android
  /// builds). On failure the error lists every text the dialog does show.
  Future<void> expectNativeText(
    PatrolIntegrationTester $,
    List<String> candidates, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    for (final text in candidates) {
      try {
        await $.platformAutomator.android.waitUntilVisible(
          AndroidSelector(
            applicationPackage: spoolerPackage,
            textContains: text,
          ),
          timeout: timeout,
        );
        return;
      } catch (_) {
        // Try the next label variant.
      }
    }

    final views = await $.platformAutomator.android.getNativeViews(
      AndroidSelector(applicationPackage: spoolerPackage),
    );
    final texts = <String>[];
    void collect(AndroidNativeView view) {
      final text = view.text;
      if (text != null && text.isNotEmpty) texts.add(text);
      view.children.forEach(collect);
    }

    views.roots.forEach(collect);
    fail(
      'None of $candidates found in the native print dialog. '
      'Dialog texts: $texts',
    );
  }

  /// Backs out of the (expanded) print dialog and confirms the app resumed.
  Future<void> leaveDialog(PatrolIntegrationTester $) async {
    // First back collapses the expanded options, second one closes the
    // dialog itself.
    await $.platformAutomator.android.pressBack();
    await Future<void>.delayed(const Duration(seconds: 1));
    await $.platformAutomator.android.pressBack();
    await $('Document Printing Panel').waitUntilVisible(
      timeout: const Duration(seconds: 15),
    );
  }

  patrolTest(
    'native dialog opens preset to the paper size, orientation and color '
    'selected in the app',
    ($) async {
      if (!isAndroid()) return;
      await boot($);
      await openPrintTab($);

      // Configure: Letter paper, landscape, black & white.
      await selectDropdownOption($, 'A4', 'LETTER');
      await selectDropdownOption($, 'Portrait', 'Landscape');
      // First switch in the settings panel is "Full Color Output" — turn it
      // off to request monochrome.
      await $('Full Color Output').scrollTo(
        view: find.byType(Scrollable).hitTestable(),
        step: 300,
        maxScrolls: 40,
      );
      await $(Switch).at(0).tap();
      await $.pumpAndSettle();

      await scrollToAndTap($, 'Print Text');
      await waitForSpooler($);
      await expandDialogOptions($);

      // The spinners must show exactly the app-selected configuration.
      await expectNativeText($, ['Letter']);
      await expectNativeText($, ['Landscape']);
      await expectNativeText($, [
        'Black & white',
        'Black & White',
        'Black and white',
        'Monochrome',
      ]);

      await leaveDialog($);
    },
  );

  patrolTest(
    'native dialog opens preset to the default A4 portrait color '
    'configuration',
    ($) async {
      if (!isAndroid()) return;
      await boot($);
      await openPrintTab($);

      await scrollToAndTap($, 'Print Text');
      await waitForSpooler($);
      await expandDialogOptions($);

      await expectNativeText($, ['A4']);
      await expectNativeText($, ['Portrait']);
      await expectNativeText($, ['Color', 'Colour']);

      // The Android print framework does not accept a preset copies count —
      // the dialog must open at 1 copy (copies propagation is verified via
      // the direct/IPP transports instead).
      await $.platformAutomator.android.waitUntilVisible(
        AndroidSelector(
          resourceName: '$spoolerPackage:id/copies_edittext',
          text: '1',
        ),
        timeout: const Duration(seconds: 10),
      );

      await leaveDialog($);
    },
  );
}
