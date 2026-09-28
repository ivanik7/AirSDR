// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/dsp/chain.h (@8c9f5ee, lines 1-198).
//
// C++ `chain<T>` rewires `setInput` of the blocks and calls `onOutputChange` when the tail
// changes. In the synchronous Dart graph a chain simply runs its enabled blocks in order,
// in place (every `Processor<T,T>` of SDR++ supports out == in). The block order and the
// enable/disable API are kept.
import 'dart:typed_data';

import 'processor.dart';

class Chain {
  Chain(this.type);

  final SampleType type;
  final List<ProcessorTT> _links = [];
  final Map<ProcessorTT, bool> _states = Map.identity();

  /// `addBlock(block, enabled)`.
  void addBlock(ProcessorTT block, bool enabled) {
    if (blockExists(block)) {
      throw StateError('[chain] Tried to add a block that is already part of the chain');
    }
    if (block.type != type) {
      throw ArgumentError('[chain] block type ${block.type} != chain type $type');
    }
    _links.add(block);
    _states[block] = false;
    if (enabled) {
      enableBlock(block);
    }
  }

  void removeBlock(ProcessorTT block) {
    if (!blockExists(block)) {
      throw StateError('[chain] Tried to remove a block that is not part of the chain');
    }
    disableBlock(block);
    _states.remove(block);
    _links.remove(block);
  }

  void enableBlock(ProcessorTT block) {
    if (!blockExists(block)) {
      throw StateError("[chain] Tried to enable a block that isn't part of the chain");
    }
    _states[block] = true;
  }

  void disableBlock(ProcessorTT block) {
    if (!blockExists(block)) {
      throw StateError("[chain] Tried to disable a block that isn't part of the chain");
    }
    _states[block] = false;
  }

  void setBlockEnabled(ProcessorTT block, bool enabled) {
    if (enabled) {
      enableBlock(block);
    } else {
      disableBlock(block);
    }
  }

  void enableAllBlocks() {
    for (final ln in _links) {
      enableBlock(ln);
    }
  }

  void disableAllBlocks() {
    for (final ln in _links) {
      disableBlock(ln);
    }
  }

  bool isEnabled(ProcessorTT block) => _states[block] ?? false;

  bool blockExists(ProcessorTT block) => _states.containsKey(block);

  /// Runs the enabled blocks in order over [buf] in place. Returns the output sample count
  /// (multirate blocks such as the AF resampler change it). [buf] must be large enough for
  /// the largest intermediate count.
  int process(int count, Float32List buf) {
    for (final ln in _links) {
      if (_states[ln] != true) continue;
      count = ln.process(count, buf, buf);
    }
    return count;
  }
}
