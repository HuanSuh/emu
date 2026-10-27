import 'package:emu/src/changelog_html.dart';
import 'package:emu/src/hub.dart' show changelogBetween;
import 'package:test/test.dart';

void main() {
  test('version headings, sections, lists with wrapped lines', () {
    final html = renderChangelogHtml('''
## [0.2.0] - 2030-01-01

### Added
- first item that
  wraps onto a second line.
- second item

### Fixed
- a fix
''');
    expect(
        html,
        '<h3>0.2.0 - 2030-01-01</h3>'
        '<h4>Added</h4><ul><li>first item that wraps onto a second line.</li><li>second item</li></ul>'
        '<h4>Fixed</h4><ul><li>a fix</li></ul>');
  });

  test('nested lists', () {
    expect(renderChangelogHtml('- a\n  - a1\n  - a2\n- b\n'),
        '<ul><li>a<ul><li>a1</li><li>a2</li></ul></li><li>b</li></ul>');
  });

  test('code, bold and links', () {
    expect(renderChangelogHtml('use `emu up --json` and **this** — [docs](https://example.com/a?b=1&c=2)'),
        '<p>use <code>emu up --json</code> and <strong>this</strong> — '
        '<a href="https://example.com/a?b=1&amp;c=2" target="_blank" rel="noopener noreferrer">docs</a></p>');
    // Nothing inside code is markdown.
    expect(renderChangelogHtml('`**not bold** [x](https://a.b)`'),
        '<p><code>**not bold** [x](https://a.b)</code></p>');
    expect(renderChangelogHtml('```\n<b>x</b>\n```'), '<pre><code>&lt;b&gt;x&lt;/b&gt;</code></pre>');
  });

  test('HTML in the CHANGELOG stays text', () {
    final html = renderChangelogHtml('''
## [1.0.0] <img src=x onerror=alert(1)>
- <script>alert(1)</script>
- `</code><script>alert(2)</script>`
- **<b onmouseover=x>hi</b>**
''');
    expect(html, isNot(contains('<script')));
    expect(html, isNot(contains('<img')));
    expect(html, isNot(contains('<b ')));
    expect(html, contains('&lt;script&gt;alert(1)&lt;/script&gt;'));
    expect(html, contains('<code>&lt;/code&gt;&lt;script&gt;alert(2)&lt;/script&gt;</code>'));
  });

  test('only http(s) links become links, and they cannot leave the attribute', () {
    expect(renderChangelogHtml('[x](javascript:alert(1))'), isNot(contains('<a')));
    expect(renderChangelogHtml('[x](data:text/html,hi)'), '<p>x</p>');
    expect(renderChangelogHtml('[x](JavaScript:alert(1))'), isNot(contains('href')));
    final quoted = renderChangelogHtml('[x](https://a.b/"onmouseover="alert(1))');
    expect(quoted, isNot(contains('"onmouseover')));
    expect(quoted, contains('&quot;onmouseover=&quot;'));
    // `**` in a URL, or bold crossing a link, cannot split the tag.
    expect(renderChangelogHtml('[x](https://a.b/**y**)'),
        '<p><a href="https://a.b/**y**" target="_blank" rel="noopener noreferrer">x</a></p>');
    expect(renderChangelogHtml('**a [b](https://a.b/c) c** and [**d**](https://e.f)'),
        '<p><strong>a <a href="https://a.b/c" target="_blank" rel="noopener noreferrer">b</a> c</strong> and '
        '<a href="https://e.f" target="_blank" rel="noopener noreferrer"><strong>d</strong></a></p>');
    expect(renderChangelogHtml('**a [b**](https://a.b/c)'),
        '<p>**a <a href="https://a.b/c" target="_blank" rel="noopener noreferrer">b**</a></p>');
    expect(renderChangelogHtml('[`x`](https://a.b)'),
        '<p><a href="https://a.b" target="_blank" rel="noopener noreferrer"><code>x</code></a></p>');
  });

  test('link reference definitions are dropped', () {
    expect(renderChangelogHtml('text\n\n[0.2.0]: https://github.com/x/y/compare/a...b\n'), '<p>text</p>');
  });

  test('renders what changelogBetween cuts', () {
    const log = '# Changelog\n\n## [Unreleased]\n\n## [0.3.0] - 2030-02-01\n### Added\n- three\n\n'
        '## [0.2.0] - 2030-01-01\n### Fixed\n- two\n\n## [0.1.0] - 2029-01-01\n- one\n\n[0.3.0]: https://x\n';
    final html = renderChangelogHtml(changelogBetween(log, '0.1.0', '0.3.0'));
    expect(html, '<h3>0.3.0 - 2030-02-01</h3><h4>Added</h4><ul><li>three</li></ul>'
        '<h3>0.2.0 - 2030-01-01</h3><h4>Fixed</h4><ul><li>two</li></ul>');
  });
}
