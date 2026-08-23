import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

int _viewSeq = 0;

/// Web: renders PDF bytes inline through the browser's PDF viewer.
///
/// Seamless updates: the platform view is registered ONCE and holds TWO
/// stacked iframes — a new document loads in the hidden one and the pair
/// cross-fades on load, so re-renders never flash white or tear down the
/// Flutter platform view.
class PdfView extends StatefulWidget {
  final Uint8List bytes;
  const PdfView({super.key, required this.bytes});

  @override
  State<PdfView> createState() => _PdfViewState();
}

class _PdfViewState extends State<PdfView> {
  late final String _viewType;
  JSObject? _front;
  JSObject? _back;

  static const _frameStyle =
      'position:absolute;inset:0;border:0;width:100%;height:100%;'
      'background:#fff;transition:opacity .18s ease';

  @override
  void initState() {
    super.initState();
    _viewType = 'nitro-pdf-preview-${++_viewSeq}';
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
      final document = globalContext.getProperty('document'.toJS)! as JSObject;
      JSObject makeFrame(String opacity) {
        final f = document.callMethod('createElement'.toJS, 'iframe'.toJS)!
            as JSObject;
        f.callMethod('setAttribute'.toJS, 'style'.toJS,
            '$_frameStyle;opacity:$opacity'.toJS);
        return f;
      }

      final container =
          document.callMethod('createElement'.toJS, 'div'.toJS)! as JSObject;
      container.callMethod('setAttribute'.toJS, 'style'.toJS,
          'position:relative;width:100%;height:100%;background:#fff'.toJS);
      _front = makeFrame('1');
      _back = makeFrame('0');
      container.callMethod('appendChild'.toJS, _front!);
      container.callMethod('appendChild'.toJS, _back!);
      _load(widget.bytes);
      return container;
    });
  }

  String _url(Uint8List bytes) =>
      'data:application/pdf;base64,${base64Encode(bytes)}'
      '#toolbar=0&navpanes=0&view=FitH';

  void _load(Uint8List bytes) {
    final back = _back;
    final front = _front;
    if (back == null || front == null) return;
    // Load into the hidden frame; cross-fade once it's ready.
    back.setProperty(
      'onload'.toJS,
      (() {
        back.callMethod('setAttribute'.toJS, 'style'.toJS,
            '$_frameStyle;opacity:1'.toJS);
        front.callMethod('setAttribute'.toJS, 'style'.toJS,
            '$_frameStyle;opacity:0'.toJS);
        _back = front;
        _front = back;
      }).toJS,
    );
    back.setProperty('src'.toJS, _url(bytes).toJS);
  }

  @override
  void didUpdateWidget(PdfView old) {
    super.didUpdateWidget(old);
    if (!identical(old.bytes, widget.bytes)) _load(widget.bytes);
  }

  @override
  Widget build(BuildContext context) {
    // Key stays constant — the platform view is never recreated.
    return HtmlElementView(key: ValueKey(_viewType), viewType: _viewType);
  }
}
