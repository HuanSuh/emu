/// Dashboard pages declared in `emu.yaml` (`pages:`) — project tools such as a
/// template previewer or a remote-config differ, run from the dashboard and
/// from the CLI (`emu run`, `emu block`). emu knows nothing about them: a page
/// is a toolbar of toggles and actions plus blocks, and the contract is "a
/// command, and what it prints" (JSON for state and lists, a unified diff,
/// text for output).
///
/// Commands come only from the config. A request names an item by id and
/// never carries a command, so the dashboard can run exactly what the project
/// declared — the same trust as the `onDeviceReady`/`onAppStarted` hooks. The
/// values a request does carry (the selected row, a segment) fill
/// placeholders such as `{{selected.name}}`, each inside its own argument.
///
/// Parsing is pure and collects every problem instead of failing: one typo
/// hides one item, not the whole page.
library;

/// Page and item ids: they appear in URLs and in `emu run <page>.<item>`.
final _id = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]*$');

bool isPageId(String s) => _id.hasMatch(s);

/// The built-in page the dashboard always shows first.
const debugPageId = 'debug';

/// `{{selected.<column>}}`, `{{row.<column>}}`, `{{seg}}`, `{{input.<field>}}`.
final _placeholder = RegExp(r'\{\{\s*([A-Za-z]+)(?:\.([A-Za-z0-9_-]+))?\s*\}\}');
final _braces = RegExp(r'\{\{.*?\}\}');

/// A command from the config: an argv list, started directly, or a string,
/// run with `sh -c` (like the hooks).
class PageCommand {
  const PageCommand.argv(List<String> this.argv) : shell = null;
  const PageCommand.shell(String this.shell) : argv = null;

  final List<String>? argv;
  final String? shell;

  /// Executable and arguments to start.
  (String, List<String>) get invocation {
    final a = argv;
    return a != null ? (a.first, a.sublist(1)) : ('sh', ['-c', shell!]);
  }

  /// What runs, for people (confirm dialog, `emu pages`): argv shell-quoted.
  String get display => argv?.map(shellQuote).join(' ') ?? shell!;

  /// The placeholders used, as `selected.name`, `row.id`, `seg`, `input.url`.
  Set<String> get placeholders => {
        for (final arg in argv ?? const <String>[])
          for (final m in _placeholder.allMatches(arg)) _key(m),
      };

  /// This command with every placeholder filled from [vars] (keys as in
  /// [placeholders]). A value replaces its placeholder inside that one
  /// argument — spaces or `;` in it are never split or run. Throws
  /// [MissingValue] for the first placeholder [vars] has no value for.
  PageCommand fill(Map<String, String> vars) {
    final a = argv;
    if (a == null) return this;
    return PageCommand.argv([
      for (final arg in a)
        arg.replaceAllMapped(_placeholder, (m) => vars[_key(m)] ?? (throw MissingValue(_key(m)))),
    ]);
  }

  static String _key(Match m) => m.group(2) == null ? m.group(1)! : '${m.group(1)}.${m.group(2)}';
}

/// A placeholder with no value in the request, e.g. no row selected yet.
class MissingValue implements Exception {
  MissingValue(this.key);
  final String key;

  /// `selected`, `row`, `seg` or `input`.
  String get kind => key.split('.').first;

  @override
  String toString() => 'no value for {{$key}}';
}

final _plainArg = RegExp(r'^[A-Za-z0-9_@%+=:,./-]+$');

/// [s] quoted for `sh` when it needs to be.
String shellQuote(String s) => _plainArg.hasMatch(s) ? s : "'${s.replaceAll("'", r"'\''")}'";

/// A `watch:` glob, relative to the project root, as a RegExp over the
/// project-relative path of a changed file: `**` spans directories (`**/`
/// also none), `*` and `?` stay within one.
RegExp globToRegExp(String glob) {
  final g = glob.startsWith('./') ? glob.substring(2) : glob;
  final sb = StringBuffer('^');
  for (var i = 0; i < g.length; i++) {
    final c = g[i];
    if (c == '*' && i + 1 < g.length && g[i + 1] == '*') {
      final dir = i + 2 < g.length && g[i + 2] == '/';
      sb.write(dir ? '(?:.*/)?' : '.*');
      i += dir ? 2 : 1;
    } else if (c == '*') {
      sb.write('[^/]*');
    } else if (c == '?') {
      sb.write('[^/]');
    } else {
      sb.write(RegExp.escape(c));
    }
  }
  sb.write(r'$');
  return RegExp(sb.toString());
}

