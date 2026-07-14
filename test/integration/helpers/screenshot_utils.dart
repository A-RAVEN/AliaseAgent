import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// Captures the widget subtree behind [key] as a PNG file at [path].
///
/// The caller must wrap the target widget in a [RepaintBoundary] with [key].
Future<void> captureWidgetAsPng(GlobalKey key, String path) async {
  final boundary =
      key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
  if (boundary == null) {
    throw StateError('RepaintBoundary not found for key. '
        'Wrap the target widget in RepaintBoundary(key: key).');
  }

  final image = await boundary.toImage(pixelRatio: 1.0);
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  if (byteData == null) {
    throw StateError('Failed to convert image to PNG bytes');
  }

  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsBytes(byteData.buffer.asUint8List());
}

/// Captures a screenshot AND compares against a reference if one exists.
///
/// - If [refPath] doesn't exist: copies [outputPath] → [refPath] as baseline.
///   Reports "BASELINE_CREATED" and passes.
/// - If [refPath] exists: compares pixel-by-pixel. Passes if ≤ [tolerance]
///   fraction of pixels differ (by >10 in any RGB channel).
///
/// Throws [TestFailure] if the diff ratio exceeds [tolerance].
Future<void> captureAndCompare(
  GlobalKey key,
  String outputPath,
  String refPath, {
  double tolerance = 0.01,
}) async {
  await captureWidgetAsPng(key, outputPath);

  final refFile = File(refPath);
  if (!refFile.existsSync()) {
    // Baseline creation
    await refFile.parent.create(recursive: true);
    await File(outputPath).copy(refPath);
    return; // baseline created, no comparison
  }

  // Load both images and compare
  final outBytes = await File(outputPath).readAsBytes();
  final refBytes = await refFile.readAsBytes();

  final outImage = await decodeImageFromList(outBytes);
  final refImage = await decodeImageFromList(refBytes);

  final outData = await outImage.toByteData();
  final refData = await refImage.toByteData();

  if (outData!.lengthInBytes != refData!.lengthInBytes) {
    throw Exception(
      'Image size mismatch: ${File(outputPath).lengthSync()} vs ${refFile.lengthSync()} bytes',
    );
  }

  int diffPixels = 0;
  final totalPixels = outData.lengthInBytes ~/ 4;

  for (int i = 0; i < outData.lengthInBytes; i += 4) {
    final dr = (outData.getUint8(i) - refData.getUint8(i)).abs();
    final dg = (outData.getUint8(i + 1) - refData.getUint8(i + 1)).abs();
    final db = (outData.getUint8(i + 2) - refData.getUint8(i + 2)).abs();
    if (dr > 10 || dg > 10 || db > 10) {
      diffPixels++;
    }
  }

  final ratio = diffPixels / totalPixels;
  if (ratio > tolerance) {
    throw Exception(
      'Visual diff: ${(ratio * 100).toStringAsFixed(2)}% pixels changed '
      '(threshold: ${(tolerance * 100).toStringAsFixed(0)}%)\n'
      '  output:    $outputPath\n'
      '  reference: $refPath',
    );
  }
}
