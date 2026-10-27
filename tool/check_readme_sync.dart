// Checks that README.md and README.ko.md share one structure — the same
// headings (level by level, in order) and the same number of code blocks —
// so a section added to one is not silently missing from the other.
// Wording is not compared; only the shape a translation must keep.
//
// Run: dart run tool/check_readme_sync.dart
import 'dart:io';

typedef Heading = ({int level, String text, int line});

/// The structure of a Markdown document: its ATX headings and how many fenced
/// code blocks it has. Lines inside a fence (``` or ~~~) are code, not headings.
({List<Heading> headings, int codeBlocks}) markdownShape(String md) {
  final headings = <Heading>[];
  var codeBlocks = 0;
  String? fence;
  final lines = md.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final open = RegExp(r'^\s{0,3}(`{3,}|~{3,})').firstMatch(line);
    if (fence == null) {
      if (open != null) {
        fence = open.group(1);
        codeBlocks++;
        continue;
      }
      final h = RegExp(r'^#{1,6}(?=\s)').firstMatch(line);
      if (h != null) headings.add((level: h.group(0)!.length, text: line.trim(), line: i + 1));
    } else if (open != null && open.group(1)![0] == fence[0] && open.group(1)!.length >= fence.length) {
      fence = null;
    }
  }
  return (headings: headings, codeBlocks: codeBlocks);
}

/// What differs between two shapes; empty when they match. Headings are
/// reported at the first one whose level differs (or that one side lacks),
/// since everything after it is shifted.
List<String> shapeDiff(
    ({List<Heading> headings, int codeBlocks}) a, ({List<Heading> headings, int codeBlocks}) b) {
  final out = <String>[];
  final n = a.headings.length > b.headings.length ? a.headings.length : b.headings.length;
  for (var i = 0; i < n; i++) {
    final x = i < a.headings.length ? a.headings[i] : null;
    final y = i < b.headings.length ? b.headings[i] : null;
    if (x?.level == y?.level) continue;
    String show(Heading? h) => h == null ? '(none)' : 'line ${h.line}: ${h.text}';
    out.add('heading #${i + 1} differs:\n  ${show(x)}\n  ${show(y)}');
    break;
  }
  if (a.headings.length != b.headings.length) {
    out.add('heading count: ${a.headings.length} vs ${b.headings.length}');
  }
  if (a.codeBlocks != b.codeBlocks) out.add('code blocks: ${a.codeBlocks} vs ${b.codeBlocks}');
  return out;
}

void main() {
  final en = File('README.md');
  final ko = File('README.ko.md');
  if (!en.existsSync() || !ko.existsSync()) {
    stderr.writeln('README.md / README.ko.md not found; run from the package root.');
    exit(1);
  }
  final diff = shapeDiff(markdownShape(en.readAsStringSync()), markdownShape(ko.readAsStringSync()));
  if (diff.isNotEmpty) {
    stderr.writeln('README.md and README.ko.md differ in structure (README.md first):');
    for (final d in diff) {
      stderr.writeln(d);
    }
    exit(1);
  }
  stdout.writeln('README.md and README.ko.md match in structure');
}
