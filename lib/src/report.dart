/// `emu report`: a bug, feature request or question about emu itself, sent as
/// a GitHub issue to the emu repository — from the CLI, the dashboard and the
/// hub (`report_api.dart`).
///
/// What goes out is decided here, once, for every frontend:
///
/// - The body is the user's text, the attachments they picked (none by
///   default) and an environment tail (emu, OS, Flutter, device kind, app
///   state). Everything — title, body, attachments, tail — passes through
///   [Scrubber] first: home and project paths, project and app names, tokens
///   and credentials are replaced before anyone sees the preview.
/// - The preview *is* the issue: [BuiltReport] is built once and the same
///   object is sent; a frontend that previews in one request and sends in
///   another refers to it by [BuiltReport.digest].
/// - With `gh` signed in to github.com the issue is created with
///   `gh issue create`; otherwise a prefilled `issues/new` link is opened and
///   the user submits it in the browser.
/// - Images can't be uploaded through any GitHub API (the web editor's upload
///   is private), so a screenshot never goes in the body: after the issue
///   exists the user pastes it into a comment (see [copyImageToClipboard]).
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'error_parser.dart';
import 'models.dart';
import 'version.dart';

/// Where reports go. `host/owner/name`, so `gh` never picks another host the
/// user is signed in to (an enterprise server).
const reportRepo = 'HuanSuh/emu';
const _host = 'github.com';
const _repoArg = '$_host/$reportRepo';
const reportIssuesUrl = 'https://$_host/$reportRepo/issues';

/// GitHub rejects issue bodies over 65,536 characters; leave room.
const _bodyLimit = 60000;

/// A prefilled `issues/new` link longer than this is refused by GitHub.
const _urlLimit = 8000;

const _titleLimit = 120;

const _leftOut = '(left out: the report was too long)';

/// Marks issues sent by `emu report` (`emu report --mine` finds them by it).
const reportMarker = '<!-- emu-report v1';

enum ReportKind {
  bug('bug'),
  feature('enhancement'),
  question('question');

  const ReportKind(this.label);

  /// The repository label for this kind — applied only if the repo has it.
  final String label;

  static ReportKind? parse(String? s) => switch (s?.toLowerCase()) {
    'bug' => bug,
    'feature' || 'enhancement' || 'idea' => feature,
    'question' || 'q' => question,
    _ => null,
  };
}

/// Something the user chose to attach.
class ReportAttachment {
  ReportAttachment.text(this.name, String this.text) : imagePath = null;
  ReportAttachment.image(this.name, String this.imagePath) : text = null;

  /// Shown as the attachment's heading, e.g. `logs (last 200 lines)`.
  final String name;
  final String? text;

  /// A PNG/JPEG on disk — pasted into the issue after it is created.
  final String? imagePath;
}

class ReportDraft {
  ReportDraft({required this.kind, required this.title, this.body = '', this.attachments = const []});

  final ReportKind kind;
  final String title;
  final String body;
  final List<ReportAttachment> attachments;
}

/// The issue exactly as it will be sent.
class BuiltReport {
  BuiltReport({
    required this.kind,
    required this.title,
    required this.body,
    this.images = const [],
    this.notes = const [],
  });

  final ReportKind kind;
  final String title;
  final String body;

  /// Image attachments, pasted in after the issue exists.
  final List<String> images;

  /// What the preview should point out (trimmed attachments, …).
  final List<String> notes;

  /// Names this report: what a later "send" refers to.
  String get digest => contentDigest(jsonEncode([kind.name, title, body, images]));

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'title': title,
    'body': body,
    'label': kind.label,
    'images': images,
    'notes': notes,
    'digest': digest,
  };

  static BuiltReport? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = ReportKind.parse(json['kind'] as String?);
    if (kind == null || json['title'] is! String || json['body'] is! String) return null;
    return BuiltReport(
      kind: kind,
      title: json['title'] as String,
      body: json['body'] as String,
      images: [for (final i in (json['images'] as List? ?? const [])) '$i'],
      notes: [for (final n in (json['notes'] as List? ?? const [])) '$n'],
    );
  }
}

