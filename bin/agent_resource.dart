import 'package:agent_resource/agent_resource.dart';
import 'package:mamba/mamba.dart' show chalk;

Future<void> main(List<String> args) {
  // Reports must remain parseable JSON even on Mamba's failure stream.
  chalk.level = 0;
  return createExecutor().create().execute(args);
}
