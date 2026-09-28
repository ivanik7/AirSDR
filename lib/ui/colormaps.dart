// SPDX-License-Identifier: GPL-3.0-or-later
//
// Waterfall colour maps and palette LUT.
//
// Port of:
//   * sdrpp/core/src/gui/colormaps.cpp          (loading the JSON colour maps)
//   * sdrpp/core/src/gui/widgets/waterfall.cpp  WaterFall::updatePalletteFromArray (lines 960-974)
//   * sdrpp/root/res/colormaps/*.json          (data, compiled into colormaps.g.dart
//                                               by tool/ui/gen_colormaps.py)
//
// Differences from SDR++ (see docs/03 §2.7):
//   * The LUT has [kPaletteResolution] (4096) entries instead of WATERFALL_RESOLUTION = 1000000;
//     the interpolation formula (including the `/colorCount` quirk that makes the
//     last colour occupy only the tail) is copied unchanged.
//   * Packing is identical: 0xAABBGGRR in a Uint32List = bytes R,G,B,A on little-endian
//     machines = ui.PixelFormat.rgba8888.

import 'dart:typed_data';

part 'colormaps.g.dart';

/// Number of entries in a palette LUT (SDR++: WATERFALL_RESOLUTION = 1000000).
const int kPaletteResolution = 4096;

/// Opaque black in 0xAABBGGRR packing — used for "no data" pixels
/// (SDR++ updateWaterfallFb fills the rest of the frame buffer with 0xFF000000).
const int kOpaqueBlack = 0xFF000000;

/// One SDR++ colour map (`{"name", "author", "map": ["#RRGGBB", ...]}`).
class ColorMapDef {
  const ColorMapDef({
    required this.id,
    required this.name,
    required this.author,
    required this.colors,
  });

  /// File name without extension (e.g. `classic`, `turbo`).
  final String id;

  /// Display name from the JSON (e.g. `Classic`).
  final String name;
  final String author;

  /// Colours as 0xRRGGBB, in JSON order.
  final List<int> colors;
}

/// Looks up a colour map by [ColorMapDef.id] or [ColorMapDef.name] (case-insensitive).
/// Falls back to Classic, the SDR++ default (`conf["colorMap"] = "Classic"`).
ColorMapDef colorMapByName(String name) {
  final n = name.toLowerCase();
  for (final m in sdrppColorMaps) {
    if (m.id == n || m.name.toLowerCase() == n) return m;
  }
  return sdrppColorMaps.firstWhere((m) => m.id == 'classic');
}

/// Port of `WaterFall::updatePalletteFromArray` (waterfall.cpp:960-974).
///
/// Returns a LUT of [resolution] packed 0xAABBGGRR colours.
Uint32List buildPalette(List<int> colors, {int resolution = kPaletteResolution}) {
  final colorCount = colors.length;
  final pallet = Uint32List(resolution);
  for (var i = 0; i < resolution; i++) {
    final pos = (i / resolution) * colorCount;
    var lowerId = pos.floor();
    var upperId = pos.ceil();
    lowerId = lowerId.clamp(0, colorCount - 1);
    upperId = upperId.clamp(0, colorCount - 1);
    final ratio = pos - lowerId;
    final lc = colors[lowerId], uc = colors[upperId];
    final r = ((lc >> 16) & 0xFF) * (1.0 - ratio) + ((uc >> 16) & 0xFF) * ratio;
    final g = ((lc >> 8) & 0xFF) * (1.0 - ratio) + ((uc >> 8) & 0xFF) * ratio;
    final b = (lc & 0xFF) * (1.0 - ratio) + (uc & 0xFF) * ratio;
    // C++ casts float -> uint32_t (truncation).
    pallet[i] = (255 << 24) | (b.toInt() << 16) | (g.toInt() << 8) | r.toInt();
  }
  return pallet;
}

/// Maps a dB value to a palette entry exactly like `WaterFall::pushFFT`:
/// `pixel = (clamp(v, min, max) - min) / (max - min); pallet[(int)(pixel * (RES - 1))]`.
/// NaN (no data) maps to opaque black.
int paletteLookup(Uint32List palette, double db, double min, double max) {
  if (db.isNaN) return kOpaqueBlack;
  final range = max - min;
  var p = (db.clamp(min, max) - min) / range;
  if (!p.isFinite) p = 0;
  return palette[(p * (palette.length - 1)).toInt()];
}

/// Splits a packed 0xAABBGGRR palette entry into a Flutter ARGB int (0xAARRGGBB).
int packedToArgb(int abgr) {
  final r = abgr & 0xFF, g = (abgr >> 8) & 0xFF, b = (abgr >> 16) & 0xFF, a = (abgr >> 24) & 0xFF;
  return (a << 24) | (r << 16) | (g << 8) | b;
}
