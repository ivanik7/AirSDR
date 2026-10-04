// SPDX-License-Identifier: GPL-3.0-or-later
// UI-only declarative source controls. Native ABI v3 currently exposes none.
sealed class SourceSetting {
  const SourceSetting(this.id, this.label);
  final String id;
  final String label;
}

class ChoiceSetting extends SourceSetting {
  const ChoiceSetting(super.id, super.label, this.options, this.selected);
  final List<String> options;
  final int selected;
}

class SliderSetting extends SourceSetting {
  const SliderSetting(
    super.id,
    super.label, {
    required this.min,
    required this.max,
    required this.step,
    required this.value,
  });
  final double min, max, step, value;
}

class BoolSetting extends SourceSetting {
  const BoolSetting(super.id, super.label, this.value);
  final bool value;
}
