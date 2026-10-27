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
/// values a request does carry (the selected row, a segment, the checked
/// rows) fill placeholders such as `{{selected.name}}`, each inside its own
/// argument — or, for `{{checked.name...}}`, as arguments of their own.
///
/// Parsing is pure and collects every problem instead of failing: one typo
/// hides one item, not the whole page.
library;

/// Page and item ids: they appear in URLs and in `emu run <page>.<item>`.
final _id = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]*$');

bool isPageId(String s) => _id.hasMatch(s);

/// The built-in page the dashboard always shows first.
const debugPageId = 'debug';

/// `{{selected.<column>}}`, `{{row.<column>}}`, `{{seg}}`, `{{input.<field>}}`,
/// `{{checked.<column>}}`, `{{checked.<column>...}}`, `{{checked.count}}` —
/// the checked ones also as `{{<list>.checked.…}}`. Groups: list, kind,
/// column, `...`.
final _placeholder = RegExp(
    r'\{\{\s*(?:([A-Za-z0-9][A-Za-z0-9_-]*)\.(?=checked\.))?([A-Za-z]+)(?:\.([A-Za-z0-9_-]+))?(\.\.\.)?\s*\}\}');
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

  /// The placeholders used, as `selected.name`, `row.id`, `seg`, `input.url`,
  /// `checked.name...`, `templates.checked.count`.
  Set<String> get placeholders => {
        for (final arg in argv ?? const <String>[])
          for (final m in _placeholder.allMatches(arg)) _key(m),
      };

  /// The lists whose checked rows this command reads; an unqualified
  /// `{{checked.*}}` is [checkList]'s (the page's one list with `check:`).
  Set<String> checkedLists(String? checkList) => {for (final arg in argv ?? const <String>[]) ..._checkedIn(arg, checkList)};

  static Set<String> _checkedIn(String text, String? checkList) => {
        for (final m in _placeholder.allMatches(text))
          if (m.group(2) == 'checked') ?(m.group(1) ?? checkList),
      };

  /// This command with every placeholder filled from [vars] (keys as in
  /// [placeholders]) and [checked] (list id → its checked rows; an
  /// unqualified `{{checked.*}}` reads [checkList]'s). A value replaces its
  /// placeholder inside that one argument — spaces or `;` in it are never
  /// split or run; `{{checked.<col>...}}` becomes one argument per checked
  /// row, and none for no rows. Throws [MissingValue] for the first
  /// placeholder there is no value for.
  PageCommand fill(Map<String, String> vars,
      {Map<String, List<Map<String, String>>> checked = const {}, String? checkList}) {
    final a = argv;
    if (a == null) return this;
    return PageCommand.argv([
      for (final arg in a)
        if (_placeholder.matchAsPrefix(arg) case final m? when m.group(4) != null && m.end == arg.length)
          for (final row in _rows(m, checked, checkList)) _column(row, m)
        else
          _fillText(arg, vars, checked, checkList),
    ]);
  }

  static List<Map<String, String>> _rows(Match m, Map<String, List<Map<String, String>>> checked, String? checkList) =>
      checked[m.group(1) ?? checkList] ?? const [];

  static String _column(Map<String, String> row, Match m) => row[m.group(3)] ?? (throw MissingValue(_key(m)));

  /// [text] with each placeholder replaced by its one value; a checked
  /// column is the checked rows' values joined with commas.
  static String _fillText(
          String text, Map<String, String> vars, Map<String, List<Map<String, String>>> checked, String? checkList) =>
      text.replaceAllMapped(_placeholder, (m) {
        if (m.group(2) != 'checked') return vars[_key(m)] ?? (throw MissingValue(_key(m)));
        final r = _rows(m, checked, checkList);
        return m.group(3) == 'count' ? '${r.length}' : [for (final row in r) _column(row, m)].join(',');
      });

  static String _key(Match m) => [m.group(1), m.group(2), m.group(3)].nonNulls.join('.') + (m.group(4) ?? '');
}

final _checkedKey = RegExp(r'^(?:[^.]+\.)?checked\.');

/// A placeholder with no value in the request, e.g. no row selected yet.
class MissingValue implements Exception {
  MissingValue(this.key);
  final String key;

  /// `selected`, `row`, `seg`, `input` or `checked`.
  String get kind => _checkedKey.hasMatch(key) ? 'checked' : key.split('.').first;

  @override
  String toString() => 'no value for {{$key}}';
}

final _plainArg = RegExp(r'^[A-Za-z0-9_@%+=:,./-]+$');

/// [s] quoted for `sh` when it needs to be.
String shellQuote(String s) => _plainArg.hasMatch(s) ? s : "'${s.replaceAll("'", r"'\''")}'";

final _globs = <String, RegExp>{};

/// A `watch:` glob, relative to the project root, as a RegExp over the
/// project-relative path of a changed file: `**` spans directories (`**/`
/// also none), `*` and `?` stay within one. Compiled once per glob — a save
/// burst checks every changed path against every glob.
RegExp globToRegExp(String glob) => _globs.putIfAbsent(glob, () => _compileGlob(glob));

