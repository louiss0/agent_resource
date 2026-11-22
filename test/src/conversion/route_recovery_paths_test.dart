import 'package:agent_resource/src/conversion/route_recovery_paths.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('derives deterministic distinct paths for equal basenames', () {
    final paths = RouteRecoveryPaths(p.posix);
    final a = paths.forLocation(
      '/volume/skills',
      '/volume/skills/a/demo',
      'trx_${'a' * 32}',
    );
    final b = paths.forLocation(
      '/volume/skills',
      '/volume/skills/b/demo',
      'trx_${'a' * 32}',
    );
    expect(
      a,
      paths.forLocation(
        '/volume/skills',
        '/volume/skills/a/demo',
        'trx_${'a' * 32}',
      ),
    );
    expect(a.staged, isNot(b.staged));
    expect(a.quarantine, isNot(b.quarantine));
    expect(
      a.staged,
      startsWith('/volume/.agent-resource/staging/trx_${'a' * 32}/'),
    );
    expect(
      a.quarantine,
      startsWith('/volume/.agent-resource/quarantine/trx_${'a' * 32}/'),
    );
  });
}
