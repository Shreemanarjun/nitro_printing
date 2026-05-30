import 'package:flutter/material.dart';
import 'package:nitro_printing/nitro_printing.dart' as p;
import '../../core/repositories/printer_repository.dart';
import '../../core/signals.dart';
import 'printers_signals.dart';

class PrintersTab extends StatelessWidget {
  final PrinterRepository repo;
  const PrintersTab({super.key, required this.repo});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.devices_rounded, color: Color(0xFF6366F1), size: 22),
            SizedBox(width: 10),
            Text(
              'Printers',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
            ),
          ],
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ListenableBuilder(
              listenable: printersLoading,
              builder: (context, _) => IconButton(
                icon: printersLoading.value
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFF6366F1),
                        ),
                      )
                    : const Icon(Icons.refresh_rounded, color: Color(0xFF6366F1)),
                tooltip: 'Refresh printers',
                onPressed: printersLoading.value ? null : () => loadAllPrinters(repo),
              ),
            ),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: createListenableFromSignals([
          allPrinters,
          printersLoading,
          printersError,
          isDiscovering,
        ]),
        builder: (context, _) {
          final printers = allPrinters.value;
          final loading = printersLoading.value;
          final error = printersError.value;
          final discovering = isDiscovering.value;

          return RefreshIndicator(
            onRefresh: () => loadAllPrinters(repo),
            child: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (error != null)
                          _ErrorBanner(error: error),
                        if (loading && printers == null)
                          const Padding(
                            padding: EdgeInsets.only(bottom: 16),
                            child: ClipRRect(
                              borderRadius: BorderRadius.all(Radius.circular(4)),
                              child: LinearProgressIndicator(
                                minHeight: 3,
                                backgroundColor: Color(0xFF1E293B),
                                color: Color(0xFF6366F1),
                              ),
                            ),
                          ),
                        _ControlBar(repo: repo, discovering: discovering, loading: loading),
                        const SizedBox(height: 24),
                        if (printers != null) ...[
                          Text(
                            'DISCOVERED PRINTERS (${printers.length})',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                          const SizedBox(height: 12),
                        ],
                      ],
                    ),
                  ),
                ),

                if (printers == null && !loading)
                  SliverFillRemaining(
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.print_disabled_rounded,
                            size: 64,
                            color: const Color(0xFF334155),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'No printers loaded',
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              color: const Color(0xFF64748B),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Tap Refresh or use the buttons above',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                  )
                else if (printers != null && printers.isEmpty)
                  SliverFillRemaining(
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.search_off_rounded,
                            size: 64,
                            color: const Color(0xFF334155),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'No printers found',
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              color: const Color(0xFF64748B),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Try enabling discovery or check your network',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                  )
                else if (printers != null)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 48),
                    sliver: SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, index) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _PrinterCard(printer: printers[index]),
                        ),
                        childCount: printers.length,
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ControlBar extends StatelessWidget {
  final PrinterRepository repo;
  final bool discovering;
  final bool loading;

  const _ControlBar({
    required this.repo,
    required this.discovering,
    required this.loading,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'List all printers available to this device, or run mDNS/Bonjour discovery to find network printers.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.list_rounded, size: 18),
                  label: const Text('Get All Printers'),
                  onPressed: loading ? null : () => loadAllPrinters(repo),
                ),
                OutlinedButton.icon(
                  icon: Icon(
                    discovering ? Icons.stop_rounded : Icons.radar_rounded,
                    size: 18,
                    color: discovering ? const Color(0xFFEF4444) : null,
                  ),
                  label: Text(
                    discovering ? 'Stop Discovery' : 'Start Discovery',
                    style: TextStyle(
                      color: discovering ? const Color(0xFFEF4444) : null,
                    ),
                  ),
                  style: discovering
                      ? OutlinedButton.styleFrom(
                          side: const BorderSide(color: Color(0xFFEF4444)),
                        )
                      : null,
                  onPressed: loading ? null : () => toggleDiscovery(repo),
                ),
              ],
            ),
            if (discovering) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Color(0xFF10B981),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Discovery active — scanning network…',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFF10B981),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PrinterCard extends StatelessWidget {
  final p.PrinterInfo printer;
  const _PrinterCard({required this.printer});

  @override
  Widget build(BuildContext context) {
    final isDefault = printer.isDefault;
    final isAvailable = printer.isAvailable;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: isAvailable
                    ? const Color(0xFF6366F1).withValues(alpha: 0.12)
                    : const Color(0xFF334155).withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                isAvailable ? Icons.print_rounded : Icons.print_disabled_rounded,
                color: isAvailable ? const Color(0xFF6366F1) : const Color(0xFF64748B),
                size: 22,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          printer.name.isNotEmpty ? printer.name : printer.id,
                          style: Theme.of(context).textTheme.titleMedium,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isDefault) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: const Color(0xFF6366F1).withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: const Color(0xFF6366F1).withValues(alpha: 0.3),
                            ),
                          ),
                          child: const Text(
                            'Default',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF6366F1),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (printer.id.isNotEmpty && printer.id != printer.name) ...[
                    const SizedBox(height: 4),
                    Text(
                      printer.id,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: const Color(0xFF64748B),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  if (printer.address.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(Icons.router_rounded, size: 13, color: Color(0xFF64748B)),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            printer.address,
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              fontFamily: 'monospace',
                              fontSize: 12,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _StatusDot(
                        color: isAvailable ? const Color(0xFF10B981) : const Color(0xFFEF4444),
                        label: isAvailable ? 'Available' : 'Unavailable',
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  final Color color;
  final String label;
  const _StatusDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color),
        ),
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String error;
  const _ErrorBanner({required this.error});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFEF4444).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFEF4444).withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, color: Color(0xFFEF4444), size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              error,
              style: const TextStyle(color: Color(0xFFEF4444), fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
