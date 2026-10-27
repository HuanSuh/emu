import 'dart:io';

import 'package:test/test.dart';

import '../tool/check_readme_sync.dart';

void main() {
  test('headings and code blocks are read outside fences only', () {
    final shape = markdownShape('''
# Title
## A
```sh
# a comment, not a heading
```
### B
~~~
## also not a heading
~~~
#not-a-heading
''');
    expect(shape.headings.map((h) => h.level), [1, 2, 3]);
    expect(shape.headings.map((h) => h.line), [1, 2, 6]);
    expect(shape.codeBlocks, 2);
  });

  test('a translation with the same structure matches', () {
    expect(shapeDiff(markdownShape('## Install\n```\nx\n```\n### Build\n'),
            markdownShape('## 설치\n```\nx\n```\n### 빌드\n')),
        isEmpty);
  });

  test('a missing section is reported at the first heading that differs', () {
    final diff = shapeDiff(markdownShape('## A\n### A1\n## B\n'), markdownShape('## 가\n## 나\n'));
    expect(diff, hasLength(2));
    expect(diff.first, contains('heading #2'));
    expect(diff.first, contains('### A1'));
    expect(diff.first, contains('## 나'));
    expect(diff.last, 'heading count: 3 vs 2');
  });

  test('a heading at another level is reported', () {
    expect(shapeDiff(markdownShape('## A\n### B\n'), markdownShape('## 가\n#### 나\n')).single,
        contains('heading #2'));
  });

  test('a different number of code blocks is reported', () {
    expect(shapeDiff(markdownShape('## A\n```\nx\n```\n```\ny\n```\n'), markdownShape('## 가\n```\nx\n```\n')).single,
        contains('code blocks: 2 vs 1'));
  });

  test('README.md and README.ko.md share one structure', () {
    expect(shapeDiff(markdownShape(File('README.md').readAsStringSync()),
            markdownShape(File('README.ko.md').readAsStringSync())),
        isEmpty);
  });
}
