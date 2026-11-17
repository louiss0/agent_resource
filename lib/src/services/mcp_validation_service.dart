import '../mcp/mcp_types.dart';
import '../mcp/mcp_validation.dart';

/// The one shared, static per-harness MCP contract.
///
/// Later pack admission and conversion waves must call [validate] with the
/// target harness, the native fields, and the requested scope. The command
/// layer adds bounded native selection; it does not define another contract.
interface class McpValidationService {
  const McpValidationService();

  McpValidationReport validate({
    required McpHarness harness,
    required Map<String, Object?> fields,
    McpScope? scope,
  }) => const McpValidation().validate(
    harness: harness,
    fields: fields,
    scope: scope,
  );
}
