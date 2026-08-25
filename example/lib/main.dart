

import 'core/build_stamp/build_stamp.dart';
import 'package:flutter/material.dart';
import 'package:nitro/nitro.dart';
import 'package:nitro_printing/nitro_printing.dart';
import 'core/repositories/printer_repository.dart';
import 'features/status/status_feature.dart';
import 'features/print/print_feature.dart';
import 'features/raw/raw_feature.dart';
import 'features/jobs/jobs_feature.dart';
import 'features/printers/printers_feature.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  NitroConfig.instance
    ..logLevel = NitroLogLevel.verbose
    ..debugMode = true;
  // Instantiates the WASM module on web; a synchronous no-op on native.
  await ensureNitroPrintingReady();
  runApp(App(printerRepository: NitroPrinterRepository()));
}

class App extends StatelessWidget {
  final PrinterRepository printerRepository;
  const App({super.key, required this.printerRepository});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NitroPrinting Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6366F1), // Indigo
          brightness: Brightness.dark,
          primary: const Color(0xFF6366F1),
          secondary: const Color(0xFF8B5CF6), // Violet
          surface: const Color(0xFF0F172A), // Slate 900
          onSurface: const Color(0xFFF1F5F9),
          surfaceContainerHighest: const Color(0xFF1E293B), // Slate 800
        ),
        scaffoldBackgroundColor: const Color(0xFF090D1A),
        cardTheme: CardThemeData(
          color: const Color(0xFF131B2E), // Slate 850
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFF1E293B), width: 1),
          ),
          margin: EdgeInsets.zero,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF1E293B).withValues(alpha: 0.4),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF334155), width: 1),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF1E293B), width: 1),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF6366F1), width: 2),
          ),
          labelStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 14),
          floatingLabelStyle: const TextStyle(color: Color(0xFF6366F1)),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF6366F1),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            elevation: 0,
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF94A3B8),
            side: const BorderSide(color: Color(0xFF334155), width: 1),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        dividerTheme: const DividerThemeData(
          color: Color(0xFF1E293B),
          thickness: 1,
          space: 24,
        ),
        textTheme: const TextTheme(
          headlineMedium: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            letterSpacing: -0.5,
            color: Colors.white,
          ),
          titleLarge: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            letterSpacing: -0.2,
            color: Colors.white,
          ),
          titleMedium: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Color(0xFFE2E8F0),
          ),
          bodyLarge: TextStyle(fontSize: 15, color: Color(0xFFCBD5E1)),
          bodyMedium: TextStyle(fontSize: 14, color: Color(0xFF94A3B8)),
          labelLarge: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
            color: Color(0xFF6366F1),
          ),
        ),
      ),
      home: HomePage(printerRepository: printerRepository),
    );
  }
}

class HomePage extends StatefulWidget {
  final PrinterRepository printerRepository;
  const HomePage({super.key, required this.printerRepository});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;

