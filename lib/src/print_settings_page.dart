import 'package:flutter/material.dart';
import 'nitro_printing.native.dart';

/// A full-screen Material 3 print-settings editor.
///
/// Usage:
/// ```dart
/// final settings = await NitroPrintSettingsPage.show(context);
/// if (settings != null) { /* print with settings */ }
/// ```
class NitroPrintSettingsPage extends StatefulWidget {
  final PrintSettings initialSettings;

  const NitroPrintSettingsPage({super.key, required this.initialSettings});

  /// Opens [NitroPrintSettingsPage] as a full-screen modal route and returns
  /// the edited [PrintSettings], or `null` if the user cancelled.
  static Future<PrintSettings?> show(
    BuildContext context, {
    PrintSettings? initialSettings,
  }) {
    return Navigator.of(context).push<PrintSettings>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => NitroPrintSettingsPage(
          initialSettings: initialSettings ?? PrintSettings(),
        ),
      ),
    );
  }

  @override
  State<NitroPrintSettingsPage> createState() => _NitroPrintSettingsPageState();
}

class _NitroPrintSettingsPageState extends State<NitroPrintSettingsPage> {
  late PrintSettings _s;

  // Printer list — loaded synchronously (sync FFI, no Isolate overhead)
  late List<PrinterInfo> _printers;

  // Text controllers
  late final TextEditingController _jobNameCtrl;
  late final TextEditingController _headerCtrl;
  late final TextEditingController _footerCtrl;
  late final TextEditingController _inputTrayCtrl;
  late final TextEditingController _customWCtrl;
  late final TextEditingController _customHCtrl;
  late final TextEditingController _pageFromCtrl;
  late final TextEditingController _pageToCtrl;

  @override
  void initState() {
    super.initState();
    _s = widget.initialSettings;
    _printers = _loadPrinters();
    _jobNameCtrl = TextEditingController(text: _s.jobName);
    _headerCtrl = TextEditingController(text: _s.headerText);
    _footerCtrl = TextEditingController(text: _s.footerText);
    _inputTrayCtrl = TextEditingController(text: _s.inputTray);
    _customWCtrl = TextEditingController(
      text: _s.customPaperWidth > 0 ? _s.customPaperWidth.toString() : '',
    );
    _customHCtrl = TextEditingController(
      text: _s.customPaperHeight > 0 ? _s.customPaperHeight.toString() : '',
    );
    _pageFromCtrl = TextEditingController(
      text: _s.pageRangeFrom > 0 ? _s.pageRangeFrom.toString() : '',
    );
    _pageToCtrl = TextEditingController(
      text: _s.pageRangeTo > 0 ? _s.pageRangeTo.toString() : '',
    );
  }

  @override
  void dispose() {
    _jobNameCtrl.dispose();
    _headerCtrl.dispose();
    _footerCtrl.dispose();
    _inputTrayCtrl.dispose();
    _customWCtrl.dispose();
    _customHCtrl.dispose();
    _pageFromCtrl.dispose();
    _pageToCtrl.dispose();
    super.dispose();
  }

  List<PrinterInfo> _loadPrinters() {
    try {
      final printing = NitroPrinting.instance;
      final count = printing.getPrintersCount();
      return [for (int i = 0; i < count; i++) printing.getPrinterAt(i)];
    } catch (_) {
      return [];
    }
  }

