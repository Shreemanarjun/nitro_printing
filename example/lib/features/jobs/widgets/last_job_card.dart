import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nitro_printing/nitro_printing.dart' as p;

/// Live "last job" panel: follows onPrintJobChanged, shows the newest job's
/// state and typed failure reason, and offers Resume for failed raw jobs.
class LastJobCard extends StatefulWidget {
  const LastJobCard({super.key});

  @override
  State<LastJobCard> createState() => _LastJobCardState();
}

class _LastJobCardState extends State<LastJobCard> {
  p.PrintJob? _job;
  StreamSubscription<p.PrintJobUpdate>? _sub;
  bool _resuming = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    _sub = p.NitroPrinting.instance.onPrintJobChanged().listen((_) => _refresh());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final job = await p.NitroPrinting.instance.lastPrintJob();
    if (mounted) setState(() => _job = job);
  }

  Future<void> _resume() async {
    final job = _job;
    if (job == null) return;
    setState(() => _resuming = true);
    final ok = await p.NitroPrinting.instance.resumePrintJob(job.id);
    if (!mounted) return;
    setState(() => _resuming = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok
            ? 'Resumed ${job.id}'
            : '${job.id} is not resumable (only finished raw-transport jobs are)'),
      ),
    );
  }

  Color _stateColor(p.PrintState s) => switch (s) {
        p.PrintState.completed => Colors.greenAccent,
        p.PrintState.printing => const Color(0xFF6366F1),
        p.PrintState.failed => Colors.redAccent,
        p.PrintState.cancelled => Colors.orangeAccent,
        _ => Colors.grey,
      };

  @override
  Widget build(BuildContext context) {
    final job = _job;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.history_rounded,
                    size: 18, color: Color(0xFF6366F1)),
                const SizedBox(width: 8),
                Text('LAST JOB', style: Theme.of(context).textTheme.labelLarge),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  onPressed: _refresh,
                  tooltip: 'Refresh',
                ),
              ],
            ),
            if (job == null)
              Text('No jobs yet — print something.',
                  style: Theme.of(context).textTheme.bodySmall)
            else ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _stateColor(job.state),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${job.id} · ${job.state.name}'
                      '${job.outcome == p.PrintOutcome.dialogShown ? ' · outcome unknown (browser dialog)' : ''}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                  Text('${job.progress}%',
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
              if (job.failureReason != p.PrintJobFailureReason.none) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Chip(
                      label: Text(job.failureReason.name),
                      backgroundColor: Colors.redAccent.withValues(alpha: .15),
                      visualDensity: VisualDensity.compact,
                    ),
                    if (job.errorMessage.isNotEmpty)
                      Text(job.errorMessage,
                          style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
                const SizedBox(height: 8),
                FilledButton.tonalIcon(
                  onPressed: _resuming ? null : _resume,
                  icon: const Icon(Icons.replay_rounded, size: 16),
                  label: Text(_resuming ? 'Resuming…' : 'Resume job'),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