/// What to do after an item's command succeeds.
enum Then {
  none,
  reload,
  restart;

  static Then? fromWire(Object? v) => v == null ? none : values.where((t) => t.name == '$v').firstOrNull;
}

/// A button or switch in a page's toolbar.
sealed class ToolbarItem {
  const ToolbarItem({required this.id, required this.label, required this.then, required this.timeout});

  final String id;
  final String label;
  final Then then;

  /// Upper bound for the item's command; it is killed after this.
  final Duration timeout;

  Map<String, dynamic> toJson();
}

/// Runs [run] when pressed — a toolbar button, a button on each row of a list
/// (`rowActions`) or under a form. Instead of a command it may open
/// [openUrl] on the device, the way `emu open-url` does. With [confirm], the
/// dashboard shows what will run and asks first, and `emu run` needs `--yes`.
class PageAction extends ToolbarItem {
  const PageAction({
    required super.id,
    required super.label,
    this.run,
    this.openUrl,
    super.then = Then.none,
    super.timeout = defaultTimeout,
    this.confirm = false,
  }) : assert((run == null) != (openUrl == null));

  final PageCommand? run;

  /// The deep link to open, as a one-argument command (so placeholders fill
  /// the same way).
  final PageCommand? openUrl;
  final bool confirm;

  /// What it does, for people.
  String get display => run?.display ?? 'open-url ${openUrl!.argv!.single}';

  Set<String> get placeholders => (run ?? openUrl)!.placeholders;

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'action',
        'id': id,
        'label': label,
        'command': display,
        if (openUrl != null) 'openUrl': openUrl!.argv!.single,
        'uses': placeholders.toList(),
        'then': then.name,
        'confirm': confirm,
      };
}

/// A switch: [state] prints `{"on": bool, "detail"?: string}`; flipping it
/// runs [on] or [off].
class PageToggle extends ToolbarItem {
  const PageToggle({
    required super.id,
    required super.label,
    required this.state,
    required this.on,
    required this.off,
    super.then = Then.none,
    super.timeout = defaultTimeout,
  });

  final PageCommand state;
  final PageCommand on;
  final PageCommand off;

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'toggle',
        'id': id,
        'label': label,
        'on': on.display,
        'off': off.display,
        'uses': {...state.placeholders, ...on.placeholders, ...off.placeholders}.toList(),
        'then': then.name,
      };
}

const defaultTimeout = Duration(seconds: 60);

/// Where a block sits: a column on the left, the main area, or under it.
const blockAreas = {'left', 'main', 'bottom'};

/// A panel in a page's body.
sealed class PageBlock {
  const PageBlock({required this.id, required this.area, this.watch = const []});

  final String id;
  final String area;

  /// Project-relative globs: when a matching file changes, dashboards fetch
  /// the block again.
  final List<String> watch;

  /// The command whose output the block shows, if it has one.
  PageCommand? get command => null;

  Map<String, dynamic> toJson();
}

/// The last toolbar or row run on this page: command, exit code, output.
class OutputBlock extends PageBlock {
  const OutputBlock({required super.id, super.area = 'bottom'});

  @override
  Map<String, dynamic> toJson() => {'kind': 'output', 'id': id, 'area': area, 'source': 'lastAction'};
}

/// How a list column shows its value.
const columnFormats = {'text', 'chip', 'count'};

class ListColumn {
  const ListColumn(this.key, [this.format = 'text']);
  final String key;
  final String format;

  Map<String, dynamic> toJson() => {'key': key, 'format': format};
}

/// A table of the JSON array of objects [run] prints. The first list on a
/// page holds the page's selection: picking a row fills `{{selected.<col>}}`
/// for the other blocks and the toolbar. [rowActions] are buttons on every
/// row, with that row in `{{row.<col>}}`.
class ListBlock extends PageBlock {
  const ListBlock({
    required super.id,
    super.area = 'left',
    super.watch,
    required this.run,
    required this.title,
    this.key,
    this.columns = const [],
    this.rowActions = const [],
  });

