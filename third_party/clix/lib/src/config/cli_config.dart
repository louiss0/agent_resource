import 'dart:convert';
import 'dart:io';
import '../logger/logger.dart';
import '../core/style/color.dart';
import '../exceptions/cli_config_exception.dart';

/// Configuration value with validation and metadata
class ConfigValue {
  final dynamic value;
  final dynamic defaultValue;
  final String? description;
  final bool required;
  final List<dynamic>? allowedValues;
  final String? type;

  const ConfigValue({
    required this.value,
    this.defaultValue,
    this.description,
    this.required = false,
    this.allowedValues,
    this.type,
  });

  /// Get the effective value (value or default)
  T getValue<T>() {
    return (value ?? defaultValue) as T;
  }

  /// Check if this value is valid
  bool get isValid {
    if (required && value == null && defaultValue == null) {
      return false;
    }

    if (allowedValues != null && value != null) {
      return allowedValues!.contains(value);
    }

    return true;
  }

  /// Get validation error message
  String? get validationError {
    if (required && value == null && defaultValue == null) {
      return 'Required value is missing';
    }

    if (allowedValues != null &&
        value != null &&
        !allowedValues!.contains(value)) {
      return 'Value must be one of: ${allowedValues!.join(', ')}';
    }

    return null;
  }
}

/// Configuration manager for CLI applications
class CliConfig {
  final Map<String, ConfigValue> _values = {};
  final Map<String, dynamic> _rawData = {};
  final CliLogger? _logger;
  String? _configPath;

  CliConfig({CliLogger? logger}) : _logger = logger;

  /// Update defined values with loaded raw data
  void _updateDefinedValues() {
    for (final key in _values.keys) {
      final value = _getNestedValue(_rawData, key);
      if (value != null) {
        final configValue = _values[key]!;
        _values[key] = ConfigValue(
          value: value,
          defaultValue: configValue.defaultValue,
          description: configValue.description,
          required: configValue.required,
          allowedValues: configValue.allowedValues,
          type: configValue.type,
        );
      }
    }
  }

  /// Get nested value using dot notation (e.g., 'app.name')
  dynamic _getNestedValue(Map<String, dynamic> data, String key) {
    final parts = key.split('.');
    dynamic current = data;

    for (final part in parts) {
      if (current is Map<String, dynamic> && current.containsKey(part)) {
        current = current[part];
      } else {
        return null;
      }
    }

    return current;
  }

  /// Load configuration from a JSON file
  Future<void> loadFromJson(String filePath) async {
    _configPath = filePath;

    try {
      final file = File(filePath);
      if (!file.existsSync()) {
        _logger?.warn('Configuration file not found: $filePath');
        return;
      }

      final content = await file.readAsString();
      final data = json.decode(content) as Map<String, dynamic>;

      _rawData.clear();
      _rawData.addAll(data);
      _updateDefinedValues();

      _logger?.success('Configuration loaded from: $filePath');
    } catch (e) {
      throw CliConfigException('Failed to load JSON configuration', filePath);
    }
  }

