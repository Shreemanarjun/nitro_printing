import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

import 'package:nitro_printing_example/main.dart' as app;

import 'print_tab.dart';

/// Patrol UI tests for the NitroPrinting example app.
///
/// Run with:
///   patrol test -d `<device>`
///
/// These tests drive the real app UI (tabs, buttons, text fields) instead of
/// calling the plugin API directly — see integration_test/nitro_printing_test.dart
/// for the pure API-level integration suite.
void main() {
  Future<void> boot(PatrolIntegrationTester $) async {
    app.main();
    await $.pumpAndSettle();
    await $('Printer Status Dashboard').waitUntilVisible();
  }

  patrolTest('boots to the Status dashboard and navigates all five tabs', (
    $,
  ) async {
    await boot($);

    // Status tab is the initial screen.
    expect($('Printer Status Dashboard'), findsOneWidget);
    expect($('QUICK LOOKUPS'), findsOneWidget);

    // Walk through every navigation destination and verify its screen.
    await $('Printers').tap();
    await $('Get All Printers').waitUntilVisible();

    await $('Print').tap();
    await $('Document Printing Panel').waitUntilVisible();

    await $('Raw').tap();
    await $('Low-Level Network Printing').waitUntilVisible();

    await $('Jobs').tap();
    await $('Print Queue Manager').waitUntilVisible();

    await $('Status').tap();
    await $('Printer Status Dashboard').waitUntilVisible();
  });

  patrolTest('Status tab: quick lookups render host results', ($) async {
    await boot($);

    // "Is Supported" surfaces the printing-supported row (StatRow uppercases
    // its labels).
    await $('Is Supported').tap();
    await $('HOST RESULTS').waitUntilVisible();
    expect($('PRINTING SUPPORTED'), findsOneWidget);

    // "Printer Count" surfaces the printers-found row.
    await $('Printer Count').tap();
    await $('PRINTERS FOUND').waitUntilVisible();
  });

  patrolTest(
    'Printers tab: Get All Printers renders list state and discovery toggles',
    ($) async {
      await boot($);
      await $('Printers').tap();
      await $('Get All Printers').waitUntilVisible();

      // Load the printer list — the header shows regardless of count.
      await $('Get All Printers').tap();
      await $(RegExp(r'DISCOVERED PRINTERS \(\d+\)')).waitUntilVisible();

      // Toggle mDNS discovery on…
      await $('Start Discovery').tap();
      await $(RegExp('Discovery active')).waitUntilVisible();
      expect($('Stop Discovery'), findsOneWidget);

      // …and off again.
      await $('Stop Discovery').tap();
      await $('Start Discovery').waitUntilVisible();
    },
  );

  patrolTest('Print tab: mode switcher reveals direct-dispatch routing field', (
    $,
  ) async {
    await boot($);
    await $('Print').tap();
    await $('Document Printing Panel').waitUntilVisible();

    // Default mode is the system dialog — no routing field visible.
    expect($('System Dialog'), findsOneWidget);
    expect($('ROUTING ADDRESS').visible, false);

    // Switching to Direct Dispatch reveals the routing address panel.
    await $('Direct Dispatch').tap();
    await $('ROUTING ADDRESS').waitUntilVisible();

    // The routing field accepts input.
    await $(TextField)
        .containing('Direct Destination Printer ID / URL')
        .enterText('ipp://192.0.2.1/ipp/print');
    await $.pumpAndSettle();

    // Switching back hides the panel again.
    await $('System Dialog').tap();
    await $.pump(const Duration(milliseconds: 400));
    expect($('ROUTING ADDRESS').visible, false);
  });

  patrolTest(
    'Raw tab: dispatch without endpoint shows validation snackbar; '
    'protocol tabs switch',
    ($) async {
      await boot($);
      await $('Raw').tap();
      await $('Low-Level Network Printing').waitUntilVisible();

      // ESC/POS is the first protocol tab. Dispatching with no printer
      // endpoint set must show the validation snackbar instead of printing.
      // Target the keyed vertical scrollable of tab 0 so we don't grab the
      // TabBarView's horizontal PageView (which iOS may pick first).
      await $('Dispatch ESC/POS Payload')
          .scrollTo(
            view: find
                .descendant(
                  of: find.byKey(const ValueKey('rawPanelScroll_0')),
                  matching: find.byType(Scrollable),
                )
                .first,
            step: 300,
            maxScrolls: 40,
          )
          .tap();
      await $(RegExp('Enter a printer IP or URI first')).waitUntilVisible();

      // Protocol tabs switch content.
      await $('ZPL').tap();
      await $('ZPL II Programming Language').waitUntilVisible();

      await $('ESC/POS').tap();
      await $('ESC/POS Thermal Receipt Payload').waitUntilVisible();
    },
  );

  patrolTest('Jobs tab: spool count and telemetry feed toggle', ($) async {
    await boot($);
    await $('Jobs').tap();
    await $('Print Queue Manager').waitUntilVisible();

    // Spool count card appears after querying the queue.
    await $('Get Spool Count').tap();
    await $('TOTAL SPOOLED JOBS').waitUntilVisible();
    expect($(RegExp(r'\d+ Active Spool\(s\)')), findsOneWidget);

    // Telemetry feed toggles on…
    expect($('Telemetry Feed Idle'), findsOneWidget);
    await $('Launch Feed').tap();
    await $('Telemetry Feed Active').waitUntilVisible();
    expect($('Kill Feed'), findsOneWidget);

    // …and off again.
    await $('Kill Feed').tap();
    await $('Telemetry Feed Idle').waitUntilVisible();
  });

  patrolTest('system print dialog opens from Print Text and app recovers', (
    $,
  ) async {
    if (kIsWeb || !Platform.isAndroid) {
      // The native back-press recovery flow below is Android-specific.
      return;
    }

    await boot($);
    await $('Print').tap();
    await $('Document Printing Panel').waitUntilVisible();

    // System Dialog mode is the default; dispatch a text print job. This
    // hands off to the Android print activity (native UI). The print actions
    // sit below the tall settings column, and the live preview's height
    // changes while it renders — a drag loop races that and can overshoot to
    // the bottom of the list, so scroll the element into view directly.
    await tapInPrintTab($, $('Print Text'));
    await Future<void>.delayed(const Duration(seconds: 3));

    // Leave the native print dialog and verify the app is responsive again.
    await $.platformAutomator.android.pressBack();
    await $.pump(const Duration(seconds: 1));
    await $('Document Printing Panel').waitUntilVisible();
  });
}
