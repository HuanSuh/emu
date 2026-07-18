/// Tool-owned, disposable per-project memory: `.emu/memory.json`.
///
/// This is the *learned* tier — recalculation material that emu picks up while
/// running (device pixel ratio, screen size, keys it has seen, the last line
/// inspected). It is git-ignored and rebuildable; it is NOT authoritative.
/// Nothing here should let a later run skip a fresh screenshot before tapping —
/// raw coordinates rot across boots, so they are deliberately *not* stored.
/// Only re-usable, semantic, or recomputable facts live here.
library;

import 'dart:convert';
import 'dart:io';

class ProjectMemory {
  ProjectMemory(this._file, this._data);

  final File _file;
  final Map<String, dynamic> _data;

  double? get lastDpr => (_data['lastDpr'] as num?)?.toDouble();
  set lastDpr(double? v) => _set('lastDpr', v);

  List<int>? get lastScreen {
    final v = _data['lastScreen'];
    return v is List ? v.map((e) => (e as num).toInt()).toList() : null;
  }

  set lastScreen(List<int>? v) => _set('lastScreen', v);

  String? get lastInspect => _data['lastInspect'] as String?;
  set lastInspect(String? v) => _set('lastInspect', v);

  /// Widget keys emu has observed, newest last, de-duplicated.
  List<String> get seenKeys =>
      (_data['seenKeys'] as List?)?.map((e) => '$e').toList() ?? const [];

  void addSeenKey(String key) {
    final keys = seenKeys.where((k) => k != key).toList()..add(key);
    _set('seenKeys', keys);
  }

  void _set(String k, Object? v) {
    if (v == null) {
      _data.remove(k);
    } else {
      _data[k] = v;
    }
  }

  Map<String, dynamic> toJson() => Map.of(_data);

  /// Load `.emu/memory.json` under [stateDir]. Malformed JSON starts empty
  /// rather than throwing — memory is disposable by design.
  static ProjectMemory load(Directory stateDir) {
    final f = File('${stateDir.path}/memory.json');
    if (f.existsSync()) {
      try {
        final m = jsonDecode(f.readAsStringSync());
        if (m is Map) return ProjectMemory(f, m.cast<String, dynamic>());
      } catch (_) {/* fall through to empty */}
    }
    return ProjectMemory(f, <String, dynamic>{});
  }

  /// Persist to disk. Caller ensures [Directory] parent exists (Session.ensureState).
  void save() {
    _file.parent.createSync(recursive: true);
    _file.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(_data)}\n');
  }
}