RegExp _compileGlob(String glob) {
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

/// How an action asks first (`confirm:`): `true`, a message, or a map of
/// these. Whatever it says, the dialog also shows the exact command — what
/// it shows is what runs.
class ConfirmSpec {
  const ConfirmSpec({this.title, this.message, this.danger = false, this.button, this.preview, this.allowOnPreviewError = false});

  /// null: `Run “<label>”?`.
  final String? title;

  /// Text under the title; may hold placeholders, filled as plain text.
  final String? message;

  /// Hard to undo: the Run button stands out, and Enter alone doesn't run it.
  final bool danger;

  /// The Run button's text; null: `Run`.
  final String? button;

  /// Runs before the dialog opens; its stdout shows in the dialog, and a
  /// failure keeps Run disabled unless [allowOnPreviewError].
  final PageCommand? preview;
  final bool allowOnPreviewError;

  /// The placeholders used, as in [PageCommand.placeholders].
  Set<String> get placeholders => {
        for (final text in [?title, ?message])
          for (final m in _placeholder.allMatches(text)) PageCommand._key(m),
        ...?preview?.placeholders,
      };

  /// The lists whose checked rows the title, message and preview read, as
  /// in [PageCommand.checkedLists].
  Set<String> checkedLists(String? checkList) => {
        for (final text in [?title, ?message]) ...PageCommand._checkedIn(text, checkList),
        ...?preview?.checkedLists(checkList),
      };

  /// [text] with its placeholders filled from [vars] and [checked], as plain
  /// text (`{{checked.count}}`, a checked column comma-joined). Throws
  /// [MissingValue] like [PageCommand.fill].
  static String fillText(String text, Map<String, String> vars,
          {Map<String, List<Map<String, String>>> checked = const {}, String? checkList}) =>
      PageCommand._fillText(text, vars, checked, checkList);
}

/// Runs [run] when pressed — a toolbar button, a button on each row of a list
/// (`rowActions`) or under a form. Instead of a command it may open
/// [openUrl] on the device, the way `emu open-url` does. With [confirm], the
/// dashboard shows what will run and asks first, and `emu run` asks too (or
/// takes `--yes`).
class PageAction extends ToolbarItem {
  const PageAction({
    required super.id,
    required super.label,
    this.run,
    this.openUrl,
    super.then = Then.none,
    super.timeout = defaultTimeout,
    this.confirm,
    this.needsChecked,
    this.bulk = false,
    this.auto,
    this.interactive = false,
    this.askTimeout = defaultAskTimeout,
  }) : assert((run == null) != (openUrl == null));

  final PageCommand? run;

  /// The deep link to open, as a one-argument command (so placeholders fill
  /// the same way).
  final PageCommand? openUrl;

  /// null: runs without asking.
  final ConfirmSpec? confirm;

  /// `needs: checked`: the list that must have a checked row before this runs.
  final String? needsChecked;

  /// A row button that also runs once per checked row, from the list's head
  /// (`bulk: true`). The dashboard does the rounds; each is a plain row run.
  final bool bulk;

  /// `auto:` — the server also runs it when a file it watches changes, while
  /// it is switched on. Toolbar actions only, with nothing to fill or ask.
  final AutoRun? auto;

  /// `interactive: true` — the command may ask while it runs: a stdout line
  /// `::emu-ask {…}` is taken out of the output and asked (in the dashboard
  /// tab that started it, or the terminal of `emu run`), and the answer goes
  /// to its stdin as one line of JSON. Without it such a line is plain output.
  final bool interactive;

  /// How long one question waits for an answer before it is answered null.
  final Duration askTimeout;

  /// What it does, for people.
  String get display => run?.display ?? 'open-url ${openUrl!.argv!.single}';

  Set<String> get placeholders => {...(run ?? openUrl)!.placeholders, ...?confirm?.placeholders};

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'action',
        'id': id,
        'label': label,
        'command': display,
        if (openUrl != null) 'openUrl': openUrl!.argv!.single,
        'uses': placeholders.toList(),
        'then': then.name,
        'confirm': confirm != null,
        if (confirm?.danger == true) 'danger': true,
        'preview': ?confirm?.preview?.display,
        'needsChecked': ?needsChecked,
        if (bulk) 'bulk': true,
        'auto': ?auto?.toJson(),
        if (interactive) 'interactive': true,
      };
}

const defaultAutoDebounce = Duration(milliseconds: 400);

/// When an action runs on its own (`auto:`): a change to a project file that
/// matches [watch], once the changes have rested for [debounce]. [on] is
/// where the dashboard's switch starts; the server keeps it per project.
class AutoRun {
  const AutoRun({required this.watch, this.debounce = defaultAutoDebounce, this.on = false});

  final List<String> watch;
  final Duration debounce;
  final bool on;

  bool matches(String relPath) => watch.any((g) => globToRegExp(g).hasMatch(relPath));

  Map<String, dynamic> toJson() => {'watch': watch, 'debounce': debounce.inMilliseconds, 'on': on};
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

/// How long an `interactive:` action's question waits for an answer (`askTimeout:`).
const defaultAskTimeout = Duration(seconds: 120);

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

/// A text column's widest, as `<n>em`, `<n>ch` or `<n>px`.
final _columnWidth = RegExp(r'^\d+(?:\.\d+)?(?:em|ch|px)$');

class ListColumn {
  const ListColumn(this.key, [this.format = 'text', this.width, this.clipStart = false]);
  final String key;
  final String format;