  final PageCommand run;
  final String title;

  /// The column that tells rows apart (a selection survives a refresh by it);
  /// null: the first column.
  final String? key;

  /// Empty: every field of the first row, as text.
  final List<ListColumn> columns;
  final List<PageAction> rowActions;

  @override
  PageCommand get command => run;

  PageAction? rowAction(String id) => rowActions.where((a) => a.id == id).firstOrNull;

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'list',
        'id': id,
        'area': area,
        'title': title,
        'command': run.display,
        'uses': run.placeholders.toList(),
        'key': ?key,
        'columns': [for (final c in columns) c.toJson()],
        'rowActions': [for (final a in rowActions) a.toJson()],
        'watch': watch,
      };
}

/// The unified diff [run] prints, rendered like the Changes tab. With
/// [segments], a switch picks what to compare against: `{{seg}}`.
class DiffBlock extends PageBlock {
  const DiffBlock({
    required super.id,
    super.area = 'main',
    super.watch,
    required this.run,
    required this.title,
    this.segments = const [],
  });

  final PageCommand run;
  final String title;
  final List<String> segments;

  @override
  PageCommand get command => run;

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'diff',
        'id': id,
        'area': area,
        'title': title,
        'command': run.display,
        'uses': run.placeholders.toList(),
        'segments': segments,
        'watch': watch,
      };
}

/// A project HTML file in a sandboxed frame, for what lists and diffs can't
/// show (a value tree, an image preview). The frame gets [run]'s output as
/// data and may ask the dashboard to run the toolbar items in [actions] —
/// nothing else: no network, no access to the dashboard.
class HtmlBlock extends PageBlock {
  const HtmlBlock({
    required super.id,
    super.area = 'main',
    super.watch,
    required this.title,
    required this.src,
    this.run,
    this.actions = const [],
  });

  final String title;

  /// Project-relative path of a self-contained HTML file.
  final String src;

  /// Prints the frame's data (JSON, or any text); null: the frame gets none.
  final PageCommand? run;

  /// Toolbar items the frame may run (`postMessage({type: 'emu:action', id})`).
  final List<String> actions;

  @override
  PageCommand? get command => run;

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'html',
        'id': id,
        'area': area,
        'title': title,
        'src': src,
        'command': ?run?.display,
        'uses': run?.placeholders.toList() ?? const [],
        'actions': actions,
        'watch': watch,
      };
}

class FormField {
  const FormField({required this.name, required this.label, this.placeholder, this.initial});

  final String name;
  final String label;
  final String? placeholder;

  /// The value before anyone types (`default:`).
  final String? initial;

  Map<String, dynamic> toJson() => {
        'name': name,
        'label': label,
        'placeholder': ?placeholder,
        'default': ?initial,
      };
}

/// Input fields and the buttons that use them: what's typed fills
/// `{{input.<field>}}` in the [actions]. Values aren't stored by emu; the
/// dashboard keeps them per browser.
class FormBlock extends PageBlock {
  const FormBlock({required super.id, super.area = 'main', required this.title, required this.fields, required this.actions});

  final String title;
  final List<FormField> fields;
  final List<PageAction> actions;

  PageAction? action(String id) => actions.where((a) => a.id == id).firstOrNull;

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'form',
        'id': id,
        'area': area,
        'title': title,
        'fields': [for (final f in fields) f.toJson()],
        'actions': [for (final a in actions) a.toJson()],
      };
}

class DashboardPage {
  const DashboardPage({required this.id, required this.title, this.toolbar = const [], this.blocks = const []});

  final String id;
  final String title;
  final List<ToolbarItem> toolbar;
  final List<PageBlock> blocks;

  ToolbarItem? item(String id) => toolbar.where((i) => i.id == id).firstOrNull;
  PageBlock? block(String id) => blocks.where((b) => b.id == id).firstOrNull;

  /// The list whose picked row is `{{selected.*}}`.
  ListBlock? get selectionList => blocks.whereType<ListBlock>().firstOrNull;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'toolbar': [for (final i in toolbar) i.toJson()],
        'blocks': [for (final b in blocks) b.toJson()],
        'selection': ?selectionList?.id,
      };
}