  void _save() {
    final updated = PrintSettings(
      printerId: _s.printerId,
      paperSize: _s.paperSize,
      orientationDegrees: _s.orientationDegrees,
      quality: _s.quality,
      copies: _s.copies,
      collate: _s.collate,
      duplex: _s.duplex,
      color: _s.color,
      marginTop: _s.marginTop,
      marginBottom: _s.marginBottom,
      marginLeft: _s.marginLeft,
      marginRight: _s.marginRight,
      jobName: _jobNameCtrl.text,
      pagesPerSheet: _s.pagesPerSheet,
      showPrintDialog: _s.showPrintDialog,
      pageRangeFrom: int.tryParse(_pageFromCtrl.text) ?? 0,
      pageRangeTo: int.tryParse(_pageToCtrl.text) ?? 0,
      customPaperWidth: double.tryParse(_customWCtrl.text) ?? 0,
      customPaperHeight: double.tryParse(_customHCtrl.text) ?? 0,
      fitToPage: _s.fitToPage,
      mediaType: _s.mediaType,
      headerText: _headerCtrl.text,
      footerText: _footerCtrl.text,
      inputTray: _inputTrayCtrl.text,
    );
    Navigator.of(context).pop(updated);
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  void _update(PrintSettings s) => setState(() => _s = s);

  Widget _section(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
          child: Text(
            title,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 12),
          child: Column(children: children),
        ),
      ],
    );
  }

  Widget _dropdownTile<T>({
    required String title,
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
    Widget? leading,
  }) {
    return ListTile(
      leading: leading,
      title: Text(title),
      trailing: DropdownButton<T>(
        value: value,
        underline: const SizedBox.shrink(),
        onChanged: onChanged,
        items: items,
      ),
    );
  }

  Widget _switchTile({
    required String title,
    required String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    Widget? leading,
  }) {
    return SwitchListTile(
      secondary: leading,
      title: Text(title),
      subtitle: subtitle != null ? Text(subtitle) : null,
      value: value,
      onChanged: onChanged,
    );
  }

  Widget _textTile({
    required String label,
    required TextEditingController controller,
    TextInputType? keyboardType,
    Widget? leading,
  }) {
    return ListTile(
      leading: leading,
      title: TextField(
        controller: controller,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          labelText: label,
          border: InputBorder.none,
          isDense: true,
        ),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Print Settings'),
        actions: [
          TextButton(onPressed: _save, child: const Text('Save')),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        children: [
          // ── Printer ──────────────────────────────────────────────────────
          _section('Printer', [
            if (_printers.isEmpty)
              const ListTile(
                leading: Icon(Icons.print_disabled),
                title: Text('No printers found'),
                subtitle: Text(
                  'Printers discovered via network will appear here',
                ),
              )
            else
              _dropdownTile<String>(
                leading: const Icon(Icons.print),
                title: 'Printer',
                value: _s.printerId.isEmpty
                    ? (_printers
                          .firstWhere(
                            (p) => p.isDefault,
                            orElse: () => _printers.first,
                          )
                          .id)
                    : _s.printerId,
                items: _printers
                    .map(
                      (p) => DropdownMenuItem(
                        value: p.id,
                        child: Text(p.name, overflow: TextOverflow.ellipsis),
                      ),
                    )
                    .toList(),
                onChanged: (v) =>
                    v != null ? _update(_s.copyWith(printerId: v)) : null,
              ),
            _switchTile(
              leading: const Icon(Icons.open_in_new),
              title: 'Show Print Dialog',
              subtitle: 'Show OS dialog instead of printing directly',
              value: _s.showPrintDialog,
              onChanged: (v) => _update(_s.copyWith(showPrintDialog: v)),
            ),
            _textTile(
              leading: const Icon(Icons.label_outline),
              label: 'Job Name',
              controller: _jobNameCtrl,
            ),
          ]),

          // ── Paper ─────────────────────────────────────────────────────────
          _section('Paper', [
            _dropdownTile<PaperSize>(
              leading: const Icon(Icons.article_outlined),
              title: 'Paper Size',
              value: _s.paperSize,
              items: PaperSize.values
                  .map(
                    (s) => DropdownMenuItem(
                      value: s,
                      child: Text(s.name.toUpperCase()),
                    ),
                  )
                  .toList(),
              onChanged: (v) =>
                  v != null ? _update(_s.copyWith(paperSize: v)) : null,
            ),
            if (_s.paperSize == PaperSize.custom) ...[
              _textTile(
                leading: const Icon(Icons.width_normal),
                label: 'Width (pt)',
                controller: _customWCtrl,
                keyboardType: TextInputType.number,
              ),
              _textTile(
                leading: const Icon(Icons.height),
                label: 'Height (pt)',
                controller: _customHCtrl,
                keyboardType: TextInputType.number,
              ),
            ],
            _dropdownTile<double>(
              leading: const Icon(Icons.screen_rotation_outlined),
              title: 'Orientation',
              value: _s.orientationDegrees,
              items: const [
                DropdownMenuItem(value: 0.0, child: Text('Portrait')),
                DropdownMenuItem(value: 90.0, child: Text('Landscape')),
                DropdownMenuItem(value: 180.0, child: Text('Reverse Portrait')),
                DropdownMenuItem(
                  value: 270.0,
                  child: Text('Reverse Landscape'),
                ),
              ],
              onChanged: (v) => v != null
                  ? _update(_s.copyWith(orientationDegrees: v))
                  : null,
            ),
          ]),

          // ── Layout ────────────────────────────────────────────────────────
          _section('Layout', [
            ListTile(
              leading: const Icon(Icons.content_copy_outlined),
              title: const Text('Copies'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.remove),
                    onPressed: _s.copies > 1
                        ? () => _update(_s.copyWith(copies: _s.copies - 1))
                        : null,
                  ),
                  Text(
                    '${_s.copies}',
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  IconButton(
                    icon: const Icon(Icons.add),
                    onPressed: () =>
                        _update(_s.copyWith(copies: _s.copies + 1)),
                  ),
                ],
              ),
            ),
            _dropdownTile<int>(
              leading: const Icon(Icons.view_module_outlined),
              title: 'Pages per Sheet',
              value: _s.pagesPerSheet,
              items: const [
                DropdownMenuItem(value: 1, child: Text('1')),
                DropdownMenuItem(value: 2, child: Text('2')),
                DropdownMenuItem(value: 4, child: Text('4')),
                DropdownMenuItem(value: 6, child: Text('6')),
                DropdownMenuItem(value: 8, child: Text('8')),
                DropdownMenuItem(value: 16, child: Text('16')),
              ],
              onChanged: (v) =>
                  v != null ? _update(_s.copyWith(pagesPerSheet: v)) : null,
            ),
            ListTile(
              leading: const Icon(Icons.looks_one_outlined),
              title: const Text('Page Range'),
              subtitle: Text(
                _pageFromCtrl.text.isEmpty && _pageToCtrl.text.isEmpty
                    ? 'All pages'
                    : 'Pages ${_pageFromCtrl.text.isEmpty ? "1" : _pageFromCtrl.text}'
                          '–${_pageToCtrl.text.isEmpty ? "end" : _pageToCtrl.text}',
              ),
              trailing: SizedBox(
                width: 120,
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _pageFromCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'From',
                          isDense: true,
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _pageToCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'To',
                          isDense: true,
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            _switchTile(
              leading: const Icon(Icons.fit_screen),
              title: 'Fit to Page',
              subtitle: 'Scale content to fill printable area',
              value: _s.fitToPage,
              onChanged: (v) => _update(_s.copyWith(fitToPage: v)),
            ),
          ]),

          // ── Quality ───────────────────────────────────────────────────────
          _section('Quality', [
            _dropdownTile<PrintQuality>(
              leading: const Icon(Icons.tune),
              title: 'Print Quality',
              value: _s.quality,
              items: PrintQuality.values
                  .map(
                    (q) => DropdownMenuItem(
                      value: q,
                      child: Text(
                        q.name[0].toUpperCase() + q.name.substring(1),
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (v) =>
                  v != null ? _update(_s.copyWith(quality: v)) : null,
            ),
            _dropdownTile<MediaType>(
              leading: const Icon(Icons.layers_outlined),
              title: 'Media Type',
              value: _s.mediaType,
              items: MediaType.values
                  .map(
                    (m) => DropdownMenuItem(
                      value: m,
                      child: Text(
                        m.name[0].toUpperCase() + m.name.substring(1),
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (v) =>
                  v != null ? _update(_s.copyWith(mediaType: v)) : null,
            ),
            _switchTile(
              leading: const Icon(Icons.color_lens_outlined),
              title: 'Color',
              subtitle: 'Print in color (uncheck for grayscale)',
              value: _s.color,
              onChanged: (v) => _update(_s.copyWith(color: v)),
            ),
            _switchTile(
              leading: const Icon(Icons.flip),
              title: 'Duplex (Double-sided)',
              subtitle: null,
              value: _s.duplex,
              onChanged: (v) => _update(_s.copyWith(duplex: v)),
            ),
            _switchTile(
              leading: const Icon(Icons.sort),
              title: 'Collate',
              subtitle: 'Print pages in order for each copy',
              value: _s.collate,
              onChanged: (v) => _update(_s.copyWith(collate: v)),
            ),
          ]),

          // ── Content ───────────────────────────────────────────────────────
          _section('Content', [
            _textTile(
              leading: const Icon(Icons.vertical_align_top),
              label: 'Header Text',
              controller: _headerCtrl,
            ),
            _textTile(
              leading: const Icon(Icons.vertical_align_bottom),
              label: 'Footer Text',
              controller: _footerCtrl,
            ),
            _textTile(
              leading: const Icon(Icons.inbox_outlined),
              label: 'Input Tray',
              controller: _inputTrayCtrl,
            ),
          ]),

          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ── PrintSettings copyWith extension ─────────────────────────────────────────

extension PrintSettingsCopyWith on PrintSettings {
  PrintSettings copyWith({
    String? printerId,
    PaperSize? paperSize,
    double? orientationDegrees,
    PrintQuality? quality,
    int? copies,
    bool? collate,
    bool? duplex,
    bool? color,
    double? marginTop,
    double? marginBottom,
    double? marginLeft,
    double? marginRight,
    String? jobName,
    int? pagesPerSheet,
    bool? showPrintDialog,
    int? pageRangeFrom,
    int? pageRangeTo,
    double? customPaperWidth,
    double? customPaperHeight,
    bool? fitToPage,
    MediaType? mediaType,
    String? headerText,
    String? footerText,
    String? inputTray,
  }) {
    return PrintSettings(
      printerId: printerId ?? this.printerId,
      paperSize: paperSize ?? this.paperSize,
      orientationDegrees: orientationDegrees ?? this.orientationDegrees,
      quality: quality ?? this.quality,
      copies: copies ?? this.copies,
      collate: collate ?? this.collate,
      duplex: duplex ?? this.duplex,
      color: color ?? this.color,
      marginTop: marginTop ?? this.marginTop,
      marginBottom: marginBottom ?? this.marginBottom,
      marginLeft: marginLeft ?? this.marginLeft,
      marginRight: marginRight ?? this.marginRight,
      jobName: jobName ?? this.jobName,
      pagesPerSheet: pagesPerSheet ?? this.pagesPerSheet,
      showPrintDialog: showPrintDialog ?? this.showPrintDialog,
      pageRangeFrom: pageRangeFrom ?? this.pageRangeFrom,
      pageRangeTo: pageRangeTo ?? this.pageRangeTo,
      customPaperWidth: customPaperWidth ?? this.customPaperWidth,
      customPaperHeight: customPaperHeight ?? this.customPaperHeight,
      fitToPage: fitToPage ?? this.fitToPage,
      mediaType: mediaType ?? this.mediaType,
      headerText: headerText ?? this.headerText,
      footerText: footerText ?? this.footerText,
      inputTray: inputTray ?? this.inputTray,
    );
  }
}