  /// How wide a text column grows before a longer value is cut with an
  /// ellipsis (`40em`); null: the dashboard's default.
  final String? width;

  /// Cut a long text value at its start, so the end of a path stays in view.
  final bool clipStart;

  Map<String, dynamic> toJson() => {'key': key, 'format': format, 'width': ?width, if (clipStart) 'clip': 'start'};
}

/// A `columns:` entry: `name`, `name:text|chip|count`, and for text a width
/// (`40em`) and `start`, in any order (`path:start` is `path:text:start`).
ListColumn? parseColumn(String spec) {
  final parts = spec.split(':');
  if (parts.first.isEmpty) return null;
  final named = parts.length > 1 && columnFormats.contains(parts[1]);
  final format = named ? parts[1] : 'text';
  String? width;
  var start = false;
  for (final mod in parts.skip(named ? 2 : 1)) {
    if (format != 'text') return null;
    if (mod == 'start' && !start) {
      start = true;
    } else if (_columnWidth.hasMatch(mod) && width == null) {
      width = mod;
    } else {
      return null;
    }
  }
  return ListColumn(parts.first, format, width, start);
}

/// How a list's rows get checked (`check:`): by the dashboard, which keeps
/// the checked keys per browser (`check: true`), or by the tool — the
/// [column] of each row says whether it is checked and [toggle] flips it.
class ListCheck {
  const ListCheck({this.column, this.toggle});

  final String? column;

  /// Runs with the row in `{{row.<col>}}`; as a row action its id is `check`.
  final PageAction? toggle;

  Map<String, dynamic> toJson() => {
        'column': ?column,
        'toggle': ?toggle?.display,
      };
}

/// A list drawn as folders (`tree:`): the values of [columns], each split at
/// `/`, make a row's path — its last part names the row, the parts before it
/// are folders. Folders deeper than [open] levels start closed.
class ListTree {
  const ListTree(this.columns, {this.open = 0});
  final List<String> columns;
  final int open;

  Map<String, dynamic> toJson() => {'columns': columns, 'open': open};
}

/// The order a list starts in (`sort: minVer:desc`); clicking a column head
/// in the dashboard changes it.
class ListSort {
  const ListSort(this.column, {this.descending = false});
  final String column;
  final bool descending;

  Map<String, dynamic> toJson() => {'key': column, 'dir': descending ? 'desc' : 'asc'};
}

/// Whether a `check.column` value means checked: true, a non-zero number,
/// or a word like yes/on/checked.
bool isCheckedValue(Object? v) =>
    v == true ||
    (v is num && v != 0) ||
    (v is String && RegExp(r'^(true|yes|y|on|1|checked)$', caseSensitive: false).hasMatch(v.trim()));

/// A table of the JSON array of objects [run] prints. The first list on a
/// page holds the page's selection: picking a row fills `{{selected.<col>}}`
/// for the other blocks and the toolbar. [rowActions] are buttons on every
/// row, with that row in `{{row.<col>}}`. With [check], rows can also be
/// checked — many at once — for `{{checked.<col>...}}` in the page's actions.
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
    this.check,
    this.sort,
    this.tree,
  });

  final PageCommand run;
  final String title;

  /// The column that tells rows apart (a selection survives a refresh by it);
  /// null: the first column.
  final String? key;

  /// Empty: every field of the first row, as text.
  final List<ListColumn> columns;
  final List<PageAction> rowActions;
  final ListCheck? check;

  /// The starting order; null: as the command prints the rows.
  final ListSort? sort;

  /// Draw the rows as folders; null: a flat table.
  final ListTree? tree;

  @override
  PageCommand get command => run;

  PageAction? rowAction(String id) =>
      id == 'check' && check?.toggle != null ? check!.toggle : rowActions.where((a) => a.id == id).firstOrNull;

  /// The value that tells [row] apart: [key], else the first column, else
  /// the row's first field.
  String? rowKey(Map<String, dynamic> row) {
    final col = key ?? columns.firstOrNull?.key ?? row.keys.firstOrNull;
    final v = row[col];
    return v == null ? null : v is String ? v : v is num || v is bool ? '$v' : null;
  }

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
        'check': ?check?.toJson(),
        'sort': ?sort?.toJson(),
        'tree': ?tree?.toJson(),
        'watch': watch,
      };
}

/// The unified diff [run] prints, rendered like the Changes tab; output that
/// isn't a diff shows as text. With [segments], a switch picks what to compare
/// against: `{{seg}}`.
class DiffBlock extends PageBlock {
  const DiffBlock({
    required super.id,
    super.area = 'main',
    super.watch,
    required this.run,
    required this.title,
    this.segments = const [],
    this.optional = false,
    this.hide,
  });

  final PageCommand run;
  final String title;
  final List<String> segments;

  /// `segments: {optional: true}`: none is picked at first and a click turns
  /// the picked one off — `{{seg}}` is then empty.
  final bool optional;