/// Parsed `pages:` plus everything wrong with it, in reading order.
class PagesConfig {
  const PagesConfig(this.pages, this.problems);

  static const empty = PagesConfig([], []);

  final List<DashboardPage> pages;
  final List<String> problems;

  DashboardPage? page(String id) => pages.where((p) => p.id == id).firstOrNull;

  /// Blocks to fetch again because [relPath] (project-relative) changed —
  /// a `watch:` match, or an html block's own file: page id → block ids.
  Map<String, List<String>> watching(String relPath) => {
        for (final page in pages)
          if (page.blocks
                  .where((b) => b.watch.any((g) => globToRegExp(g).hasMatch(relPath)) || (b is HtmlBlock && b.src == relPath))
                  .toList()
              case final blocks when blocks.isNotEmpty)
            page.id: [for (final b in blocks) b.id],
      };
}

/// Parse the raw `pages:` value of the merged config (see `project_config.dart`).
PagesConfig parsePages(Object? raw) {
  if (raw == null) return PagesConfig.empty;
  final problems = <String>[];
  if (raw is! List) return const PagesConfig([], ['pages: expected a list of pages']);
  final pages = <DashboardPage>[];
  for (var i = 0; i < raw.length; i++) {
    final page = _parsePage(raw[i], 'pages[$i]', problems);
    if (page == null) continue;
    if (pages.any((p) => p.id == page.id)) {
      problems.add('pages[$i]: page id "${page.id}" is used twice');
      continue;
    }
    pages.add(page);
  }
  return PagesConfig(pages, problems);
}

/// Who may use which placeholder: the selection everywhere but in the list
/// that makes it, a row only in that list's row buttons, a segment only in
/// a diff with segments, an input only in its own form's buttons.
class _Allowed {
  const _Allowed({this.selected = true, this.row = false, this.seg = false, this.inputs});
  final bool selected;
  final bool row;
  final bool seg;

  /// The form's field names; null outside a form.
  final Set<String>? inputs;
}

DashboardPage? _parsePage(Object? raw, String at, List<String> problems) {
  if (raw is! Map) {
    problems.add('$at: expected a map with id, title, toolbar, blocks');
    return null;
  }
  final id = '${raw['id'] ?? ''}';
  if (!isPageId(id)) {
    problems.add('$at: needs an id of letters, digits, - or _ (got "$id")');
    return null;
  }
  if (id == debugPageId) {
    problems.add('$at: "$debugPageId" is the built-in page — pick another id');
    return null;
  }
  final ids = <String>{};
  String? claim(Object? raw, String where) {
    final itemId = raw?.toString();
    if (itemId == null || !isPageId(itemId)) {
      problems.add('$where: needs an id of letters, digits, - or _ (got "${itemId ?? ''}")');
      return null;
    }
    if (!ids.add(itemId)) {
      problems.add('$id.$itemId: id is used twice in this page');
      return null;
    }
    return itemId;
  }

  final toolbar = <ToolbarItem>[];
  for (final (j, entry) in _entries(raw['toolbar'], '$id.toolbar', problems).indexed) {
    final item = _parseToolbarItem(entry, '$id.toolbar[$j]', claim, problems);
    if (item != null) toolbar.add(item);
  }
  final blocks = <PageBlock>[];
  var listSeen = false;
  for (final (j, entry) in _entries(raw['blocks'], '$id.blocks', problems).indexed) {
    // The first list makes the selection, so it can't depend on it.
    final makesSelection = entry.$1 == 'list' && !listSeen;
    final block = _parseBlock(entry, '$id.blocks[$j]', claim, problems, makesSelection: makesSelection);
    if (block is ListBlock) listSeen = true;
    if (block is HtmlBlock) {
      final unknown = block.actions.where((a) => toolbar.whereType<PageAction>().every((i) => i.id != a)).toList();
      if (unknown.isNotEmpty) {
        problems.add('$id.${block.id}.actions: no toolbar action ${unknown.map((a) => '"$a"').join(', ')} on this page');
        continue;
      }
    }
    if (block != null) blocks.add(block);
  }
  return DashboardPage(id: id, title: '${raw['title'] ?? id}', toolbar: toolbar, blocks: blocks);
}

