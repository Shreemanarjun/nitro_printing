import 'package:flutter/material.dart';
import '../../core/repositories/printer_repository.dart';
import '../../core/signals.dart';
import 'status_signals.dart';
import 'widgets/action_chip.dart' as widgets;
import 'widgets/error_banner.dart' as widgets;
import 'widgets/printer_status_detail_card.dart' as widgets;

class StatusTab extends StatefulWidget {
  final PrinterRepository repo;
  const StatusTab({super.key, required this.repo});

  @override
  State<StatusTab> createState() => _StatusTabState();
}

class _StatusTabState extends State<StatusTab> {
  final _ippCtrl = TextEditingController();

  @override
  void dispose() {
    _ippCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isWide = size.width >= 900;

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.dashboard_rounded, color: Color(0xFF6366F1), size: 22),
            SizedBox(width: 10),
            Text(
              'Printer Status Dashboard',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
            ),
          ],
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: ListenableBuilder(
        listenable: createListenableFromSignals([
          isSupported,
          printersCount,
          defaultPrinter,
          printerCapabilities,
          driverVersion,
          printerStatusDetail,
          statusLoading,
          statusError,
        ]),
        builder: (context, _) {
          final loading = statusLoading.value;
          final error = statusError.value;

          final basicInfoColumn = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('QUICK LOOKUPS', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Query basic properties and system integration of the local printing host.',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          widgets.ActionChip(
                            label: 'Is Supported',
                            icon: Icons.check_circle_outline,
                            disabled: loading,
                            onPressed: () => checkPrintingSupported(widget.repo),
                          ),
                          widgets.ActionChip(
                            label: 'Printer Count',
                            icon: Icons.format_list_numbered_outlined,
                            disabled: loading,
                            onPressed: () => loadPrintersCount(widget.repo),
                          ),
                          widgets.ActionChip(
                            label: 'Default Printer',
                            icon: Icons.print_outlined,
                            disabled: loading,
                            onPressed: () => loadDefaultPrinter(widget.repo),
                          ),
                          widgets.ActionChip(
                            label: 'Capabilities',
                            icon: Icons.tune_outlined,
                            disabled: loading,
                            onPressed: () => loadCapabilities(widget.repo),
                          ),
                          widgets.ActionChip(
                            label: 'Driver Version',
                            icon: Icons.info_outline,
                            disabled: loading,
                            onPressed: () => loadDriverVersion(widget.repo),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // Basic Info results
              if (isSupported.value != null ||
                  printersCount.value != null ||
                  defaultPrinter.value != null ||
                  driverVersion.value != null ||
                  printerCapabilities.value != null) ...[
                Text('HOST RESULTS', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (isSupported.value != null)
                          widgets.StatRow(
                            'Printing supported',
                            isSupported.value! ? 'Yes' : 'No',
                            icon: isSupported.value! ? Icons.check_circle : Icons.cancel_outlined,
                            successColor: isSupported.value! ? const Color(0xFF10B981) : const Color(0xFFEF4444),
                          ),
                        if (printersCount.value != null)
                          widgets.StatRow(
                            'Printers found',
                            '${printersCount.value}',
                            icon: Icons.numbers_rounded,
                          ),
                        if (defaultPrinter.value != null) ...[
                          widgets.StatRow(
                            'Default printer',
                            defaultPrinter.value!.name,
                            icon: Icons.star_rounded,
                            highlight: true,
                          ),
                          widgets.StatRow(
                            'Printer ID',
                            defaultPrinter.value!.id,
                            icon: Icons.tag_rounded,
                            mono: true,
                          ),
                          if (defaultPrinter.value!.address.isNotEmpty)
                            widgets.StatRow(
                              'Address',
                              defaultPrinter.value!.address,
                              icon: Icons.router_rounded,
                              mono: true,
                            ),
                        ],
                        if (driverVersion.value != null && driverVersion.value!.isNotEmpty)
                          widgets.StatRow(
                            'Driver version',
                            driverVersion.value!,
                            icon: Icons.build_circle_rounded,
                          ),
                        if (printerCapabilities.value != null) ...[
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 8.0),
                            child: Divider(),
                          ),
                          widgets.CapabilitiesSection(caps: printerCapabilities.value!),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ],
          );

          final ippColumn = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('IPP STATUS INQUIRY', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Query full real-time status via IPP Get-Printer-Attributes protocol.',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _ippCtrl,
                        decoration: InputDecoration(
                          labelText: 'Printer URI / IP address',
                          hintText: 'ipp://192.168.1.10/ipp/print',
                          prefixIcon: const Icon(Icons.link_rounded, color: Color(0xFF64748B)),
                          suffixIcon: loading
                              ? const Padding(
                                  padding: EdgeInsets.all(12),
                                  child: SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF6366F1)),
                                  ),
                                )
                              : IconButton(
                                  icon: const Icon(Icons.search_rounded, color: Color(0xFF6366F1)),
                                  onPressed: () => loadStatusDetail(
                                    widget.repo,
                                    _ippCtrl.text.trim(),
                                  ),
                                ),
                        ),
                        onSubmitted: (v) => loadStatusDetail(widget.repo, v.trim()),
                      ),
                    ],
                  ),
                ),
              ),
              if (printerStatusDetail.value != null) ...[
                const SizedBox(height: 24),
                Text('DETAILED STATUS', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 12),
                widgets.PrinterStatusDetailCard(detail: printerStatusDetail.value!),
              ],
            ],
          );

          return RefreshIndicator(
            onRefresh: () async {
              if (defaultPrinter.value != null) {
                await loadStatusDetail(widget.repo, defaultPrinter.value!.id);
              }
            },
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                if (error != null) widgets.ErrorBanner(error: error),
                if (loading)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 20),
                    child: ClipRRect(
                      borderRadius: BorderRadius.all(Radius.circular(4)),
                      child: LinearProgressIndicator(
                        minHeight: 3,
                        backgroundColor: Color(0xFF1E293B),
                        color: Color(0xFF6366F1),
                      ),
                    ),
                  ),
                if (isWide)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: basicInfoColumn),
                      const SizedBox(width: 24),
                      Expanded(child: ippColumn),
                    ],
                  )
                else ...[
                  basicInfoColumn,
                  const SizedBox(height: 24),
                  ippColumn,
                ],
                const SizedBox(height: 48),
              ],
            ),
          );
        },
      ),
    );
  }
}