  /// Load configuration from a YAML-like file (simple key: value format)
  Future<void> loadFromSimpleYaml(String filePath) async {
    _configPath = filePath;

    try {
      final file = File(filePath);
      if (!file.existsSync()) {
        _logger?.warn('Configuration file not found: $filePath');
        return;
      }

      final content = await file.readAsString();
      final data = <String, dynamic>{};

      for (final line in content.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('#')) continue;

        if (trimmed.contains(':')) {
          final parts = trimmed.split(':');
          if (parts.length >= 2) {
            final key = parts[0].trim();
            final value = parts.sublist(1).join(':').trim();

            // Try to parse as different types
            if (value.toLowerCase() == 'true') {
              data[key] = true;
            } else if (value.toLowerCase() == 'false') {
              data[key] = false;
            } else if (RegExp(r'^\d+$').hasMatch(value)) {
              data[key] = int.tryParse(value) ?? value;
            } else if (RegExp(r'^\d+\.\d+$').hasMatch(value)) {
              data[key] = double.tryParse(value) ?? value;
            } else {
              // Remove quotes if present
              if ((value.startsWith('"') && value.endsWith('"')) ||
                  (value.startsWith("'") && value.endsWith("'"))) {
                data[key] = value.substring(1, value.length - 1);
              } else {
                data[key] = value;
              }
            }
          }
        }
      }

      _rawData.clear();
      _rawData.addAll(data);
      _updateDefinedValues();

      _logger?.success('Configuration loaded from: $filePath');
    } catch (e) {
      throw CliConfigException('Failed to load YAML configuration', filePath);
    }
  }

  /// Load configuration from a Map
  void loadFromMap(Map<String, dynamic> data) {
    _rawData.clear();
    _rawData.addAll(data);
    _updateDefinedValues();
    _logger?.success('Configuration loaded from Map');
  }

  /// Define a configuration value with validation
  void define(
    String key, {
    dynamic defaultValue,
    String? description,
    bool required = false,
    List<dynamic>? allowedValues,
    String? type,
  }) {
    final rawValue = _rawData[key];

    _values[key] = ConfigValue(
      value: rawValue,
      defaultValue: defaultValue,
      description: description,
      required: required,
      allowedValues: allowedValues,
      type: type,
    );
  }

  /// Get a configuration value
  T? get<T>(String key) {
    final configValue = _values[key];
    if (configValue != null) {
      return configValue.getValue<T>();
    }

    // Fallback to raw data
    return _rawData[key] as T?;
  }

  /// Get a required configuration value
  T getRequired<T>(String key) {
    final value = get<T>(key);
    if (value == null) {
      throw CliConfigException('Required configuration key "$key" not found');
    }
    return value;
  }

  /// Check if a key exists
  bool has(String key) {
    return _values.containsKey(key) || _rawData.containsKey(key);
  }

  /// Validate all defined configuration values
  bool validate({bool throwOnError = false}) {
    final errors = <String>[];

    for (final entry in _values.entries) {
      final key = entry.key;
      final value = entry.value;

      if (!value.isValid) {
        final error = '$key: ${value.validationError}';
        errors.add(error);

        if (throwOnError) {
          throw CliConfigException(value.validationError!, key);
        }
      }
    }

    if (errors.isNotEmpty && _logger != null) {
      _logger.error('Configuration validation failed:');
      for (final error in errors) {
        _logger.error('  • $error');
      }
    }

    return errors.isEmpty;
  }

  /// Get all configuration values as a map
  Map<String, dynamic> toMap() {
    final result = <String, dynamic>{};

    for (final entry in _values.entries) {
      result[entry.key] = entry.value.getValue();
    }

    // Add raw data that wasn't defined
    for (final entry in _rawData.entries) {
      if (!_values.containsKey(entry.key)) {
        result[entry.key] = entry.value;
      }
    }

    return result;
  }

  /// Save current configuration to file
  Future<void> save([String? filePath]) async {
    final path = filePath ?? _configPath;
    if (path == null) {
      throw CliConfigException(
        'No file path specified for saving configuration',
      );
    }

    try {
      final file = File(path);
      final data = toMap();

      if (path.endsWith('.json')) {
        const encoder = JsonEncoder.withIndent('  ');
        await file.writeAsString(encoder.convert(data));
      } else {
        // Save as simple YAML format
        final buffer = StringBuffer();
        buffer.writeln('# Configuration file generated by Clix');
        buffer.writeln('# ${DateTime.now().toIso8601String()}');
        buffer.writeln();

        for (final entry in data.entries) {
          final configValue = _values[entry.key];
          if (configValue?.description != null) {
            buffer.writeln('# ${configValue!.description}');
          }

          final value = entry.value;
          if (value is String && value.contains(' ')) {
            buffer.writeln('${entry.key}: "$value"');
          } else {
            buffer.writeln('${entry.key}: $value');
          }
        }

        await file.writeAsString(buffer.toString());
      }

      _logger?.success('Configuration saved to: $path');
    } catch (e) {
      throw CliConfigException('Failed to save configuration', path);
    }
  }

  /// Display configuration in a formatted way
  void display(CliLogger logger) {
    logger.info('📋 Configuration:');

    if (_configPath != null) {
      logger.debug('Source: $_configPath');
    }

    if (_values.isEmpty && _rawData.isEmpty) {
      logger.warn('No configuration loaded');
      return;
    }

    // Show defined values first
    if (_values.isNotEmpty) {
      logger.info('Defined values:');
      for (final entry in _values.entries) {
        final key = entry.key;
        final configValue = entry.value;
        final value = configValue.getValue();

        final status = configValue.isValid ? '✓' : '✗';
        final statusColor = configValue.isValid ? CliColor.green : CliColor.red;

        // Build complete message
        String message = '  ${statusColor(status)} ${CliColor.cyan(key)}: ';

        if (configValue.required) {
          message += '${CliColor.yellow('(required)')} ';
        }

        message += CliColor.white(value.toString());
        logger.output(message);

        if (configValue.description != null) {
          final description = configValue.description!;
          logger.output('    ${CliColor.gray(description)}');
        }
      }
    }

    // Show undefined raw values
    final undefinedKeys = _rawData.keys
        .where((k) => !_values.containsKey(k))
        .toList();
    if (undefinedKeys.isNotEmpty) {
      logger.info('Other values:');
      for (final key in undefinedKeys) {
        final value = _rawData[key];
        logger.output(
          '  ${CliColor.gray('•')} ${CliColor.cyan(key)}: ${CliColor.white(value.toString())}',
        );
      }
    }
  }

  /// Create a template configuration file
  static Future<void> createTemplate(
    String filePath, {
    Map<String, dynamic>? defaultValues,
    CliLogger? logger,
  }) async {
    final defaults =
        defaultValues ??
        {
          'app_name': 'My CLI App',
          'version': '1.0.0',
          'debug': false,
          'log_level': 'info',
          'output_format': 'json',
          'max_retries': 3,
          'timeout_seconds': 30,
        };

    try {
      final file = File(filePath);

      if (filePath.endsWith('.json')) {
        const encoder = JsonEncoder.withIndent('  ');
        await file.writeAsString(encoder.convert(defaults));
      } else {
        final buffer = StringBuffer();
        buffer.writeln('# Configuration template generated by Clix');
        buffer.writeln('# Modify these values according to your needs');
        buffer.writeln();

        for (final entry in defaults.entries) {
          final value = entry.value;
          if (value is String && value.contains(' ')) {
            buffer.writeln('${entry.key}: "$value"');
          } else {
            buffer.writeln('${entry.key}: $value');
          }
        }

        await file.writeAsString(buffer.toString());
      }

      logger?.success('Configuration template created: $filePath');
    } catch (e) {
      throw CliConfigException(
        'Failed to create configuration template',
        filePath,
      );
    }
  }
}
