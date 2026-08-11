/// Version info + update checking against GitHub tags.
///
/// `kEmuVersion` is baked in at compile time by build.sh via
/// `--define=EMU_VERSION=x.y.z` (read from pubspec.yaml), so the check works
/// from the compiled binary with no bundled source files.
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

const String kEmuVersion = String.fromEnvironment('EMU_VERSION', defaultValue: '0.0.0-dev');

const _repoSlug = 'HuanSuh/emu';

/// The source checkout backing the running binary, resolved through the PATH
/// symlink `emu-setup` creates (`ln -sf $CLAUDE_PLUGIN_ROOT/emu <path>/emu`).
/// Null if the binary isn't sitting next to a git checkout of emu (e.g. run
/// via `dart run` in dev, or a copied-out binary).
Directory? emuRepoRoot() {
  final dir = File(Platform.resolvedExecutable).parent;
  if (File('${dir.path}/pubspec.yaml').existsSync() && Directory('${dir.path}/.git').existsSync()) {
    return dir;
  }
  return null;
}

/// Highest `vX.Y.Z` tag published on GitHub, or null on any network/parse
/// failure (offline, rate-limited, no tags yet).
Future<String?> latestReleaseVersion() async {
  try {
    final r = await http
        .get(Uri.parse('https://api.github.com/repos/$_repoSlug/tags'),
            headers: {'Accept': 'application/vnd.github+json'})
        .timeout(const Duration(seconds: 5));
    if (r.statusCode != 200) return null;
    final tags = (jsonDecode(r.body) as List)
        .map((t) => (t as Map<String, dynamic>)['name'] as String)
        .where((n) => RegExp(r'^v?\d+\.\d+\.\d+$').hasMatch(n))
        .map((n) => n.startsWith('v') ? n.substring(1) : n)
        .toList();
    if (tags.isEmpty) return null;
    tags.sort(compareSemver);
    return tags.last;
  } catch (_) {
    return null;
  }
}

/// Ascending comparator for `x.y.z` version strings (no pre-release/build
/// metadata support — this repo doesn't use them).
int compareSemver(String a, String b) {
  final pa = a.split('.').map(int.parse).toList();
  final pb = b.split('.').map(int.parse).toList();
  for (var i = 0; i < 3; i++) {
    final c = pa[i].compareTo(pb[i]);
    if (c != 0) return c;
  }
  return 0;
}

bool isNewer(String candidate, String current) => compareSemver(candidate, current) > 0;
