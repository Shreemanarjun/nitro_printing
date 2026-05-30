import 'package:flutter/material.dart';
import '../../core/repositories/printer_repository.dart';
import '../../core/signals.dart';
import 'jobs_signals.dart';
import 'widgets/action_button.dart';
import 'widgets/event_terminal.dart';
import 'widgets/listening_toggle.dart';
import 'widgets/pulsing_dot.dart';
import 'widgets/result_card.dart';
import 'widgets/spool_count_card.dart';
import 'widgets/spool_detail_card.dart';

class PrintJobsTab extends StatefulWidget {
  final PrinterRepository repo;
  const PrintJobsTab({super.key, required this.repo});

  @override
  State<PrintJobsTab> createState() => _PrintJobsTabState();
}

class _PrintJobsTabState extends State<PrintJobsTab> {
  @override
  void dispose() {
    disposeJobsSubscriptions();
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
            Icon(Icons.list_alt_rounded, color: Color(0xFF6366F1), size: 22),
            SizedBox(width: 10),
            Text(
              'Print Queue Manager',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ],
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: ListenableBuilder(
        listenable: createListenableFromSignals([
          jobsCount,
          selectedJob,
          jobsLoading,
          jobsError,
          isListening,
          jobEvents,
        ]),
        builder: (context, _) {
          final loading = jobsLoading.value;
          final error = jobsError.value;
          final listening = isListening.value;
          final events = jobEvents.value;

          final controlColumn = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'QUEUE OPERATIONS',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Query the native operational print spooler and cancel running pipelines.',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ActionButton(
                            label: 'Get Spool Count',
                            icon: Icons.numbers_rounded,
                            disabled: loading,
                            onPressed: () => loadJobsCount(widget.repo),
                          ),
                          ActionButton(
                            label: 'Query Spool [0]',
                            icon: Icons.find_in_page_rounded,
                            disabled: loading,
                            onPressed: () => loadJobAt(widget.repo, 0),
                          ),
                          ActionButton(
                            label: 'Force Kill Spool "test"',
                            icon: Icons.cancel_schedule_send_rounded,
                            disabled: loading,
                            onPressed: () => cancelJob(widget.repo, 'test'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),

              Text(
                'TELEMETRY LISTENER',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Monitor dynamic event streams dispatched by print servers and physical device engines.',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          ListeningToggle(
                            listening: listening,
                            onPressed: () => toggleJobListening(widget.repo),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color:
                                    (listening
                                            ? const Color(0xFF10B981)
                                            : const Color(0xFF64748B))
                                        .withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color:
                                      (listening
                                              ? const Color(0xFF10B981)
                                              : const Color(0xFF64748B))
                                          .withValues(alpha: 0.2),
                                  width: 1,
                                ),
                              ),
                              child: Row(
                                children: [
                                  if (listening) ...[
                                    const PulsingDot(),
                                    const SizedBox(width: 8),
                                  ],
                                  Text(
                                    listening
                                        ? 'Telemetry Feed Active'
                                        : 'Telemetry Feed Idle',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: listening
                                          ? const Color(0xFF10B981)
                                          : const Color(0xFF94A3B8),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );

          final logsColumn = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    'REAL-TIME PIPELINE LOGS',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const Spacer(),
                  if (events.isNotEmpty)
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(50, 30),
                      ),
                      onPressed: () => jobEvents.value = [],
                      icon: const Icon(
                        Icons.delete_sweep_rounded,
                        size: 16,
                        color: Color(0xFF6366F1),
                      ),
                      label: const Text(
                        'Clear',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFF6366F1),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              EventTerminal(events: events),
            ],
          );

          return ListView(
            padding: const EdgeInsets.all(24),
            children: [
              if (error != null) ResultCard(result: error, isError: true),
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
              if (selectedJob.value != null) ...[
                SpoolDetailCard(job: selectedJob.value!),
                const SizedBox(height: 24),
              ],
              if (jobsCount.value != null) ...[
                SpoolCountCard(count: jobsCount.value!),
                const SizedBox(height: 24),
              ],

              if (isWide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: controlColumn),
                    const SizedBox(width: 24),
                    Expanded(child: logsColumn),
                  ],
                )
              else ...[
                controlColumn,
                const SizedBox(height: 24),
                logsColumn,
              ],
              const SizedBox(height: 48),
            ],
          );
        },
      ),
    );
  }
}