/// 64-bit FNV-1a as 16 hex digits — an id for a report's content, not a
/// security boundary (every caller already holds the session token).
String contentDigest(String s) {
  var h = 0xcbf29ce484222325;
  for (final b in utf8.encode(s)) {
    h ^= b;
    h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  String half(int v) => v.toRadixString(16).padLeft(8, '0');
  return half((h >> 32) & 0xFFFFFFFF) + half(h & 0xFFFFFFFF);
}

// ---------------------------------------------------------------------------
// Scrubbing
// ---------------------------------------------------------------------------

/// Replaces what identifies the user or their project, and anything that
/// looks like a secret. Applied to every part of a report.
class Scrubber {
  Scrubber({String? home, List<String> paths = const [], List<String> names = const []})
    : _home = home,
      _paths = [
        for (final x in paths)
          if (x.length > 1) x,
      ]..sort((a, b) => b.length.compareTo(a.length)),
      _names = [
        for (final n in names.toSet())
          if (n.length >= 3 && !_commonNames.contains(n.toLowerCase())) n,
      ]..sort((a, b) => b.length.compareTo(a.length));

  /// Project names that are ordinary words in a report about emu — masking
  /// them would garble the text without hiding anything.
  static const _commonNames = {
    'emu',
    'flutter',
    'dart',
    'app',
    'apps',
    'example',
    'test',
    'tests',
    'demo',
    'lib',
    'core',
    'main',
    'mobile',
    'client',
  };

  /// For [projectRoot]: its path, its directory and pubspec names, and the
  /// app ids it builds (`com.example.app`) become `<project>`/`<app-id>`.
  factory Scrubber.forProject(String? projectRoot, {List<String> appIds = const []}) {
    final names = <String>[];
    if (projectRoot != null) {
      names.add(p.basename(projectRoot));
      final pubspec = File(p.join(projectRoot, 'pubspec.yaml'));
      if (pubspec.existsSync()) {
        final m = RegExp(r'^name:\s*([A-Za-z0-9_]+)', multiLine: true).firstMatch(pubspec.readAsStringSync());
        if (m != null) names.add(m.group(1)!);
      }
    }
    return Scrubber(
      home: Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'],
      paths: [?projectRoot],
      names: names,
    ).._appIds.addAll(appIds.where((a) => a.contains('.')));
  }

  final String? _home;
  final List<String> _paths;
  final List<String> _names;
  final List<String> _appIds = [];

  static final _secrets = <(RegExp, String)>[
    (RegExp(r'-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----'), '[redacted key]'),
    (RegExp(r'\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})'), '[redacted]'),
    (RegExp(r'\bsk-(?:ant-)?[A-Za-z0-9_-]{20,}'), '[redacted]'),
    (RegExp(r'\bxox[abposr]-[A-Za-z0-9-]{10,}'), '[redacted]'),
    (RegExp(r'\b(?:AKIA|ASIA)[0-9A-Z]{16}\b'), '[redacted]'),
    (RegExp(r'\bAIza[0-9A-Za-z_-]{30,}'), '[redacted]'),
    (RegExp(r'\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}'), '[redacted jwt]'),
    // An emu session token, and other long hex secrets (not 40-digit git SHAs).
    (RegExp(r'\b[0-9a-f]{64}\b'), '[redacted]'),
    (RegExp(r'\b(Bearer|Basic|token)\s+[A-Za-z0-9._~+/=-]{12,}', caseSensitive: false), r'$1 [redacted]'),
    // `scheme://user:pass@host`
    (RegExp(r'([a-z][a-z0-9+.-]{0,20}://)[^\s/:@]{1,200}:[^\s/@]{1,200}@', caseSensitive: false), r'$1[redacted]@'),
    // The VM Service URI's auth path: http://127.0.0.1:52345/Xy-aBc12_3=/ — it lets anyone run code in the app.
    // Also URL-encoded, as inside a DevTools link (`?uri=ws%3A%2F%2F127.0.0.1%3A52345%2FXy-aBc12_3%3D%2Fws`).
    (
      RegExp(r'((?:127\.0\.0\.1|localhost|\[::1\])(?::|%3A)\d+(?:/|%2F))[A-Za-z0-9_-]{1,200}(?:=|%3D)(?=/|%2F|\s|$|&)',
          caseSensitive: false),
      r'$1[redacted]'
    ),
    (
      RegExp(
        r'([?&](?:access_token|token|api_?key|key|secret|sig|signature|code|password)=)[^&\s#]+',
        caseSensitive: false,
      ),
      r'$1[redacted]',
    ),
    // `password: x`, `"apiKey": "x"`, `X-Emu-Token=x` …
    (
      RegExp(
        r'''\b([\w-]{0,40}(?:token|secret|passw(?:or)?d|pwd|api[_-]?key|access[_-]?key|private[_-]?key|credential|cookie|session[_-]?id|authorization)[\w-]{0,40})(["']?\s*[:=]\s*["']?)(?!\[redacted)([^\s"',;&]+)''',
        caseSensitive: false,
      ),
      r'$1$2[redacted]',
    ),
    (RegExp(r'\b[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9-]{1,63}(?:\.[A-Za-z0-9-]{1,63}){0,8}\.[A-Za-z]{2,24}\b'), '[email]'),
  ];

  String call(String s) {
    var out = s;
    for (final path in _paths) {
      out = out.replaceAll(path, '<project>');
    }
    final home = _home;
    if (home != null && home.length > 1) out = out.replaceAll(home, '~');
    // Other users' homes, and paths from a machine whose $HOME differs.
    out = out
        .replaceAll(
          RegExp(
            r'/(?:Users|home)/[^/\s"'
            "'"
            r':]+',
          ),
          '~',
        )
        .replaceAll(
          RegExp(
            r'[A-Za-z]:\\Users\\[^\\\s"'
            "'"
            r']+',
            caseSensitive: false,
          ),
          '~',
        );
    for (final id in _appIds) {
      out = out.replaceAll(id, '<app-id>');
    }
    for (final name in _names) {
      out = out.replaceAll(RegExp('(?<![A-Za-z0-9_])${RegExp.escape(name)}(?![A-Za-z0-9_])'), '<project>');
    }
    for (final (re, replacement) in _secrets) {
      out = out.replaceAllMapped(re, (m) => _expand(replacement, m));
    }
    return out;
  }

  static String _expand(String replacement, Match m) =>
      replacement.replaceAllMapped(RegExp(r'\$(\d)'), (g) => m.group(int.parse(g.group(1)!)) ?? '');
}

// ---------------------------------------------------------------------------
// Environment
// ---------------------------------------------------------------------------

/// The running session's device, as far as a report needs it: its kind, not
/// its name or id (a phone's name is often its owner's).
String describeDevice(DeviceInfo? d, {String? fallbackPlatform}) {
  if (d == null) return fallbackPlatform ?? 'none';
  return [d.platform, d.emulator ? (d.platform == 'ios' ? 'simulator' : 'emulator') : 'physical', ?d.sdk].join(' · ');
}

String? _flutterCache;

/// `3.44.4 stable · Dart 3.12.2`, or null when flutter isn't there (cached:
/// `flutter --version` takes a second or two).
Future<String?> flutterVersionLine() async {
  if (_flutterCache != null) return _flutterCache;
  try {
    final r = await Process.run('flutter', ['--version', '--machine']).timeout(const Duration(seconds: 30));
    if (r.exitCode != 0) return null;
    final out = r.stdout as String;
    final j = jsonDecode(out.substring(out.indexOf('{'))) as Map<String, dynamic>;
    return _flutterCache = [
      '${j['frameworkVersion'] ?? j['flutterVersion'] ?? '?'} ${j['channel'] ?? ''}'.trim(),
      if (j['dartSdkVersion'] != null) 'Dart ${j['dartSdkVersion']}',
    ].join(' · ');
  } catch (_) {
    return null;
  }
}

/// `macOS 15.6 (arm64)`.
Future<String> osLine() async {
  var arch = '';
  try {
    arch = ((await Process.run('uname', ['-m'])).stdout as String).trim();
  } catch (_) {}
  var version = Platform.operatingSystemVersion.split(' ').first;
  if (Platform.isMacOS) {
    try {
      version = ((await Process.run('sw_vers', ['-productVersion'])).stdout as String).trim();
    } catch (_) {}
  }
  final name = Platform.isMacOS ? 'macOS' : Platform.operatingSystem;
  return '$name $version${arch.isEmpty ? '' : ' ($arch)'}';
}

/// How this emu was installed — tells a bug in a stale build from one in main.
String installKind() {
  final self = File(Platform.resolvedExecutable).path;
  if (emuRepoRoot() != null) return 'git checkout';
  if (self.contains('.claude/plugins/')) return 'Claude Code plugin';
  if (self.endsWith('/dart') || self.endsWith('dart.exe')) return 'dart run';
  return 'binary';
}

/// The tail every report carries. [device] / [appState] are null without a session.
Future<Map<String, String>> collectEnvironment({String? device, String? appState, String? from}) async {
  return {
    'emu': '$kEmuVersion (${installKind()})',
    'OS': await osLine(),
    'Flutter': await flutterVersionLine() ?? 'not found',
    'device': device ?? 'no session',
    if (appState != null) 'app': appState,
    'from': ?from,
  };
}

// ---------------------------------------------------------------------------
// Building the body
// ---------------------------------------------------------------------------

/// The report as it will be sent. Throws [FormatException] for a missing title.
BuiltReport buildReport(ReportDraft draft, Map<String, String> environment, Scrubber scrub) {
  final title = scrub(draft.title.replaceAll(RegExp(r'\s+'), ' ').trim());
  if (title.isEmpty) throw const FormatException('a title is required');
  final notes = <String>[];
  var shortTitle = title;
  if (title.length > _titleLimit) {
    shortTitle = '${title.substring(0, _titleLimit - 1)}…';
    notes.add('title shortened to $_titleLimit characters');
  }

  // A `<!--` the user typed could hide text, or fake our marker.
  String unComment(String s) => s.replaceAll('<!--', '&lt;!--');

  var userBody = unComment(scrub(draft.body.trim()));
  if (userBody.length > _bodyLimit ~/ 2) {
    userBody = '${userBody.substring(0, _bodyLimit ~/ 2)}\n\n… (cut at ${_bodyLimit ~/ 2} characters)';
    notes.add('the description was cut to ${_bodyLimit ~/ 2} characters');
  }
  final texts = [
    for (final a in draft.attachments)
      if (a.text != null) (name: scrub(a.name), text: scrub(a.text!)),
  ];
  final images = [for (final a in draft.attachments) ?a.imagePath];

  final tail = _tail(draft.kind, environment, scrub);
  var room = _bodyLimit - userBody.length - tail.length - 200;
  final sections = <String>[];
  for (final t in texts) {
    sections.add(_fold(t.name, t.text));
  }
  // Over the limit: cut the oldest part of the longest attachment, then the
  // next, until it fits. Every pass shrinks the body, so this always ends.
  final cutNotes = <String, String>{};
  while (sections.join().length > room) {
    final open = [
      for (var k = 0; k < texts.length; k++)
        if (!texts[k].text.startsWith(_leftOut)) k,
    ];
    if (open.isEmpty) break;
    final i = open.reduce((a, b) => texts[a].text.length >= texts[b].text.length ? a : b);
    final t = texts[i].text;
    final keep = t.length - (sections.join().length - room) - 100;
    if (keep < 500) {
      texts[i] = (name: texts[i].name, text: _leftOut);
      cutNotes[texts[i].name] = "${texts[i].name}: left out to fit GitHub's size limit";
    } else {
      var tail = t.substring(t.length - keep);
      final nl = tail.indexOf('\n');
      if (nl >= 0 && nl < tail.length - 1) tail = tail.substring(nl + 1); // start on a whole line
      final cut = t.substring(0, t.length - tail.length);
      final lines = '\n'.allMatches(cut).length;
      final what = lines > 0 ? '$lines earlier lines' : '${cut.length} earlier characters';
      texts[i] = (name: texts[i].name, text: '… $what left out\n$tail');
      cutNotes[texts[i].name] = "${texts[i].name}: $what left out to fit GitHub's size limit";
    }
    sections[i] = _fold(texts[i].name, texts[i].text);
  }
  notes.addAll(cutNotes.values);
  if (images.isNotEmpty) {
    notes.add(
      '${images.length == 1 ? 'the screenshot is' : '${images.length} screenshots are'} not in the body — '
      'paste ${images.length == 1 ? 'it' : 'them'} into a comment once the issue is open',
    );
  }

  final body = StringBuffer();
  if (userBody.isNotEmpty) body.writeln(userBody);
  if (sections.isNotEmpty) {
    body
      ..writeln()
      ..writeln('### Attachments')
      ..writeln();
    for (final s in sections) {
      body.writeln(s);
    }
  }
  body
    ..writeln()
    ..write(tail);
  return BuiltReport(kind: draft.kind, title: shortTitle, body: body.toString(), images: images, notes: notes);
}

String _fold(String name, String text) {
  // A fence longer than any backtick run inside, so the text can't close it.
  var fence = '```';
  while (text.contains(fence)) {
    fence += '`';
  }
  return '<details><summary>${_htmlText(name)}</summary>\n\n${fence}text\n$text\n$fence\n</details>\n';
}

String _tail(ReportKind kind, Map<String, String> env, Scrubber scrub) {
  final rows = {'kind': kind.name, ...env};
  final sb = StringBuffer()
    ..writeln('---')
    ..writeln('<details><summary>Environment (sent with <code>emu report</code>)</summary>')
    ..writeln()
    ..writeln('| | |')
    ..writeln('|---|---|');
  for (final e in rows.entries) {
    sb.writeln('| ${e.key} | ${scrub(e.value).replaceAll('|', r'\|').replaceAll('\n', ' ')} |');
  }
  sb
    ..writeln()
    ..writeln('</details>')
    ..writeln();
  // `<`, `>` and `&` escaped so nothing in the JSON can end the comment early.
  final meta = jsonEncode({
    'kind': kind.name,
    'emu': kEmuVersion,
  }).replaceAll('<', '\\u003c').replaceAll('>', '\\u003e').replaceAll('&', '\\u0026');
  sb.writeln('$reportMarker $meta -->');
  return sb.toString();
}

String _htmlText(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

/// The last [lines] log entries as text (`HH:MM:SS L  text`).
String formatLogLines(List<LogEntry> entries, int lines) {
  final shown = entries.length > lines ? entries.sublist(entries.length - lines) : entries;
  String two(int n) => n.toString().padLeft(2, '0');
  const tags = {LogLevel.error: 'E', LogLevel.warn: 'W', LogLevel.debug: 'D', LogLevel.system: '•', LogLevel.info: 'I'};
  return [
    for (final e in shown)
      '${two(e.timestamp.hour)}:${two(e.timestamp.minute)}:${two(e.timestamp.second)} ${tags[e.level]}  ${e.text}',
  ].join('\n');
}

/// The `logs` attachment: the last [lines] entries.
ReportAttachment logsAttachment(List<LogEntry> entries, int lines) {
  final n = entries.length < lines ? entries.length : lines;
  return ReportAttachment.text('logs (last $n lines)', entries.isEmpty ? '(no logs)' : formatLogLines(entries, lines));
}

/// The `errors` attachment: the last [count] exception banners, or null when there are none.
ReportAttachment? errorsAttachment(List<LogEntry> entries, {int count = 3}) {
  final errors = parseErrorBanners(entries);
  if (errors.isEmpty) return null;
  final shown = errors.length > count ? errors.sublist(errors.length - count) : errors;
  return ReportAttachment.text(
    'errors (last ${shown.length} of ${errors.length})',
    [for (final e in shown) e.raw].join('\n\n'),
  );
}

// ---------------------------------------------------------------------------
// Sending
// ---------------------------------------------------------------------------

/// Runs a program (never a shell) — replaced in tests.
typedef ProcessRun = Future<ProcessResult> Function(String exe, List<String> args, {String? stdin});

Future<ProcessResult> _run(String exe, List<String> args, {String? stdin}) async {
  if (stdin == null) return Process.run(exe, args).timeout(const Duration(seconds: 60));
  final proc = await Process.start(exe, args);
  proc.stdin.write(stdin);
  await proc.stdin.close();
  final out = proc.stdout.transform(utf8.decoder).join();
  final err = proc.stderr.transform(utf8.decoder).join();
  final code = await proc.exitCode.timeout(const Duration(seconds: 60));
  return ProcessResult(proc.pid, code, await out, await err);
}

/// How a report went out.
class ReportResult {
  ReportResult({required this.via, this.url, this.number, this.duplicate = false, this.labeled = false, this.error});

  /// `gh` (created) or `browser` ([url] is the prefilled form to submit).
  final String via;
  final String? url;
  final int? number;

  /// The same report was already sent a moment ago; [url] is that issue.
  final bool duplicate;
  final bool labeled;
  final String? error;

  bool get ok => error == null;

  Map<String, dynamic> toJson() => {
    'ok': ok,
    'via': via,
    'url': ?url,
    'number': ?number,
    if (duplicate) 'duplicate': true,
    if (labeled) 'labeled': true,
    'error': ?error,
  };
}

class GitHubReporter {
  GitHubReporter({ProcessRun? run, Directory? stateDir})
    : _runner = run ?? _run,
      _state = stateDir ?? Directory('${Platform.environment['HOME'] ?? '.'}/.emu/reports');

  final ProcessRun _runner;
  final Directory _state;
  Set<String>? _labels;
  bool _sending = false;

  /// Same report within this window → the issue already made, not a second one.
  static const dedupeWindow = Duration(minutes: 10);

  /// Whether `gh` is installed and signed in to github.com.
  Future<bool> ghReady() async {
    try {
      final r = await _runner('gh', ['auth', 'status', '--hostname', _host]);
      return r.exitCode == 0;
    } catch (_) {
      return false; // not installed
    }
  }

  /// The repository's labels (empty when they can't be read).
  Future<Set<String>> repoLabels() async {
    if (_labels != null) return _labels!;
    try {
      final r = await _runner('gh', ['label', 'list', '--repo', _repoArg, '--json', 'name', '--limit', '200']);
      if (r.exitCode != 0) return {};
      return _labels = {for (final l in jsonDecode(r.stdout as String) as List) '${(l as Map)['name']}'};
    } catch (_) {
      return {};
    }
  }

  /// The prefilled `issues/new` form. Over GitHub's URL limit the attachments
  /// are left out ([trimmed] is true) — the caller hands over the full body.
  ({String url, bool trimmed}) newIssueUrl(BuiltReport r) {
    String build(String body) => Uri.https(_host, '/$reportRepo/issues/new', {
      'title': r.title,
      'body': body,
      'labels': r.kind.label,
    }).toString();
    final full = build(r.body);
    if (full.length <= _urlLimit) return (url: full, trimmed: false);
    final i = r.body.indexOf('\n### Attachments');
    final j = r.body.indexOf('\n---\n<details>');
    var short = i >= 0 && j > i
        ? '${r.body.substring(0, i)}\n\n_(attachments were too long for a link — paste them from the clipboard)_\n${r.body.substring(j)}'
        : r.body;
    if (build(short).length > _urlLimit) {
      short =
          '${short.substring(0, (short.length * _urlLimit / build(short).length * 0.9).floor())}\n\n'
          '_(cut to fit a link — paste the full text from the clipboard)_';
    }
    if (build(short).length > _urlLimit) {
      short = '_(the text was too long for a link — paste it from the clipboard)_\n\n$reportMarker {} -->';
    }
    return (url: build(short), trimmed: true);
  }

  /// Sends [r]: `gh issue create` when [useGh], else the browser link. The
  /// browser link isn't opened here — the caller does that.
  Future<ReportResult> send(BuiltReport r, {required bool useGh}) async {
    final sent = _recentlySent(r.digest);
    if (sent != null) return ReportResult(via: 'gh', url: sent, number: _issueNumber(sent), duplicate: true);
    if (!useGh) return ReportResult(via: 'browser', url: newIssueUrl(r).url);
    if (_sending) return ReportResult(via: 'gh', error: 'another report is being sent — try again in a moment');
    _sending = true;
    final tmp = await Directory.systemTemp.createTemp('emu-report-');
    try {
      final file = File(p.join(tmp.path, 'body.md'));
      await file.create();
      if (!Platform.isWindows) await Process.run('chmod', ['600', file.path]);
      await file.writeAsString(r.body);
      final labels = (await repoLabels()).contains(r.kind.label) ? [r.kind.label] : <String>[];
      Future<ProcessResult> create(List<String> labels) => _runner('gh', [
        'issue',
        'create',
        '--repo',
        _repoArg,
        '--title',
        r.title,
        '--body-file',
        file.path,
        for (final l in labels) ...['--label', l],
      ]);
      var res = await create(labels);
      var labeled = labels.isNotEmpty;
      // No permission to label (a non-collaborator) — send it without.
      if (res.exitCode != 0 && labels.isNotEmpty && '${res.stderr}'.toLowerCase().contains('label')) {
        res = await create(const []);
        labeled = false;
      }
      if (res.exitCode != 0) return ReportResult(via: 'gh', error: ghErrorText('${res.stderr}'));
      final url = parseIssueUrl('${res.stdout}');
      if (url == null) {
        return ReportResult(
          via: 'gh',
          error: 'gh did not answer with an issue of $reportRepo: ${'${res.stdout}'.trim()}',
        );
      }
      _rememberSent(r.digest, url);
      return ReportResult(via: 'gh', url: url, number: _issueNumber(url), labeled: labeled);
    } catch (e) {
      return ReportResult(via: 'gh', error: ghErrorText('$e'));
    } finally {
      _sending = false;
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  /// The issues this user sent with `emu report` (found by [reportMarker]),
  /// newest first. Null when gh can't list them — show [myIssuesUrl] instead.
  Future<List<Map<String, dynamic>>?> mine({int limit = 30}) async {
    const base = [
      'number',
      'title',
      'state',
      'stateReason',
      'url',
      'createdAt',
      'updatedAt',
      'labels',
      'comments',
      'body',
    ];
    Future<ProcessResult> list(List<String> fields) => _runner('gh', [
      'issue',
      'list',
      '--repo',
      _repoArg,
      '--author',
      '@me',
      '--state',
      'all',
      '--limit',
      '${limit * 2}',
      '--json',
      fields.join(','),
    ]);
    try {
      var r = await list([...base, 'closedByPullRequestsReferences']);
      if (r.exitCode != 0) r = await list(base); // an older gh without that field
      if (r.exitCode != 0) return null;
      final out = <Map<String, dynamic>>[];
      for (final i in (jsonDecode(r.stdout as String) as List).cast<Map<String, dynamic>>()) {
        if (!'${i['body']}'.contains(reportMarker)) continue;
        out.add({
          'number': i['number'],
          'title': i['title'],
          'state': (i['state'] as String? ?? '').toLowerCase(),
          'status': issueStatus(i),
          'url': i['url'],
          'createdAt': i['createdAt'],
          'updatedAt': i['updatedAt'],
          'comments': (i['comments'] as List?)?.length ?? 0,
          'labels': [for (final l in (i['labels'] as List? ?? const [])) (l as Map)['name']],
          'prs': [
            for (final pr in (i['closedByPullRequestsReferences'] as List? ?? const []))
              {'number': (pr as Map)['number'], 'url': pr['url']},
          ],
        });
        if (out.length >= limit) break;
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  String? _recentlySent(String digest) {
    final now = DateTime.now();
    for (final e in _readSent().entries) {
      final at = DateTime.tryParse('${(e.value as Map)['at']}');
      if (e.key == digest && at != null && now.difference(at) < dedupeWindow) return '${e.value['url']}';
    }
    return null;
  }

  void _rememberSent(String digest, String url) {
    final now = DateTime.now();
    final sent = _readSent()
      ..removeWhere((_, v) => now.difference(DateTime.tryParse('${(v as Map)['at']}') ?? now) > dedupeWindow)
      ..[digest] = {'url': url, 'at': now.toIso8601String()};
    try {
      _state.createSync(recursive: true);
      final f = File(p.join(_state.path, 'sent.json'));
      final tmp = File('${f.path}.$pid.tmp')..writeAsStringSync(jsonEncode(sent));
      tmp.renameSync(f.path);
    } catch (_) {}
  }

  Map<String, dynamic> _readSent() {
    try {
      return jsonDecode(File(p.join(_state.path, 'sent.json')).readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }
}

/// Where the user can see their issues without gh.
const myIssuesUrl = '$reportIssuesUrl?q=is%3Aissue+author%3A%40me';

/// open / fixing (a PR is linked) / fixed / closed / not planned.
String issueStatus(Map<String, dynamic> issue) {
  final state = '${issue['state']}'.toUpperCase();
  final prs = issue['closedByPullRequestsReferences'] as List? ?? const [];
  if (state == 'OPEN') return prs.isEmpty ? 'open' : 'fixing';
  if ('${issue['stateReason']}'.toUpperCase() == 'NOT_PLANNED') return 'not planned';
  return prs.isEmpty ? 'closed' : 'fixed';
}

/// The issue URL `gh issue create` printed — only one of [reportRepo].
String? parseIssueUrl(String stdout) {
  final lines = stdout.trim().split('\n');
  final last = lines.isEmpty ? '' : lines.last.trim();
  return RegExp('^https://$_host/${RegExp.escape(reportRepo)}/issues/\\d+\$').hasMatch(last) ? last : null;
}

int? _issueNumber(String url) => int.tryParse(url.split('/').last);

/// A gh failure, as something the user can act on.
String ghErrorText(String stderr) {
  final s = stderr.toLowerCase();
  if (s.contains('enoent') || s.contains('no such file') || s.contains('command not found')) {
    return 'gh is not installed — install it (https://cli.github.com) or send from the browser';
  }
  if (s.contains('not logged in') || s.contains('401') || s.contains('bad credentials') || s.contains('auth login')) {
    return 'gh is not signed in to github.com — run `gh auth login --hostname github.com`';
  }
  if (s.contains('could not resolve') || s.contains('timeout') || s.contains('timed out') || s.contains('network')) {
    return 'could not reach GitHub — check the network';
  }
  final first = stderr.trim().split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => 'unknown error');
  return 'gh failed: ${first.length > 200 ? '${first.substring(0, 200)}…' : first}';
}

// ---------------------------------------------------------------------------
// Drafts (preview in one command, send in the next)
// ---------------------------------------------------------------------------

/// `emu report --dry-run` keeps what it showed here; `emu report --send <id>`
/// sends exactly that. Kept a day, readable only by the user.
class ReportDrafts {
  ReportDrafts([Directory? dir]) : dir = dir ?? Directory('${Platform.environment['HOME'] ?? '.'}/.emu/reports/drafts');

  final Directory dir;
  static const keep = Duration(days: 1);

  String save(BuiltReport r) {
    dir.createSync(recursive: true);
    if (!Platform.isWindows) Process.runSync('chmod', ['700', dir.path]);
    final now = DateTime.now();
    for (final f in dir.listSync().whereType<File>()) {
      if (now.difference(f.statSync().modified) > keep) f.deleteSync();
    }
    final f = File(p.join(dir.path, '${r.digest}.json'))..createSync();
    if (!Platform.isWindows) Process.runSync('chmod', ['600', f.path]);
    f.writeAsStringSync(jsonEncode(r.toJson()));
    return r.digest;
  }

  BuiltReport? load(String id) {
    if (!RegExp(r'^[0-9a-f]{16}$').hasMatch(id)) return null;
    final f = File(p.join(dir.path, '$id.json'));
    if (!f.existsSync() || DateTime.now().difference(f.statSync().modified) > keep) return null;
    try {
      final r = BuiltReport.fromJson(jsonDecode(f.readAsStringSync()));
      return r?.digest == id ? r : null;
    } catch (_) {
      return null;
    }
  }

  void remove(String id) {
    try {
      File(p.join(dir.path, '$id.json')).deleteSync();
    } catch (_) {}
  }
}

// ---------------------------------------------------------------------------
// Desktop helpers
// ---------------------------------------------------------------------------

/// Puts a PNG on the macOS clipboard, to paste into the issue (⌘V).
Future<bool> copyImageToClipboard(String path) async {
  if (!Platform.isMacOS) return false;
  final r = await Process.run('osascript', [
    '-e',
    'on run argv',
    '-e',
    'set the clipboard to (read (POSIX file (item 1 of argv)) as «class PNGf»)',
    '-e',
    'end run',
    path,
  ]);
  return r.exitCode == 0;
}

/// Puts text on the clipboard (macOS `pbcopy`); false elsewhere.
Future<bool> copyTextToClipboard(String text) async {
  if (!Platform.isMacOS) return false;
  try {
    final r = await _run('pbcopy', const [], stdin: text);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}
