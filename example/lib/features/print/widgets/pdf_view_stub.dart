import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Non-web: no inline PDF surface — the preview card's stats still show.
class PdfView extends StatelessWidget {
  final Uint8List bytes;
  const PdfView({super.key, required this.bytes});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        'Inline PDF preview is web-only.\nUse "Save PDF" to inspect the output.',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}