  /// `segments: {hide: "{{selected.env}}"}`: the segment equal to this value,
  /// filled from the picked row, isn't offered (a branch compared with itself).
  final String? hide;

  @override
  PageCommand get command => run;

  /// The placeholders [hide] reads, as in [PageCommand.placeholders].
  Set<String> get _hidePlaceholders => {for (final m in _placeholder.allMatches(hide ?? '')) PageCommand._key(m)};

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'diff',
        'id': id,
        'area': area,
        'title': title,
        'command': run.display,
        // The picked row also decides which segments show.
        'uses': {...run.placeholders, ..._hidePlaceholders}.toList(),
        'segments': segments,
        if (optional) 'segmentsOptional': true,
        'segmentsHide': ?hide,
        'watch': watch,
      };
}

/// A project HTML file in a sandboxed frame, for what lists and diffs can't
/// show (a value tree, an image preview). The frame gets [run]'s output as
/// data and may ask the dashboard to run the toolbar items in [actions] and
/// its own [blockActions], passing [inputs] — nothing else: no network, no
/// access to the dashboard.
class HtmlBlock extends PageBlock {
  const HtmlBlock({
    required super.id,
    super.area = 'main',
    super.watch,
    required this.title,
    required this.src,
    this.run,
    this.actions = const [],
    this.blockActions = const [],
    this.inputs = const [],
  });

  final String title;

  /// Project-relative path of a self-contained HTML file.
  final String src;

  /// Prints the frame's data (JSON, or any text); null: the frame gets none.
  final PageCommand? run;

  /// Toolbar items the frame may run (`emu.run(id)`, or the older
  /// `postMessage({type: 'emu:action', id})`).
  final List<String> actions;

  /// Actions of this block alone (`- action: {…}` under `actions:`): not in
  /// the toolbar, run at `frames/<block>/<action>`.
  final List<PageAction> blockActions;

  /// The `{{input.<name>}}` values the frame may pass with `emu.run`; any
  /// other name it sends is dropped.
  final List<String> inputs;

  PageAction? action(String id) => blockActions.where((a) => a.id == id).firstOrNull;

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
        'blockActions': [for (final a in blockActions) a.toJson()],
        'inputs': inputs,
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
/// dashboard keeps them per browser. With no fields it's a button panel
/// (`panel:` is the same block).
class FormBlock extends PageBlock {
  const FormBlock({
    required super.id,
    super.area = 'main',
    required this.title,
    this.note,
    this.fields = const [],
    required this.actions,
  });

  final String title;

  /// A line of text under the title: what the buttons do.
  final String? note;
  final List<FormField> fields;
  final List<PageAction> actions;

  PageAction? action(String id) => actions.where((a) => a.id == id).firstOrNull;

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'form',
        'id': id,
        'area': area,
        'title': title,
        'note': ?note,
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

  /// The lists with `check:`.
  Iterable<ListBlock> get checkLists => blocks.whereType<ListBlock>().where((b) => b.check != null);

  /// The list an unqualified `{{checked.*}}` reads: the page's only one with
  /// `check:`.
  String? get checkList => checkLists.length == 1 ? checkLists.first.id : null;

  /// The lists whose checked rows [action] reads or needs.
  Set<String> checkedListsOf(PageAction action) => {
        ...(action.run ?? action.openUrl)!.checkedLists(checkList),
        ...?action.confirm?.checkedLists(checkList),
        ?action.needsChecked,
      };

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
/// a diff with segments, an input only in its own form's buttons or an html
/// block's own actions, the checked rows only in buttons (toolbar, row and
/// form actions).
class _Allowed {
  const _Allowed(
      {this.selected = true, this.row = false, this.seg = false, this.inputs, this.inputsOf = 'form', this.checks});
  final bool selected;
  final bool row;
  final bool seg;

  /// The form's field names or the html block's `inputs:`; null elsewhere.
  final Set<String>? inputs;

  /// What declares [inputs]: `form` or `html`.
  final String inputsOf;

  /// The page's lists with `check:`; null where `{{checked.*}}` can't be used.
  final Set<String>? checks;