  final List<({IconData icon, IconData selectedIcon, String label})>
  _destinations = const [
    (icon: Icons.info_outline, selectedIcon: Icons.info, label: 'Status'),
    (
      icon: Icons.devices_outlined,
      selectedIcon: Icons.devices_rounded,
      label: 'Printers',
    ),
    (icon: Icons.print_outlined, selectedIcon: Icons.print, label: 'Print'),
    (
      icon: Icons.receipt_long_outlined,
      selectedIcon: Icons.receipt_long,
      label: 'Raw',
    ),
    (
      icon: Icons.list_alt_outlined,
      selectedIcon: Icons.list_alt,
      label: 'Jobs',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isDesktop = size.width >= 1100;
    final isTablet = size.width >= 650 && size.width < 1100;

    final tabs = [
      StatusTab(repo: widget.printerRepository),
      PrintersTab(repo: widget.printerRepository),
      PrintTab(repo: widget.printerRepository),
      RawTab(repo: widget.printerRepository),
      PrintJobsTab(repo: widget.printerRepository),
    ];

    return Scaffold(
      body: Row(
        children: [
          if (isDesktop) _buildSidebar(context),
          if (isTablet) _buildNavigationRail(context),
          Expanded(
            child: IndexedStack(index: _tab, children: tabs),
          ),
        ],
      ),
      bottomNavigationBar: (!isDesktop && !isTablet)
          ? Container(
              decoration: const BoxDecoration(
                border: Border(
                  top: BorderSide(color: Color(0xFF1E293B), width: 1),
                ),
              ),
              child: NavigationBar(
                backgroundColor: const Color(0xFF0B0F19),
                elevation: 0,
                selectedIndex: _tab,
                onDestinationSelected: (i) => setState(() => _tab = i),
                indicatorColor: const Color(0xFF6366F1).withValues(alpha: 0.15),
                destinations: _destinations
                    .map(
                      (d) => NavigationDestination(
                        icon: Icon(d.icon, color: const Color(0xFF94A3B8)),
                        selectedIcon: Icon(
                          d.selectedIcon,
                          color: const Color(0xFF6366F1),
                        ),
                        label: d.label,
                      ),
                    )
                    .toList(),
              ),
            )
          : null,
    );
  }

  // Elegant sidebar for desktop screens
  Widget _buildSidebar(BuildContext context) {
    return Container(
      width: 260,
      decoration: const BoxDecoration(
        color: Color(0xFF0B0F19),
        border: Border(right: BorderSide(color: Color(0xFF1E293B), width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Elegant Header with glowing logo
          Padding(
            padding: const EdgeInsets.all(24),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF6366F1), Color(0xFF8B5CF6)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF6366F1).withValues(alpha: 0.3),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.print_rounded,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 14),
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'NitroPrint',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        letterSpacing: -0.5,
                      ),
                    ),
                    Text(
                      'Plugin Example',
                      style: TextStyle(
                        fontSize: 11,
                        color: Color(0xFF64748B),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          const SizedBox(height: 20),

          // Menu Items
          Expanded(
            child: ListView.builder(
              itemCount: _destinations.length,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemBuilder: (context, index) {
                final d = _destinations[index];
                final isSelected = _tab == index;

                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => setState(() => _tab = index),
                      borderRadius: BorderRadius.circular(12),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          gradient: isSelected
                              ? LinearGradient(
                                  colors: [
                                    const Color(
                                      0xFF6366F1,
                                    ).withValues(alpha: 0.15),
                                    const Color(
                                      0xFF8B5CF6,
                                    ).withValues(alpha: 0.05),
                                  ],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                )
                              : null,
                          border: isSelected
                              ? Border.all(
                                  color: const Color(
                                    0xFF6366F1,
                                  ).withValues(alpha: 0.25),
                                  width: 1,
                                )
                              : Border.all(color: Colors.transparent, width: 1),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              isSelected ? d.selectedIcon : d.icon,
                              color: isSelected
                                  ? const Color(0xFF6366F1)
                                  : const Color(0xFF64748B),
                              size: 20,
                            ),
                            const SizedBox(width: 16),
                            Text(
                              d.label,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: isSelected
                                    ? FontWeight.bold
                                    : FontWeight.w500,
                                color: isSelected
                                    ? Colors.white
                                    : const Color(0xFF94A3B8),
                              ),
                            ),
                            if (isSelected) ...[
                              const Spacer(),
                              Container(
                                width: 6,
                                height: 6,
                                decoration: const BoxDecoration(
                                  color: Color(0xFF6366F1),
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),

          // Elegant Sidebar Footer
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: Colors.green,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.green,
                        blurRadius: 6,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                const Text(
                  'Plugin Ready',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF64748B),
                  ),
                ),
                const Spacer(),
                FutureBuilder<String>(
                  future: buildStamp(),
                  builder: (context, snap) => Text(
                    snap.data ?? '',
                    style: const TextStyle(
                      fontSize: 10,
                      color: Color(0xFF475569),
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Elegant Navigation Rail for Tablet screens
  Widget _buildNavigationRail(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF0B0F19),
        border: Border(right: BorderSide(color: Color(0xFF1E293B), width: 1)),
      ),
      child: NavigationRail(
        backgroundColor: Colors.transparent,
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        labelType: NavigationRailLabelType.none,
        indicatorColor: const Color(0xFF6366F1).withValues(alpha: 0.15),
        leading: Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF6366F1), Color(0xFF8B5CF6)],
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.print_rounded,
              color: Colors.white,
              size: 20,
            ),
          ),
        ),
        destinations: _destinations
            .map(
              (d) => NavigationRailDestination(
                icon: Icon(d.icon, color: const Color(0xFF94A3B8)),
                selectedIcon: Icon(
                  d.selectedIcon,
                  color: const Color(0xFF6366F1),
                ),
                label: Text(d.label),
              ),
            )
            .toList(),
      ),
    );
  }
}