/// The single-key maps of a `toolbar:`/`blocks:` list, as (kind, body).
List<(String, Map)> _entries(Object? raw, String at, List<String> problems) {
  if (raw == null) return const [];
  if (raw is! List) {
    problems.add('$at: expected a list');
    return const [];
  }
  final out = <(String, Map)>[];
  for (var i = 0; i < raw.length; i++) {
    final e = raw[i];
    if (e is Map && e.length == 1 && e.values.first is Map) {
      out.add(('${e.keys.first}', e.values.first as Map));
    } else {
      problems.add('$at[$i]: expected one entry like `- action: {id: …}`');
    }
  }
  return out;
}

ToolbarItem? _parseToolbarItem((String, Map) entry, String at,
    String? Function(Object?, String) claim, List<String> problems) {
  final (kind, m) = entry;
  if (kind != 'action' && kind != 'toggle') {
    problems.add('$at: unknown toolbar item "$kind" (action, toggle)');
    return null;
  }
  final id = claim(m['id'], at);
  if (id == null) return null;
  final where = '${at.split('.').first}.$id';
  if (kind == 'action') return _parseAction(m, id, where, const _Allowed(), problems);
  final common = _common(m, id, where, problems);
  if (common == null) return null;
  final (label, then, timeout) = common;
  const allowed = _Allowed();
  final state = _command(m['state'], '$where.state', allowed, problems);
  final on = _command(m['on'], '$where.on', allowed, problems);
  final off = _command(m['off'], '$where.off', allowed, problems);
  if (state == null || on == null || off == null) return null;
  return PageToggle(id: id, label: label, state: state, on: on, off: off, then: then, timeout: timeout);
}

PageAction? _parseAction(Map m, String id, String where, _Allowed allowed, List<String> problems) {
  final common = _common(m, id, where, problems);
  if (common == null) return null;
  final (label, then, timeout) = common;
  final confirm = m['confirm'] == true;
  if (m['openUrl'] != null) {
    if (m['run'] != null) {
      problems.add('$where: give run or openUrl, not both');
      return null;
    }
    if (then != Then.none) {
      problems.add('$where: then doesn\'t apply to openUrl');
      return null;
    }
    final url = m['openUrl'];
    // One argument: whatever fills its placeholders stays part of the URL.
    final openUrl = url is String && url.trim().isNotEmpty ? _command([url], '$where.openUrl', allowed, problems, program: false) : null;
    if (openUrl == null) {
      if (url is! String || url.trim().isEmpty) problems.add('$where.openUrl: expected a URL like "myapp://home?id={{row.id}}"');
      return null;
    }
    return PageAction(id: id, label: label, openUrl: openUrl, timeout: timeout, confirm: confirm);
  }
  final run = _command(m['run'], '$where.run', allowed, problems);
  if (run == null) return null;
  return PageAction(id: id, label: label, run: run, then: then, timeout: timeout, confirm: confirm);
}

/// label, then, timeout — shared by actions, toggles and row actions.
(String, Then, Duration)? _common(Map m, String id, String where, List<String> problems) {
  final then = Then.fromWire(m['then']);
  if (then == null) {
    problems.add('$where: then must be none, reload or restart (got "${m['then']}")');
    return null;
  }
  final timeout = _timeout(m['timeout'], where, problems);
  if (timeout == null) return null;
  return ('${m['label'] ?? id}', then, timeout);
}

