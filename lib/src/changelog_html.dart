/// The hub's "What changed" (`/api/version` `notesHtml`): the CHANGELOG
/// sections [changelogBetween] cut out, as HTML. The CHANGELOG comes from
/// GitHub, so it is not trusted: every character is escaped first, and only
/// the markdown this file uses becomes tags — headings, lists (nested, with
/// wrapped lines), paragraphs, code fences, `code`, **bold** and http(s)
/// links (new tab, `noopener`). Anything else stays visible as text.
library;

const _esc = {'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'};

String escapeHtml(String s) => s.replaceAllMapped(RegExp('[&<>"\']'), (m) => _esc[m[0]]!);

/// [markdown] as safe HTML.
String renderChangelogHtml(String markdown) {
  final out = StringBuffer();
  final para = <String>[];
  // Open lists: the indent of each level's markers. An item stays open until
  // the next marker or the list ends, so wrapped lines can join it.
  final lists = <int>[];
  final item = <String>[];
  List<String>? fence;

  void flushItem() {
    if (item.isNotEmpty) out.write(_inline(item.join(' ')));
    item.clear();
  }

  void closeLists([int toDepth = 0]) {
    while (lists.length > toDepth) {
      flushItem();
      out.write('</li></ul>');
      lists.removeLast();
    }
  }

  void flushPara() {
    if (para.isNotEmpty) out.write('<p>${_inline(para.join(' '))}</p>');
    para.clear();
  }

  for (final raw in markdown.replaceAll(RegExp('[\u0000\u0001]'), '').replaceAll('\r\n', '\n').split('\n')) {
    final line = raw.replaceAll('\t', '    ');
    if (fence != null) {
      if (line.trimLeft().startsWith('```')) {
        out.write('<pre><code>${escapeHtml(fence.join('\n'))}</code></pre>');
        fence = null;
      } else {
        fence.add(line);
      }
      continue;
    }
    if (line.trimLeft().startsWith('```')) {
      flushPara();
      closeLists();
      fence = [];
      continue;
    }
    if (line.trim().isEmpty) {
      flushPara();
      continue;
    }
    final h = RegExp(r'^(#{1,6})\s+(.*?)(?:\s+#+)?\s*$').firstMatch(line);
    if (h != null) {
      flushPara();
      closeLists();
      // ## [0.16.0] - date → 0.16.0 - date (a reference link with no target here).
      final text = h[2]!.replaceFirstMapped(RegExp(r'^\[([^\]]+)\](?!\()'), (m) => m[1]!);
      final tag = h[1]!.length <= 2 ? 'h3' : 'h4';
      out.write('<$tag>${_inline(text)}</$tag>');
      continue;
    }
    if (RegExp(r'^\s{0,3}\[[^\]]+\]:\s*\S').hasMatch(line)) continue; // link reference definition
    final li = RegExp(r'^(\s*)[-*+]\s+(.*)$').firstMatch(line);
    if (li != null) {
      flushPara();
      final indent = li[1]!.length;
      if (lists.isEmpty || indent > lists.last) {
        flushItem();
        out.write('<ul><li>');
        lists.add(indent);
      } else {
        while (lists.length > 1 && indent < lists.last) {
          closeLists(lists.length - 1);
        }
        flushItem();
        out.write('</li><li>');
      }
      item.add(li[2]!.trim());
      continue;
    }
    if (lists.isNotEmpty) {
      item.add(line.trim()); // a wrapped line of the open item
      continue;
    }
    para.add(line.trim());
  }
  if (fence != null) out.write('<pre><code>${escapeHtml(fence.join('\n'))}</code></pre>');
  flushPara();
  closeLists();
  return out.toString();
}

/// One line of text: `code`, **bold**, [links](http…); the rest escaped.
String _inline(String text) {
  final codes = <String>[];
  // Code spans first, so nothing inside them is read as markdown.
  var s = text.replaceAllMapped(RegExp(r'(`+)(.+?)\1'), (m) {
    codes.add('<code>${escapeHtml(m[2]!.trim())}</code>');
    return '\u0000${codes.length - 1}\u0000';
  });
  s = escapeHtml(s);
  // Links next, also set aside as whole tags: a `**` in a URL, or bold that
  // starts outside a link and ends inside it, can't split a tag.
  final links = <String>[];
  s = s.replaceAllMapped(RegExp(r'\[([^\]]+)\]\(([^)\s]+)\)'), (m) {
    final href = m[2]!;
    // Escaped already, so it can't leave the attribute; only web links.
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(href) || href.contains('\u0000')) return m[1]!;
    final text = m[1]!.replaceAllMapped(RegExp(r'\*\*(.+?)\*\*'), (b) => '<strong>${b[1]}</strong>');
    links.add('<a href="$href" target="_blank" rel="noopener noreferrer">$text</a>');
    return '\u0001${links.length - 1}\u0001';
  });
  s = s.replaceAllMapped(RegExp(r'\*\*(.+?)\*\*'), (m) => '<strong>${m[1]}</strong>');
  s = s.replaceAllMapped(RegExp('\u0001(\\d+)\u0001'), (m) => links[int.parse(m[1]!)]);
  return s.replaceAllMapped(RegExp('\u0000(\\d+)\u0000'), (m) => codes[int.parse(m[1]!)]);
}
