import '../harness/harness_catalog.dart';
import 'mcp_types.dart';
import 'mcp_validation_contract.dart';

export 'mcp_validation_contract.dart';

/// The shared, inert schema evaluator. The composed harness catalog owns the
/// per-harness Zema contract; [McpValidationService] owns the public seam.
final class McpValidation {
  const McpValidation();

  McpValidationReport validate({
    required McpHarness harness,
    required Map<String, Object?> fields,
    McpScope? scope,
  }) => HarnessCatalog.instance
      .mcpSpec(harness)
      .validation
      .validate(harness: harness, fields: fields, scope: scope);
}