PageBlock? _parseBlock((String, Map) entry, String at, String? Function(Object?, String) claim,
    List<String> problems, {required bool makesSelection}) {
  final (kind, m) = entry;
  if (!const {'output', 'list', 'diff', 'html', 'form'}.contains(kind)) {
    problems.add('$at: unknown block "$kind" (list, diff, html, form, output)');
    return null;
  }
  final id = claim(m['id'] ?? kind, at);
  if (id == null) return null;
  final where = '${at.split('.').first}.$id';
  final area = '${m['area'] ?? switch (kind) { 'list' => 'left', 'diff' || 'html' || 'form' => 'main', _ => 'bottom' }}';
  if (!blockAreas.contains(area)) {
    problems.add('$where: area must be left, main or bottom (got "$area")');
    return null;
  }
  if (kind == 'output') {
    final source = m['source'] ?? 'lastAction';
    if (source != 'lastAction') {
      problems.add('$where: source must be lastAction (got "$source")');
      return null;
    }
    return OutputBlock(id: id, area: area);
  }
  final title = '${m['title'] ?? id}';
  if (kind == 'form') return _parseForm(m, id, area, title, where, problems);
  final watch = _watch(m['watch'], '$where.watch', problems);
  if (watch == null) return null;
  if (kind == 'html') {
    final src = m['src'];
    if (src is! String || !_projectRelative(src) || !src.toLowerCase().endsWith('.html')) {
      problems.add('$where.src: expected a project-relative .html file (got "${src ?? ''}")');
      return null;
    }
    final run = m['run'] == null ? null : _command(m['run'], '$where.run', const _Allowed(), problems);
    if (m['run'] != null && run == null) return null;
    final actions = m['actions'] == null ? const <String>[] : _strings(m['actions']);
    if (actions == null) {
      problems.add('$where.actions: expected a list of toolbar action ids');
      return null;
    }
    return HtmlBlock(id: id, area: area, watch: watch, title: title, src: src, run: run, actions: actions);
  }
  if (kind == 'diff') {
    final segments = m['segments'] == null ? const <String>[] : _strings(m['segments']);
    if (segments == null) {
      problems.add('$where.segments: expected a list of names');
      return null;
    }
    final run = _command(m['run'], '$where.run', _Allowed(seg: segments.isNotEmpty), problems);
    if (run == null) return null;
    return DiffBlock(id: id, area: area, watch: watch, run: run, title: title, segments: segments);
  }
  final run = _command(m['run'], '$where.run', _Allowed(selected: !makesSelection), problems);
  if (run == null) return null;
  final columnSpecs = m['columns'] == null ? const <String>[] : _strings(m['columns']);
  if (columnSpecs == null) {
    problems.add('$where.columns: expected a list like [name, local:chip, changes:count]');
    return null;
  }
  final columns = <ListColumn>[];
  for (final c in columnSpecs) {
    final parts = c.split(':');
    final format = parts.length > 1 ? parts.sublist(1).join(':') : 'text';
    if (parts.first.isEmpty || !columnFormats.contains(format)) {
      problems.add('$where.columns: "$c" should be name or name:text|chip|count');
      return null;
    }
    columns.add(ListColumn(parts.first, format));
  }
  final rowActions = <PageAction>[];
  final rowIds = <String>{};
  for (final (j, e) in _entries(m['rowActions'], '$where.rowActions', problems).indexed) {
    final (k, body) = e;
    final rid = body['id']?.toString();
    if (k != 'action' || rid == null || !isPageId(rid) || !rowIds.add(rid)) {
      problems.add('$where.rowActions[$j]: expected `- action: {id: …, run: […]}` with an id unique in this list');
      continue;
    }
    final a = _parseAction(body, rid, '$where.$rid', _Allowed(selected: !makesSelection, row: true), problems);
    if (a != null) rowActions.add(a);
  }
  return ListBlock(
    id: id,
    area: area,
    watch: watch,
    run: run,
    title: title,
    key: m['key']?.toString(),
    columns: columns,
    rowActions: rowActions,
  );
}

FormBlock? _parseForm(Map m, String id, String area, String title, String where, List<String> problems) {
  final rawFields = m['fields'];
  if (rawFields is! List || rawFields.isEmpty) {
    problems.add('$where.fields: expected a list like [{name: url, label: URL}]');
    return null;
  }
  final fields = <FormField>[];
  for (final (i, f) in rawFields.indexed) {
    final name = f is Map ? f['name']?.toString() : null;
    if (name == null || !isPageId(name) || fields.any((x) => x.name == name)) {
      problems.add('$where.fields[$i]: needs a name of letters, digits, - or _, unique in this form');
      return null;
    }
    fields.add(FormField(
      name: name,
      label: '${(f as Map)['label'] ?? name}',
      placeholder: f['placeholder']?.toString(),
      initial: f['default']?.toString(),
    ));
  }
  final allowed = _Allowed(inputs: {for (final f in fields) f.name});
  final actions = <PageAction>[];
  for (final (j, e) in _entries(m['actions'], '$where.actions', problems).indexed) {
    final (k, body) = e;
    final aid = body['id']?.toString();
    if (k != 'action' || aid == null || !isPageId(aid) || actions.any((a) => a.id == aid)) {
      problems.add('$where.actions[$j]: expected `- action: {id: …, run: […]}` with an id unique in this form');
      continue;
    }
    final a = _parseAction(body, aid, '$where.$aid', allowed, problems);
    if (a != null) actions.add(a);
  }
  if (actions.isEmpty) {
    problems.add('$where.actions: a form needs at least one action');
    return null;
  }
  return FormBlock(id: id, area: area, title: title, fields: fields, actions: actions);
}

