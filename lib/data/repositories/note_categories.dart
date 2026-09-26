import 'dart:convert';
import 'notes_repository.dart';

/// User-defined note categories (notebooks).
///
/// A note's category is stored in its synced source_meta. This list only keeps
/// the user's order and empty categories, in the local `noteCategories`
/// setting; any category found on a note is always shown even if missing here.
class NoteCategories {
  static const settingKey = 'noteCategories';
  static const maxLength = 40;
  final NotesRepository notes;
  final String? Function() readSetting;
  final Future<void> Function(String value) writeSetting;
  NoteCategories(this.notes, this.readSetting, this.writeSetting);

  static List<String> decode(String? raw) {
    try {
      final value = jsonDecode(raw ?? '[]');
      if (value is! List) return [];
      final seen = <String>{};
      return [
        for (final item in value)
          if (item is String && item.trim().isNotEmpty && seen.add(item.trim()))
            item.trim(),
      ];
    } catch (_) {
      return [];
    }
  }

  List<String> get registry => decode(readSetting());
  Future<void> _write(List<String> names) => writeSetting(jsonEncode(names));

  /// Ordered names plus live note counts ('' = uncategorized).
  Future<({List<String> names, Map<String, int> counts})> load() async {
    final counts = await notes.categoryCounts();
    final names = registry;
    final extra =
        counts.keys.where((n) => n.isNotEmpty && !names.contains(n)).toList()
          ..sort();
    return (names: [...names, ...extra], counts: counts);
  }

  /// Returns an error message, or null when the name can be used.
  String? validate(String name, List<String> existing) {
    final value = name.trim();
    if (value.isEmpty) return '请输入分类名称';
    if (value.runes.length > maxLength) return '分类名称最多 $maxLength 个字';
    if (value == '全部笔记' || value == '未分类') return '该名称为系统保留';
    if (existing.contains(value)) return '分类“$value”已存在';
    return null;
  }

  Future<String> create(String name) async {
    final value = name.trim();
    final all = (await load()).names;
    final error = validate(value, all);
    if (error != null) throw StateError(error);
    await _write([...all, value]);
    return value;
  }

  Future<void> rename(String from, String to) async {
    final value = to.trim();
    final all = (await load()).names;
    final error = validate(value, all.where((n) => n != from).toList());
    if (error != null) throw StateError(error);
    await notes.setCategory(await notes.idsInCategory(from), value);
    await _write([for (final n in all) n == from ? value : n]);
  }

  /// Notes are never deleted: they move to uncategorized.
  Future<void> delete(String name) async {
    await notes.setCategory(await notes.idsInCategory(name), '');
    await _write((await load()).names.where((n) => n != name).toList());
  }

  Future<void> reorder(List<String> names) => _write(names);

  /// Merge another device/scope's list (guest import) without losing order.
  static String merge(String? current, String? incoming) {
    final names = decode(current);
    for (final name in decode(incoming)) {
      if (!names.contains(name)) names.add(name);
    }
    return jsonEncode(names);
  }
}
