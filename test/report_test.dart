import 'dart:convert';
import 'dart:io';

import 'package:emu/src/models.dart';
import 'package:emu/src/report.dart';
import 'package:emu/src/report_api.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

const _env = {'emu': '0.14.0 (git checkout)', 'OS': 'macOS 15.6 (arm64)', 'Flutter': '3.44.4 stable · Dart 3.12.2'};

/// A scripted `gh`: [answers] maps the joined argv's start to a result.
class FakeGh {
  FakeGh(this.answers);
  final Map<String, ProcessResult Function(List<String>)> answers;
  final calls = <List<String>>[];
  final bodies = <String>[];

  Future<ProcessResult> call(String exe, List<String> args, {String? stdin}) async {
    calls.add([exe, ...args]);
    final i = args.indexOf('--body-file');
    if (i >= 0) bodies.add(File(args[i + 1]).readAsStringSync());
    final joined = args.join(' ');
    for (final e in answers.entries) {
      if (joined.startsWith(e.key)) return e.value(args);
    }
    return ProcessResult(0, 1, '', 'unexpected: $joined');
  }
}

ProcessResult ok(String out) => ProcessResult(0, 0, out, '');
ProcessResult err(String e) => ProcessResult(0, 1, '', e);

void main() {
  group('Scrubber', () {
    final scrub = Scrubber(home: '/Users/alice', paths: ['/Users/alice/work/shop_app'], names: ['shop_app', 'emu'])
      ..call(''); // constructible without a project

    test('project and home paths', () {
      expect(scrub('at /Users/alice/work/shop_app/lib/main.dart:3'), 'at <project>/lib/main.dart:3');
      expect(scrub('cache in /Users/alice/.pub-cache'), 'cache in ~/.pub-cache');
      expect(scrub('built by /Users/bob/x and /home/carol/y'), 'built by ~/x and ~/y');
      expect(scrub(r'C:\Users\dave\app'), r'~\app');
    });

    test('project name as a word only, never a common word like emu', () {
      expect(scrub('package:shop_app/main.dart'), 'package:<project>/main.dart');
      expect(scrub('my_shop_app_test'), 'my_shop_app_test');
      expect(scrub('emu reload failed'), 'emu reload failed');
    });

    test('app ids', () {
      final s = Scrubber.forProject(null, appIds: ['com.acme.shop']);
      expect(s('Launching com.acme.shop/.MainActivity'), 'Launching <app-id>/.MainActivity');
    });

    test('tokens and credentials', () {
      expect(scrub('GH_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123'), 'GH_TOKEN=[redacted]');
      expect(scrub('use github_pat_11ABCDEFG0123456789_abcdefghij'), 'use [redacted]');
      expect(scrub('Authorization: Bearer abc.def.ghi-jkl_mno'), contains('[redacted]'));
      expect(scrub('Authorization: Bearer abc.def.ghi-jkl_mno'), isNot(contains('abc.def')));
      expect(scrub('"password": "hunter22"'), '"password": "[redacted]"');
      expect(scrub('api_key=xyz123'), 'api_key=[redacted]');
      expect(scrub('https://bob:s3cret@git.example.com/r.git'), 'https://[redacted]@git.example.com/r.git');
      expect(scrub('GET /v1/items?id=3&token=abc123&x=1'), 'GET /v1/items?id=3&token=[redacted]&x=1');
      expect(scrub('key AKIAABCDEFGHIJKLMNOP'), 'key [redacted]');
      expect(scrub('jwt eyJhbGciOiJIUzI1.eyJzdWIiOiIxMjM0.abcdefghijk'), 'jwt [redacted jwt]');
      expect(scrub('X-Emu-Token: ${'a' * 64}'), isNot(contains('a' * 64)));
      expect(scrub('-----BEGIN RSA PRIVATE KEY-----\nMIIE\n-----END RSA PRIVATE KEY-----'), '[redacted key]');
      expect(scrub('mail me at alice@example.com'), 'mail me at [email]');
    });

    test('the VM Service auth path', () {
      expect(
        scrub('VM Service at http://127.0.0.1:52345/Xy-aBc12_3=/'),
        'VM Service at http://127.0.0.1:52345/[redacted]/',
      );
      expect(scrub('ws://127.0.0.1:52345/Xy-aBc12_3=/ws'), 'ws://127.0.0.1:52345/[redacted]/ws');
      expect(scrub('DevTools: http://127.0.0.1:61729/?uri=ws%3A%2F%2F127.0.0.1%3A61723%2FXK7cO7tOkkI%3D%2Fws'),
          'DevTools: http://127.0.0.1:61729/?uri=ws%3A%2F%2F127.0.0.1%3A61723%2F[redacted]%2Fws');
    });

    test('stays fast on long lines (no backtracking blow-up)', () {
      final sw = Stopwatch()..start();
      scrub('x' * 200000);
      scrub(List.filled(2000, 'I/flutter (1234): token_count_value_${'a' * 80} ok').join('\n'));
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('leaves ordinary text and git SHAs alone', () {
      const sha = 'ad70ec4617166f1c38e5d2bfd388af71fda14f06';
      expect(scrub('engine $sha'), 'engine $sha');
      expect(scrub('Reloaded 3 of 512 libraries in 210ms.'), 'Reloaded 3 of 512 libraries in 210ms.');
    });
  });

  group('buildReport', () {
    final scrub = Scrubber(home: '/Users/alice', paths: ['/Users/alice/shop'], names: ['shop']);

    test('body, attachments and tail, all scrubbed', () {
      final r = buildReport(
        ReportDraft(
          kind: ReportKind.bug,
          title: '  reload  breaks\nshop  ',
          body: 'in /Users/alice/shop/lib/a.dart',
          attachments: [ReportAttachment.text('logs (last 2 lines)', 'E boom at /Users/alice/shop/lib/a.dart')],
        ),
        {..._env, 'device': 'android · emulator · Android 14 (API 34)'},
        scrub,
      );
      expect(r.title, 'reload breaks <project>');
      expect(r.body, startsWith('in <project>/lib/a.dart\n'));
      expect(r.body, contains('### Attachments'));
      expect(r.body, contains('<details><summary>logs (last 2 lines)</summary>'));
      expect(r.body, contains('E boom at <project>/lib/a.dart'));
      expect(r.body, contains('| kind | bug |'));
      expect(r.body, contains('| device | android · emulator · Android 14 (API 34) |'));
      expect(r.body.trimRight(), endsWith('-->'));
      expect(r.body, contains('$reportMarker {"kind":"bug"'));
      expect(r.body, isNot(contains('alice')));
    });

    test('a title is required', () {
      expect(() => buildReport(ReportDraft(kind: ReportKind.bug, title: '  '), _env, scrub), throwsFormatException);
    });

    test('a typed <!-- can not hide text or fake the marker', () {
      final r = buildReport(
        ReportDraft(kind: ReportKind.feature, title: 't', body: 'hi <!-- emu-report v1 {"kind":"x"} --> there'),
        _env,
        scrub,
      );
      expect(r.body, contains('hi &lt;!-- emu-report'));
      expect('<!--'.allMatches(r.body), hasLength(1)); // only ours
    });

    test('an attachment with backticks can not close its fence', () {
      final r = buildReport(
        ReportDraft(kind: ReportKind.bug, title: 't', attachments: [ReportAttachment.text('f', 'a\n```\n</details>')]),
        _env,
        scrub,
      );
      expect(r.body, contains('````text\na\n```\n</details>\n````'));
    });

    test('long attachments lose their oldest lines to fit GitHub', () {
      final log = [for (var i = 0; i < 4000; i++) 'line $i ${'x' * 30}'].join('\n');
      final r = buildReport(
        ReportDraft(kind: ReportKind.bug, title: 't', attachments: [ReportAttachment.text('logs', log)]),
        _env,
        scrub,
      );
      expect(r.body.length, lessThan(65536));
      expect(r.body, contains('line 3999'));
      expect(r.body, isNot(contains('line 0 ')));
      expect(r.notes.single, contains('earlier lines left out'));
    });

    test('one huge line can not stall the trimming', () {
      final r = buildReport(
        ReportDraft(
          kind: ReportKind.bug,
          title: 't',
          body: 'b' * 29000,
          attachments: [ReportAttachment.text('blob', '\n${'x' * 90000}'), ReportAttachment.text('logs', 'y' * 40000)],
        ),
        _env,
        Scrubber(),
      );
      expect(r.body.length, lessThan(65536));
      expect(r.body, contains(reportMarker));
    });

    test('the marker JSON is escaped for the HTML comment', () {
      final r = buildReport(ReportDraft(kind: ReportKind.bug, title: 't'), _env, Scrubber());
      final meta = RegExp(r'<!-- emu-report v1 (.*) -->').firstMatch(r.body)!.group(1)!;
      expect(jsonDecode(meta), containsPair('kind', 'bug'));
    });

    test('images are listed, never in the body', () {
      final r = buildReport(
        ReportDraft(
          kind: ReportKind.bug,
          title: 't',
          attachments: [ReportAttachment.image('screenshot', '/tmp/s.png')],
        ),
        _env,
        scrub,
      );
      expect(r.images, ['/tmp/s.png']);
      expect(r.body, isNot(contains('s.png')));
      expect(r.notes.single, contains('paste it into a comment'));
    });

    test('digest follows the content', () {
      BuiltReport b(String t) => buildReport(ReportDraft(kind: ReportKind.bug, title: t), _env, scrub);
      expect(b('a').digest, b('a').digest);
      expect(b('a').digest, isNot(b('b').digest));
      expect(b('a').digest, matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(BuiltReport.fromJson(jsonDecode(jsonEncode(b('a').toJson())))!.digest, b('a').digest);
    });
  });

  test('describeDevice: the kind, never the name or id', () {
    final phone = DeviceInfo(id: '00008130-0016', name: 'Alice’s iPhone', platform: 'ios', emulator: false, sdk: 'iOS 26.5');
    expect(describeDevice(phone), 'ios · physical · iOS 26.5');
    expect(describeDevice(DeviceInfo(id: 'emulator-5554', name: 'sdk', platform: 'android', emulator: true)),
        'android · emulator');
    expect(describeDevice(null, fallbackPlatform: 'android'), 'android');
  });

  test('ReportKind.parse', () {
    expect(ReportKind.parse('bug'), ReportKind.bug);
    expect(ReportKind.parse('Enhancement'), ReportKind.feature);
    expect(ReportKind.parse('question')!.label, 'question');
    expect(ReportKind.parse('feature')!.label, 'enhancement');
    expect(ReportKind.parse('nope'), isNull);
  });

  test('attachments from the log', () {
    final t = DateTime(2026, 1, 1, 9, 5, 7);
    final entries = [
      for (var i = 0; i < 5; i++) LogEntry(seq: i, timestamp: t, level: LogLevel.info, text: 'l$i', source: 'app'),
    ];
    final a = logsAttachment(entries, 2);
    expect(a.name, 'logs (last 2 lines)');
    expect(a.text, '09:05:07 I  l3\n09:05:07 I  l4');
    expect(errorsAttachment(entries), isNull);
  });

  test('parseIssueUrl accepts only an issue of the emu repo', () {
    expect(
      parseIssueUrl('Creating issue…\nhttps://github.com/HuanSuh/emu/issues/51\n'),
      'https://github.com/HuanSuh/emu/issues/51',
    );
    expect(parseIssueUrl('https://github.com/someone/emu/issues/51'), isNull);
    expect(parseIssueUrl('https://github.com/HuanSuh/emu/pull/51'), isNull);
    expect(parseIssueUrl(''), isNull);
  });

  test('issueStatus', () {
    expect(issueStatus({'state': 'OPEN'}), 'open');
    expect(
      issueStatus({
        'state': 'OPEN',
        'closedByPullRequestsReferences': [{}],
      }),
      'fixing',
    );
    expect(
      issueStatus({
        'state': 'CLOSED',
        'closedByPullRequestsReferences': [{}],
      }),
      'fixed',
    );
    expect(issueStatus({'state': 'CLOSED', 'stateReason': 'NOT_PLANNED'}), 'not planned');
    expect(issueStatus({'state': 'CLOSED'}), 'closed');
  });

  test('ghErrorText', () {
    expect(
      ghErrorText('To get started with GitHub CLI, please run:  gh auth login'),
      contains('gh auth login --hostname github.com'),
    );
    expect(ghErrorText('ProcessException: No such file or directory'), contains('not installed'));
    expect(ghErrorText('something odd\nmore'), 'gh failed: something odd');
  });

  group('GitHubReporter', () {
    late Directory state;
    setUp(() => state = Directory.systemTemp.createTempSync('emu-report-test-'));
    tearDown(() => state.deleteSync(recursive: true));

    BuiltReport report([String title = 'boom']) =>
        buildReport(ReportDraft(kind: ReportKind.bug, title: title, body: 'body'), _env, Scrubber());

    test('creates with gh, labels only when the repo has the label', () async {
      final gh = FakeGh({
        'label list': (_) => ok(
          jsonEncode([
            {'name': 'bug'},
            {'name': 'documentation'},
          ]),
        ),
        'issue create': (_) => ok('https://github.com/HuanSuh/emu/issues/60\n'),
      });
      final r = await GitHubReporter(run: gh.call, stateDir: state).send(report(), useGh: true);
      expect(r.ok, isTrue);
      expect(r.number, 60);
      expect(r.labeled, isTrue);
      final create = gh.calls.firstWhere((c) => c.contains('create'));
      expect(create, containsAllInOrder(['--repo', 'github.com/HuanSuh/emu', '--title', 'boom']));
      expect(create, containsAllInOrder(['--label', 'bug']));
      expect(gh.bodies.single, report().body);

      final q = await GitHubReporter(
        run: FakeGh({
          'label list': (_) => ok('[]'),
          'issue create': (args) {
            expect(args, isNot(contains('--label')));
            return ok('https://github.com/HuanSuh/emu/issues/61');
          },
        }).call,
        stateDir: Directory('${state.path}/b'),
      ).send(report('other'), useGh: true);
      expect(q.labeled, isFalse);
    });

    test('a label it may not set: sent again without', () async {
      var tries = 0;
      final gh = FakeGh({
        'label list': (_) => ok(
          jsonEncode([
            {'name': 'bug'},
          ]),
        ),
        'issue create': (args) => ++tries == 1
            ? err('could not add label: \'bug\' not found')
            : ok('https://github.com/HuanSuh/emu/issues/62'),
      });
      final r = await GitHubReporter(run: gh.call, stateDir: state).send(report(), useGh: true);
      expect(r.ok, isTrue);
      expect(r.labeled, isFalse);
      expect(tries, 2);
    });

    test('an answer that is not an emu issue is a failure', () async {
      final gh = FakeGh({
        'label list': (_) => ok('[]'),
        'issue create': (_) => ok('https://github.com/evil/x/issues/1'),
      });
      final r = await GitHubReporter(run: gh.call, stateDir: state).send(report(), useGh: true);
      expect(r.ok, isFalse);
    });

    test('the same report twice in a row: the first issue, not a second', () async {
      var created = 0;
      final gh = FakeGh({
        'label list': (_) => ok('[]'),
        'issue create': (_) => ok('https://github.com/HuanSuh/emu/issues/${63 + created++}'),
      });
      final reporter = GitHubReporter(run: gh.call, stateDir: state);
      await reporter.send(report(), useGh: true);
      final again = await GitHubReporter(run: gh.call, stateDir: state).send(report(), useGh: true);
      expect(again.duplicate, isTrue);
      expect(again.number, 63);
      expect(created, 1);
      expect((await reporter.send(report('different'), useGh: true)).number, 64);
    });

    test('without gh: the prefilled form', () async {
      final r = await GitHubReporter(run: FakeGh({}).call, stateDir: state).send(report(), useGh: false);
      expect(r.via, 'browser');
      final u = Uri.parse(r.url!);
      expect(u.host, 'github.com');
      expect(u.path, '/HuanSuh/emu/issues/new');
      expect(u.queryParameters['title'], 'boom');
      expect(u.queryParameters['labels'], 'bug');
      expect(u.queryParameters['body'], report().body);
    });

    test('a body too long for a link drops the attachments from the link', () {
      final big = buildReport(
        ReportDraft(
          kind: ReportKind.bug,
          title: 't',
          body: 'top',
          attachments: [ReportAttachment.text('logs', 'x' * 20000)],
        ),
        _env,
        Scrubber(),
      );
      final link = GitHubReporter(run: FakeGh({}).call, stateDir: state).newIssueUrl(big);
      expect(link.trimmed, isTrue);
      expect(link.url.length, lessThanOrEqualTo(8000));
      final body = Uri.parse(link.url).queryParameters['body']!;
      expect(body, startsWith('top'));
      expect(body, contains('paste them from the clipboard'));
      expect(body, contains(reportMarker));
    });

    test('mine: only issues sent with emu report', () async {
      final gh = FakeGh({
        'issue list': (args) => args.join(',').contains('closedByPullRequestsReferences')
            ? err('Unknown JSON field: "closedByPullRequestsReferences"')
            : ok(
                jsonEncode([
                  {
                    'number': 9,
                    'title': 'mine',
                    'state': 'OPEN',
                    'url': 'u9',
                    'body': 'x\n$reportMarker {} -->',
                    'comments': [{}],
                    'labels': [],
                  },
                  {
                    'number': 8,
                    'title': 'by hand',
                    'state': 'OPEN',
                    'url': 'u8',
                    'body': 'x',
                    'comments': [],
                    'labels': [],
                  },
                ]),
              ),
      });
      final list = await GitHubReporter(run: gh.call, stateDir: state).mine();
      expect(list, hasLength(1));
      expect(list!.single, containsPair('number', 9));
      expect(list.single, containsPair('status', 'open'));
      expect(list.single, containsPair('comments', 1));
      expect(list.single.containsKey('body'), isFalse);
      expect(gh.calls.first, containsAllInOrder(['--author', '@me']));
    });
  });

  test('ReportDrafts: what --dry-run showed is what --send sends', () {
    final dir = Directory.systemTemp.createTempSync('emu-drafts-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final drafts = ReportDrafts(dir);
    final r = buildReport(ReportDraft(kind: ReportKind.question, title: 'q?', body: 'b'), _env, Scrubber());
    final id = drafts.save(r);
    expect(drafts.load(id)!.body, r.body);
    expect(drafts.load('../../etc/passwd'), isNull);
    // Edited on disk: no longer the draft that was shown.
    File('${dir.path}/$id.json').writeAsStringSync(jsonEncode({...r.toJson(), 'body': 'changed'}));
    expect(drafts.load(id), isNull);
  });

  group('ReportApi', () {
    late Directory state;
    late FakeGh gh;
    late ReportApi api;
    var logs = <LogEntry>[];
    setUp(() {
      state = Directory.systemTemp.createTempSync('emu-report-api-');
      gh = FakeGh({
        'auth status': (_) => ok(''),
        'label list': (_) => ok(
          jsonEncode([
            {'name': 'bug'},
          ]),
        ),
        'issue create': (_) => ok('https://github.com/HuanSuh/emu/issues/70'),
      });
      api = ReportApi(
        ReportSources(
          from: 'dashboard',
          scrubber: () => Scrubber(home: '/Users/alice'),
          logs: () => logs,
        ),
        reporter: GitHubReporter(run: gh.call, stateDir: state),
        environment: ({device, appState, from}) async => {..._env, 'from': ?from},
      );
    });
    tearDown(() => state.deleteSync(recursive: true));

    Future<Map<String, dynamic>> call(String method, String path, [Object? body]) async {
      final r = await api.handle(
        Request(method, Uri.parse('http://127.0.0.1$path'), body: body == null ? null : jsonEncode(body)),
        path,
      );
      return jsonDecode(await r.readAsString()) as Map<String, dynamic>;
    }

    test('info', () async {
      final j = await call('GET', '/api/report');
      expect(j['via'], 'gh');
      expect(j['attach'], {'logs': true, 'errors': true, 'shot': false});
    });

    test('send sends the previewed issue, even when the log moved on', () async {
      logs = [
        LogEntry(
          seq: 1,
          timestamp: DateTime(2026),
          level: LogLevel.error,
          text: 'first at /Users/alice/x',
          source: 'app',
        ),
      ];
      final p = await call('POST', '/api/report/preview', {
        'kind': 'bug',
        'title': 'it broke',
        'body': 'details',
        'attach': {'logs': 50},
      });
      expect(p['ok'], isTrue);
      expect(p['labeled'], isTrue);
      expect(p['body'], contains('first at ~/x'));
      expect(p['body'], contains('| from | dashboard |'));
      logs = [...logs, LogEntry(seq: 2, timestamp: DateTime(2026), level: LogLevel.info, text: 'later', source: 'app')];

      final s = await call('POST', '/api/report/send', {'digest': p['digest']});
      expect(s['ok'], isTrue);
      expect(s['number'], 70);
      expect(gh.bodies.single, p['body']);
      expect(gh.bodies.single, isNot(contains('later')));
    });

    test('an unknown digest is refused', () async {
      final s = await call('POST', '/api/report/send', {'digest': '0123456789abcdef'});
      expect(s['ok'], isFalse);
      expect(gh.calls.where((c) => c.contains('create')), isEmpty);
    });

    test('bad input', () async {
      expect((await call('POST', '/api/report/preview', {'kind': 'rant', 'title': 'x'}))['ok'], isFalse);
      expect((await call('POST', '/api/report/preview', {'kind': 'bug', 'title': ''}))['error'], contains('title'));
    });
  });
}