/// [program] is false for an openUrl, whose one argument is the URL itself.
PageCommand? _command(Object? v, String at, _Allowed allowed, List<String> problems, {bool program = true}) {
  PageCommand? command;
  if (v is String && v.trim().isNotEmpty) {
    if (v.contains('{{')) {
      problems.add('$at: placeholders work only in the [program, arg, …] form — in a shell string '
          'a value could run as code');
      return null;
    }
    command = PageCommand.shell(v);
  } else if (v is List && v.isNotEmpty && v.every((e) => e is String || e is num || e is bool)) {
    final argv = [for (final e in v) '$e'];
    if (program && argv.first.contains('{{')) {
      // A value would pick what runs, not just what it's given.
      problems.add('$at: the program can\'t contain a placeholder — put values in the arguments after it');
      return null;
    }
    if (argv.first.isNotEmpty) command = PageCommand.argv(argv);
  }
  if (command == null) {
    problems.add(v == null
        ? '$at: missing — give a command as [program, arg, …] or a shell string'
        : '$at: expected [program, arg, …] or a shell string');
    return null;
  }
  for (final arg in command.argv ?? const <String>[]) {
    for (final m in _braces.allMatches(arg)) {
      final p = _placeholder.matchAsPrefix(m.group(0)!);
      final kind = p?.group(1);
      final name = p?.group(2);
      final hasName = name != null;
      final unknown = 'unknown placeholder ${m.group(0)} (selected.<col>, row.<col>, seg, input.<field>)';
      final String? why = switch (kind) {
        null => unknown,
        'selected' when !hasName => '{{selected}} needs a column: {{selected.<col>}}',
        'row' when !hasName => '{{row}} needs a column: {{row.<col>}}',
        'input' when !hasName => '{{input}} needs a field: {{input.<field>}}',
        'seg' when hasName => '{{seg}} takes no column',
        'selected' when !allowed.selected => '{{selected.*}} can\'t be used by the list that makes the selection',
        'row' when !allowed.row => '{{row.*}} only works in a list\'s rowActions',
        'seg' when !allowed.seg => '{{seg}} only works in a diff block with segments',
        'input' when allowed.inputs == null => '{{input.*}} only works in a form\'s actions',
        'input' when !allowed.inputs!.contains(name) => 'no field "$name" in this form',
        'selected' || 'row' || 'seg' || 'input' => null,
        _ => unknown,
      };
      if (why != null) {
        problems.add('$at: $why');
        return null;
      }
    }
  }
  return command;
}

List<String>? _strings(Object? v) => v is List && v.every((e) => e is String) ? v.cast<String>() : null;

bool _projectRelative(String path) => path.isNotEmpty && !path.startsWith('/') && !path.split('/').contains('..');

List<String>? _watch(Object? v, String at, List<String> problems) {
  if (v == null) return const [];
  final globs = v is String ? [v] : _strings(v);
  if (globs == null || globs.any((g) => !_projectRelative(g))) {
    problems.add('$at: expected project-relative globs like "templates/**"');
    return null;
  }
  return globs;
}

Duration? _timeout(Object? v, String at, List<String> problems) {
  if (v == null) return defaultTimeout;
  final s = v is int ? v : int.tryParse('$v');
  if (s == null || s <= 0) {
    problems.add('$at: timeout must be a positive number of seconds (got "$v")');
    return null;
  }
  return Duration(seconds: s);
}