  _Allowed get noChecks => _Allowed(selected: selected, row: row, seg: seg, inputs: inputs, inputsOf: inputsOf);
}

/// The list an unqualified (null) [list] means in `{{checked.*}}` or
/// `needs: checked`, or why there is none.
(String?, String?) _checkTarget(String? list, Set<String> checks) {
  if (list != null) return checks.contains(list) ? (list, null) : (null, 'no list "$list" with check: on this page');
  return switch (checks.length) {
    0 => (null, 'no list on this page has check: — add check: true to one'),
    1 => (checks.single, null),
    _ => (null, 'several lists have check: — say which, as {{<list>.checked.<col>}} or needs: <list>.checked'),
  };
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

  // The lists with check:, known up front: any action may read their rows.
  final checks = <String>{
    if (raw['blocks'] case final List bs)
      for (final b in bs)
        if (b case {'list': final Map m} when m['check'] != null && m['check'] != false) '${m['id'] ?? 'list'}',
  };
  final toolbar = <ToolbarItem>[];
  for (final (j, entry) in _entries(raw['toolbar'], '$id.toolbar', problems).indexed) {
    final item = _parseToolbarItem(entry, '$id.toolbar[$j]', claim, problems, checks);
    if (item != null) toolbar.add(item);
  }
  final blocks = <PageBlock>[];
  var listSeen = false;
  for (final (j, entry) in _entries(raw['blocks'], '$id.blocks', problems).indexed) {
    // The first list makes the selection, so it can't depend on it.
    final makesSelection = entry.$1 == 'list' && !listSeen;
    final block = _parseBlock(entry, '$id.blocks[$j]', claim, problems, checks, makesSelection: makesSelection);
    if (block is ListBlock) listSeen = true;
    if (block is HtmlBlock) {
      final unknown = block.actions.where((a) => toolbar.whereType<PageAction>().every((i) => i.id != a)).toList();
      if (unknown.isNotEmpty) {
        problems.add('$id.${block.id}.actions: no toolbar action ${unknown.map((a) => '"$a"').join(', ')} on this page');
        continue;
      }
      // The frame names either kind by id alone, so one id means one thing.
      final both = block.blockActions.where((a) => toolbar.any((i) => i.id == a.id)).toList();
      if (both.isNotEmpty) {
        problems.add('$id.${block.id}.actions: ${both.map((a) => '"${a.id}"').join(', ')} is also a toolbar id — '
            'name the block\'s own action differently');
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
    String? Function(Object?, String) claim, List<String> problems, Set<String> checks) {
  final (kind, m) = entry;
  if (kind != 'action' && kind != 'toggle') {
    problems.add('$at: unknown toolbar item "$kind" (action, toggle)');
    return null;
  }
  final id = claim(m['id'], at);
  if (id == null) return null;
  final where = '${at.split('.').first}.$id';
  if (kind == 'action') return _parseAction(m, id, where, _Allowed(checks: checks), problems, toolbar: true);
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

PageAction? _parseAction(Map m, String id, String where, _Allowed allowed, List<String> problems,
    {bool bulk = false, bool toolbar = false}) {
  final common = _common(m, id, where, problems);
  if (common == null) return null;
  final (label, then, timeout) = common;
  final (confirm, confirmOk) = _confirm(m['confirm'], '$where.confirm', allowed, problems);
  if (!confirmOk) return null;
  AutoRun? auto;
  if (m['auto'] != null) {
    // It runs with no one there: nothing to fill in, nothing to ask.
    final String? why = !toolbar
        ? 'only toolbar actions run on their own'
        : m['openUrl'] != null
            ? 'works with run:, not openUrl'
            : confirm != null
                ? 'an action that asks first (confirm) can\'t run on its own'
                : m['needs'] != null
                    ? 'an action that runs on its own has no checked rows — drop needs'
                    : null;
    if (why != null) {
      problems.add('$where.auto: $why');
      return null;
    }
    auto = _parseAuto(m['auto'], '$where.auto', problems);
    if (auto == null) return null;
  }
  final interactive = m['interactive'] ?? false;
  if (interactive is! bool) {
    problems.add('$where.interactive: expected true or false');
    return null;
  }
  Duration askTimeout = defaultAskTimeout;
  if (m['askTimeout'] != null) {
    if (!interactive) {
      problems.add('$where.askTimeout: applies to an action with interactive: true');
      return null;
    }
    final t = _timeout(m['askTimeout'], '$where.askTimeout', problems, name: 'askTimeout');
    if (t == null) return null;
    askTimeout = t;
  }
  String? needsChecked;
  if (m['needs'] != null) {
    final needs = '${m['needs']}';
    final list = needs == 'checked' ? null : needs.endsWith('.checked') ? needs.substring(0, needs.length - 8) : '';
    final checks = allowed.checks;
    final (target, why) = list == '' || checks == null ? (null, 'needs takes checked or <list>.checked') : _checkTarget(list, checks);
    if (target == null) {
      problems.add('$where.needs: $why');
      return null;
    }
    needsChecked = target;
  }
  if (m['openUrl'] != null) {
    if (m['run'] != null) {
      problems.add('$where: give run or openUrl, not both');
      return null;
    }
    if (then != Then.none) {
      problems.add('$where: then doesn\'t apply to openUrl');
      return null;
    }
    if (interactive) {
      problems.add('$where: interactive works with run:, not openUrl');
      return null;
    }
    final url = m['openUrl'];
    // One argument: whatever fills its placeholders stays part of the URL.
    final openUrl = url is String && url.trim().isNotEmpty ? _command([url], '$where.openUrl', allowed, problems, program: false) : null;
    if (openUrl == null) {
      if (url is! String || url.trim().isEmpty) problems.add('$where.openUrl: expected a URL like "myapp://home?id={{row.id}}"');
      return null;
    }
    return PageAction(
        id: id, label: label, openUrl: openUrl, timeout: timeout, confirm: confirm, needsChecked: needsChecked, bulk: bulk);
  }
  final run = _command(m['run'], '$where.run', allowed, problems);
  if (run == null) return null;
  if (auto != null && run.placeholders.isNotEmpty) {
    problems.add('$where.auto: an action that runs on its own has no pick, row or input to fill '
        '${run.placeholders.map((k) => '{{$k}}').join(', ')} with');
    return null;
  }
  if (auto != null && interactive) {
    problems.add('$where.auto: an action that runs on its own has no one to answer what it asks — '
        'its questions would all be answered null; drop interactive or auto');
    return null;
  }
  return PageAction(
      id: id,
      label: label,
      run: run,
      then: then,
      timeout: timeout,
      confirm: confirm,
      needsChecked: needsChecked,
      bulk: bulk,
      auto: auto,
      interactive: interactive,
      askTimeout: askTimeout);
}

/// `auto: {watch: [globs], debounce: <ms>, on: true|false}`.
AutoRun? _parseAuto(Object? v, String at, List<String> problems) {
  if (v is! Map || v.keys.any((k) => !const {'watch', 'debounce', 'on'}.contains(k))) {
    problems.add('$at: expected {watch: ["templates/**"], debounce: <ms>, on: true|false}');
    return null;
  }
  final watch = _watch(v['watch'], '$at.watch', problems);
  if (watch == null) return null;
  if (watch.isEmpty) {
    problems.add('$at.watch: say which project files start it, like "templates/**"');
    return null;
  }
  final debounce = v['debounce'] ?? defaultAutoDebounce.inMilliseconds;
  if (debounce is! int || debounce < 0) {
    problems.add('$at.debounce: expected milliseconds (got "$debounce")');
    return null;
  }
  final on = v['on'] ?? false;
  if (on is! bool) {
    problems.add('$at.on: expected true or false');
    return null;
  }
  return AutoRun(watch: watch, debounce: Duration(milliseconds: debounce), on: on);
}

const _confirmKeys = {'title', 'message', 'danger', 'button', 'preview', 'allowOnPreviewError'};

/// `confirm:` → (spec, ok): `true`, a message, or a map of [_confirmKeys].
(ConfirmSpec?, bool) _confirm(Object? v, String at, _Allowed allowed, List<String> problems) {
  if (v == null || v == false) return (null, true);
  if (v == true) return (const ConfirmSpec(), true);
  if (v is String) {
    if (!_textPlaceholders(v, at, allowed, problems)) return (null, false);
    return (ConfirmSpec(message: v.trim().isEmpty ? null : v), true);
  }
  if (v is! Map) {
    problems.add('$at: expected true, a message, or a map with ${_confirmKeys.join(', ')}');
    return (null, false);
  }
  final unknown = v.keys.where((k) => !_confirmKeys.contains(k)).toList();
  if (unknown.isNotEmpty) {
    problems.add('$at: unknown ${unknown.map((k) => '"$k"').join(', ')} (${_confirmKeys.join(', ')})');
    return (null, false);
  }
  for (final key in const ['title', 'message', 'button']) {
    if (v[key] != null && v[key] is! String && v[key] is! num) {
      problems.add('$at.$key: expected text');
      return (null, false);
    }
  }
  for (final key in const ['danger', 'allowOnPreviewError']) {
    if (v[key] != null && v[key] is! bool) {
      problems.add('$at.$key: expected true or false');
      return (null, false);
    }
  }
  String? text(String key) => v[key] == null || '${v[key]}'.trim().isEmpty ? null : '${v[key]}';
  final title = text('title'), message = text('message'), button = text('button');
  for (final (key, t) in [('title', title), ('message', message)]) {
    if (t != null && !_textPlaceholders(t, '$at.$key', allowed, problems)) return (null, false);
  }
  if (button != null && button.contains('{{')) {
    problems.add('$at.button: placeholders work only in title and message');
    return (null, false);
  }
  final preview = v['preview'] == null ? null : _command(v['preview'], '$at.preview', allowed, problems);
  if (v['preview'] != null && preview == null) return (null, false);
  return (
    ConfirmSpec(
      title: title,
      message: message,
      danger: v['danger'] == true,
      button: button,
      preview: preview,
      allowOnPreviewError: v['allowOnPreviewError'] == true,
    ),
    true
  );
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
    List<String> problems, Set<String> checks, {required bool makesSelection}) {
  final (kind, m) = entry;
  if (!const {'output', 'list', 'diff', 'html', 'form', 'panel'}.contains(kind)) {
    problems.add('$at: unknown block "$kind" (list, diff, html, form, panel, output)');
    return null;
  }
  final id = claim(m['id'] ?? kind, at);
  if (id == null) return null;
  final where = '${at.split('.').first}.$id';
  final area = '${m['area'] ?? switch (kind) { 'list' => 'left', 'diff' || 'html' || 'form' || 'panel' => 'main', _ => 'bottom' }}';
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
  if (kind == 'form' || kind == 'panel') {
    return _parseForm(m, id, area, title, where, problems, checks, panel: kind == 'panel');
  }
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
    return _parseHtml(m, id, area, watch, title, src, run, where, problems);
  }
  if (kind == 'diff') {
    // `segments: [a, b]`, or `{values: [a, b], optional: true, hide: "{{selected.env}}"}`.
    final raw = m['segments'];
    final spec = raw is Map ? raw : null;
    final segments = raw == null ? const <String>[] : _strings(spec != null ? spec['values'] : raw);
    final optional = spec?['optional'] ?? false;
    final hide = spec?['hide'];
    if (segments == null ||
        (spec != null && (segments.isEmpty || spec.keys.any((k) => !const {'values', 'optional', 'hide'}.contains(k)))) ||
        optional is! bool ||
        (hide != null && hide is! String)) {
      problems.add('$where.segments: expected a list of names, or {values: [a, b], optional: true, hide: "{{selected.<col>}}"}');
      return null;
    }
    if (hide is String && !_textPlaceholders(hide, '$where.segments.hide', const _Allowed(), problems)) return null;
    final run = _command(m['run'], '$where.run', _Allowed(seg: segments.isNotEmpty), problems);
    if (run == null) return null;
    return DiffBlock(
        id: id, area: area, watch: watch, run: run, title: title, segments: segments, optional: optional, hide: hide as String?);
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
    final column = parseColumn(c);
    if (column == null) {
      problems.add('$where.columns: "$c" should be name or name:text|chip|count — a text column may add '
          'a width (name:text:40em) and :start to cut long values at their start');
      return null;
    }
    columns.add(column);
  }
  final rowAllowed = _Allowed(selected: !makesSelection, row: true, checks: checks);
  ListCheck? check;
  switch (m['check']) {
    case null || false:
      break;
    case true:
      check = const ListCheck();
    case {'column': final String column, 'toggle': final Object toggle} when column.isNotEmpty:
      final run = _command(toggle, '$where.check.toggle', rowAllowed.noChecks, problems);
      if (run == null) return null;
      check = ListCheck(column: column, toggle: PageAction(id: 'check', label: 'check', run: run));
    default:
      problems.add('$where.check: expected true, or {column: <col>, toggle: [program, arg, …]}');
      return null;
  }
  final rowActions = <PageAction>[];
  final rowIds = <String>{if (check?.toggle != null) 'check'};
  for (final (j, e) in _entries(m['rowActions'], '$where.rowActions', problems).indexed) {
    final (k, body) = e;
    final rid = body['id']?.toString();
    if (k != 'action' || rid == null || !isPageId(rid) || !rowIds.add(rid)) {
      problems.add('$where.rowActions[$j]: expected `- action: {id: …, run: […]}` with an id unique in this list'
          '${rid == 'check' && check?.toggle != null ? ' (check is taken by check.toggle)' : ''}');
      continue;
    }
    final bulk = body['bulk'] == true;
    if (bulk && check == null) {
      problems.add('$where.$rid.bulk: it runs on the checked rows — give the list check:');
      continue;
    }
    final a = _parseAction(body, rid, '$where.$rid', rowAllowed, problems, bulk: bulk);
    if (a != null) rowActions.add(a);
  }
  ListSort? sort;
  if (m['sort'] != null) {
    final parts = '${m['sort']}'.split(':');
    final order = parts.length == 2 ? parts[1] : 'asc';
    if (m['sort'] is! String || parts.first.isEmpty || parts.length > 2 || !const {'asc', 'desc'}.contains(order)) {
      problems.add('$where.sort: expected <col> or <col>:asc|desc (got "${m['sort']}")');
      return null;
    }
    sort = ListSort(parts.first, descending: order == 'desc');
  }
  ListTree? tree;
  if (m['tree'] case final Object raw) {
    // `tree: path`, `tree: [env, path]` or `tree: {columns: …, open: <depth>}`.
    final spec = raw is Map ? raw['columns'] : raw;
    final columns = spec is String ? [spec] : _strings(spec);
    final open = raw is Map ? raw['open'] ?? 0 : 0;
    final extra = raw is Map && raw.keys.any((k) => k != 'columns' && k != 'open');
    if (columns == null || columns.isEmpty || columns.any((c) => c.isEmpty) || open is! int || open < 0 || extra) {
      problems.add('$where.tree: expected a column, a list of columns, or {columns: [env, path], open: <depth>}');
      return null;
    }
    tree = ListTree(columns, open: open);
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
    check: check,
    sort: sort,
    tree: tree,
  );
}

/// An html block's `inputs:` and `actions:` — toolbar ids as strings, its own
/// actions as `- action: {…}` maps that may read `{{input.<name>}}`.
HtmlBlock? _parseHtml(Map m, String id, String area, List<String> watch, String title, String src, PageCommand? run,
    String where, List<String> problems) {
  final inputs = m['inputs'] == null ? const <String>[] : _strings(m['inputs']);
  if (inputs == null || !inputs.every(isPageId) || inputs.toSet().length != inputs.length) {
    problems.add('$where.inputs: expected a list of distinct names of letters, digits, - or _');
    return null;
  }
  final rawActions = m['actions'] ?? const [];
  if (rawActions is! List) {
    problems.add('$where.actions: expected a list of toolbar action ids and `- action: {…}` entries');
    return null;
  }
  final allowed = _Allowed(inputs: inputs.toSet(), inputsOf: 'html');
  final actions = <String>[];
  final blockActions = <PageAction>[];
  for (final (j, e) in rawActions.indexed) {
    if (e is String) {
      actions.add(e);
      continue;
    }
    final body = e is Map && e.length == 1 && e.keys.first == 'action' ? e.values.first : null;
    final aid = body is Map ? body['id']?.toString() : null;
    if (aid == null || !isPageId(aid) || blockActions.any((a) => a.id == aid)) {
      problems.add('$where.actions[$j]: expected a toolbar action id, or `- action: {id: …, run: […]}` '
          'with an id unique in this block');
      continue;
    }
    final a = _parseAction(body as Map, aid, '$where.$aid', allowed, problems);
    if (a != null) blockActions.add(a);
  }
  return HtmlBlock(
    id: id,
    area: area,
    watch: watch,
    title: title,
    src: src,
    run: run,
    actions: actions,
    blockActions: blockActions,
    inputs: inputs,
  );
}

/// A form; with no `fields` (or `panel:`, which takes none) just its buttons.
FormBlock? _parseForm(
    Map m, String id, String area, String title, String where, List<String> problems, Set<String> checks,
    {required bool panel}) {
  final rawFields = m['fields'] ?? const [];
  if (panel && m['fields'] != null) {
    problems.add('$where.fields: a panel has no fields — make it a form to add some');
    return null;
  }
  if (rawFields is! List) {
    problems.add('$where.fields: expected a list like [{name: url, label: URL}]');
    return null;
  }
  final note = m['note'];
  if (note != null && note is! String) {
    problems.add('$where.note: expected a line of text');
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
  final allowed = _Allowed(inputs: {for (final f in fields) f.name}, checks: checks);
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
    problems.add('$where.actions: a ${panel ? 'panel' : 'form'} needs at least one action');
    return null;
  }
  return FormBlock(id: id, area: area, title: title, note: note as String?, fields: fields, actions: actions);
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
    if (!_textPlaceholders(arg, at, allowed, problems, arg: arg, program: program)) return null;
  }
  return command;
}

/// Whether every `{{…}}` in [text] is a placeholder [allowed] here; adds the
/// first that isn't to [problems]. [arg]: [text] is that whole argument of a
/// command ([program] false for an openUrl's); null for a confirm's text.
bool _textPlaceholders(String text, String at, _Allowed allowed, List<String> problems,
    {String? arg, bool program = true}) {
  for (final m in _braces.allMatches(text)) {
    final p = _placeholder.matchAsPrefix(m.group(0)!);
    final kind = p?.group(2);
    final name = p?.group(3);
    final hasName = name != null;
    final spread = p?.group(4) != null;
    final checks = allowed.checks;
    final unknown = 'unknown placeholder ${m.group(0)} '
        '(selected.<col>, row.<col>, seg, input.<field>, checked.<col>, checked.<col>..., checked.count)';
    final String? why = switch (kind) {
      null => unknown,
      'selected' when !hasName => '{{selected}} needs a column: {{selected.<col>}}',
      'row' when !hasName => '{{row}} needs a column: {{row.<col>}}',
      'input' when !hasName => '{{input}} needs a field: {{input.<field>}}',
      'checked' when !hasName => '{{checked}} needs a column: {{checked.<col>}}, {{checked.<col>...}} or {{checked.count}}',
      'seg' when hasName => '{{seg}} takes no column',
      _ when spread && kind != 'checked' => '... only spreads checked rows: {{checked.<col>...}}',
      'checked' when spread && name == 'count' => '{{checked.count}} is one number — drop the ...',
      'checked' when spread && arg == null => '${m.group(0)} spreads into arguments — in text use {{checked.<col>}} '
          '(comma-joined) or {{checked.count}}',
      'checked' when spread && !program => 'an openUrl is one URL — use {{checked.<col>}} (comma-joined)',
      'checked' when spread && m.group(0) != arg =>
        '${m.group(0)} must be a whole argument — it becomes one argument per checked row',
      'selected' when !allowed.selected => '{{selected.*}} can\'t be used by the list that makes the selection',
      'row' when !allowed.row => '{{row.*}} only works in a list\'s rowActions',
      'seg' when !allowed.seg => '{{seg}} only works in a diff block with segments',
      'input' when allowed.inputs == null => '{{input.*}} only works in a form\'s actions or an html block\'s own actions',
      'input' when allowed.inputsOf == 'html' && !allowed.inputs!.contains(name) => 'no "$name" in this block\'s inputs:',
      'input' when allowed.inputs!.isEmpty => 'no field "$name" — this form has no fields',
      'input' when !allowed.inputs!.contains(name) => 'no field "$name" in this form',
      'checked' when checks == null => '{{checked.*}} only works in actions (toolbar, row and form buttons)',
      'checked' => _checkTarget(p!.group(1), checks!).$2,
      'selected' || 'row' || 'seg' || 'input' => null,
      _ => unknown,
    };
    if (why != null) {
      problems.add('$at: $why');
      return false;
    }
  }
  return true;
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

Duration? _timeout(Object? v, String at, List<String> problems, {String name = 'timeout'}) {
  if (v == null) return defaultTimeout;
  final s = v is int ? v : int.tryParse('$v');
  if (s == null || s <= 0) {
    problems.add('$at: $name must be a positive number of seconds (got "$v")');
    return null;
  }
  return Duration(seconds: s);
}
