import 'dart:async';
import 'package:nitro_printing/nitro_printing.dart' as p;
import '../../core/repositories/printer_repository.dart';
import '../../core/signals.dart';

// ── Signals ───────────────────────────────────────────────────────────────────

final jobsCount = Signal<int?>(null);
final selectedJob = Signal<p.PrintJob?>(null);
final jobsLoading = Signal<bool>(false);
final jobsError = Signal<String?>(null);
final isListening = Signal<bool>(false);
final jobEvents = Signal<List<String>>([]);

StreamSubscription<p.PrintJobUpdate>? _jobSub;
StreamSubscription<p.PrinterStatus>? _statusSub;

// ── Actions ───────────────────────────────────────────────────────────────────

void toggleJobListening(PrinterRepository repo) {
  if (isListening.value) {
    _jobSub?.cancel();
    _statusSub?.cancel();
    _jobSub = null;
    _statusSub = null;
    isListening.value = false;
  } else {
    _jobSub = repo.onPrintJobChanged().listen((update) {
      final current = jobEvents.value;
      jobEvents.value = [
        '[JOB] ID: ${update.jobId} → STATE: ${update.state.name} | PROGRESS: ${update.progress}%',
        ...current,
      ].take(50).toList();
    });
    _statusSub = repo.onPrinterStatusChanged().listen((status) {
      final current = jobEvents.value;
      jobEvents.value = [
        '[STATUS] Printer: ${status.printerId} | Online: ${status.isOnline} | Printing: ${status.isPrinting}',
        ...current,
      ].take(50).toList();
    });
    isListening.value = true;
  }
}

Future<void> loadJobsCount(PrinterRepository repo) async {
  jobsLoading.value = true;
  jobsError.value = null;
  try {
    jobsCount.value = await repo.getPrintJobsCount();
  } catch (e) {
    jobsError.value = e.toString();
  } finally {
    jobsLoading.value = false;
  }
}

Future<void> loadJobAt(PrinterRepository repo, int index) async {
  jobsLoading.value = true;
  jobsError.value = null;
  try {
    selectedJob.value = await repo.getPrintJobAt(index);
  } catch (e) {
    jobsError.value = e.toString();
  } finally {
    jobsLoading.value = false;
  }
}

Future<void> cancelJob(PrinterRepository repo, String jobId) async {
  jobsLoading.value = true;
  jobsError.value = null;
  try {
    await repo.cancelPrintJob(jobId);
  } catch (e) {
    jobsError.value = e.toString();
  } finally {
    jobsLoading.value = false;
  }
}

void disposeJobsSubscriptions() {
  _jobSub?.cancel();
  _statusSub?.cancel();
  _jobSub = null;
  _statusSub = null;
  isListening.value = false;
}
