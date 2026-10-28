/// **ValidationRules Class - Builder pattern for validation**
///
/// Provides a fluent builder pattern for combining multiple validations.
/// Implements callable functionality to work seamlessly with validation systems.
library;

import 'validator.dart';

/// **ValidationRules - Fluent builder for validatio  /// **Alpha Dash Rule** - Letters, numbers, dashes, underscores only chains**
///
/// Create validation rules using a builder pattern and use directly as validator:
/// ```dart
/// // Basic builder usage (for r  /// **Custom Rule** - Add custom validation functionuse)
/// final validator = ValidationRules()
///   .required()
///   .min(8)
///   .email();
///
/// // Direct validation usage
/// validator: (value) => ValidationRules(value)
///   .required()
///   .email()
///
/// // Use directly in Input
/// final input = Input(
///   prompt: 'Enter email',
///   validator: (value) => ValidationRules(value)
///     .required()
///     .email(),
/// );
///
/// // More complex validation
/// final passwordValidator = ValidationRules()
///   .required()
///   .min(8)
///   .pattern(RegExp(r'[A-Z]'), message: 'Must contain uppercase')
///   .pattern(RegExp(r'[0-9]'), message: 'Must contain numbers');
/// ```
class ValidationRules {
  final List<String? Function(String)> _rules = [];
  final String? _value;

  /// **Constructor** - Create validation rules with optional value for direct validation
  ///
  /// ```dart
  /// // For reuse
  /// ValidationRules().required().email()
  ///
  /// // For direct validation
  /// ValidationRules(value).required().email()
  /// ```
  ValidationRules([this._value]);

  /// **Call Implementation** - Makes class callable as a validator function
  ///
  /// This allows using ValidationRules directly as a validator:
  /// ```dart
  /// // For reuse pattern
  /// final validator = ValidationRules().required().min(3);
  /// validator(someValue);
  ///
  /// // For direct validation pattern
  /// ValidationRules(value).required().email();
  /// ```
  String? call([String? value]) {
    // If value was provided in constructor, use it for direct validation
    if (_value != null) {
      for (final rule in _rules) {
        final result = rule(_value);
        if (result != null) return result;
      }
      return null;
    }

    // Otherwise, expect value in call method (reuse pattern)
    if (value == null) {
      throw ArgumentError(
        'Value must be provided either in constructor ValidationRules(value) or call method validator(value)',
      );
    }

    for (final rule in _rules) {
      final result = rule(value);
      if (result != null) return result;
    }
    return null;
  }

  /// **Required Rule** - Value must not be empty
  ///
  /// ```dart
  /// ValidationRules().required()  // For reuse
  /// ValidationRules(value).required()  // Continue chaining or return error
  /// ```
  dynamic required({String? message}) {
    _rules.add((value) => Validator.required(value, message: message));

    // If value was provided in constructor, check if current validation fails
    if (_value != null) {
      final currentResult = Validator.required(_value, message: message);
      if (currentResult != null) {
        // Validation failed, return error immediately
        return currentResult;
      }
      // Validation passed, continue chaining
      return this;
    }

    // No value provided, return this for chaining
    return this;
  }

  /// **Minimum Length Rule** - Value must have minimum character count
  ///
  /// ```dart
  /// ValidationRules().min(8)  // For reuse
  /// ValidationRules(value).min(3)  // Direct validation returns String?
  /// ```
  dynamic min(int minLength, {String? message}) {
    _rules.add((value) => Validator.min(value, minLength, message: message));

    // If value was provided in constructor, execute validation immediately
    if (_value != null) {
      return call();
    }

    // Otherwise return this for chaining
    return this;
  }

  /// **Maximum Length Rule** - Value must not exceed maximum character count
  ///
  /// ```dart
  /// ValidationRules().max(20)  // For reuse
  /// ValidationRules(value).max(100)  // Direct validation returns String?
  /// ```
  dynamic max(int maxLength, {String? message}) {
    _rules.add((value) => Validator.max(value, maxLength, message: message));

    // If value was provided in constructor, execute validation immediately
    if (_value != null) {
      return call();
    }

    // Otherwise return this for chaining
    return this;
  }

  /// **Email Rule** - Value must be valid email format
  ///
  /// ```dart
  /// ValidationRules().email()  // For reuse
  /// ValidationRules(value).email()  // Return validation result
  /// ```
  dynamic email({String? message}) {
    _rules.add((value) => Validator.email(value, message: message));

    // If value was provided in constructor, execute all validations
    if (_value != null) {
      return call();
    }

    // Otherwise return this for chaining
    return this;
  }

  /// **Pattern Rule** - Value must match custom regex pattern
  ///
  /// ```dart
  /// ValidationRules().pattern(RegExp(r'[A-Z]'), message: 'Must contain uppercase')
  /// ValidationRules().pattern(RegExp(r'^[0-9]+$'))  // Numbers only
  /// ```
  ValidationRules pattern(RegExp pattern, {String? message}) {
    _rules.add((value) => Validator.pattern(value, pattern, message: message));
    return this;
  }

  /// **Alphabetic Rule** - Value must contain only letters
  ///
  /// ```dart
  /// ValidationRules().alpha()
  /// ValidationRules().alpha(message: 'Name must contain only letters')
  /// ```
  ValidationRules alpha({String? message}) {
    _rules.add((value) => Validator.alpha(value, message: message));
    return this;
  }

  /// **Alphanumeric Rule** - Value must contain only letters and numbers
  ///
  /// ```dart
  /// ValidationRules().alphaNumeric()  // For reuse
  /// ValidationRules(value).alphaNumeric()  // Direct validation returns String?
  /// ```
  dynamic alphaNumeric({String? message}) {
    _rules.add((value) => Validator.alphaNumeric(value, message: message));

    // If value was provided in constructor, execute validation immediately
    if (_value != null) {
      return call();
    }

    // Otherwise return this for chaining
    return this;
  }

  /// **Numeric Rule** - Value must contain only numbers
  ///
  /// ```dart
  /// ValidationRules().numeric()
  /// ValidationRules().numeric(message: 'Please enter numbers only')
  /// ```
  ValidationRules numeric({String? message}) {
    _rules.add((value) => Validator.numeric(value, message: message));
    return this;
  }

  /// **URL Rule** - Value must be valid URL format
  ///
  /// ```dart
  /// ValidationRules().url()
  /// ValidationRules().url(message: 'Please enter a valid website URL')
  /// ```
  ValidationRules url({String? message}) {
    _rules.add((value) => Validator.url(value, message: message));
    return this;
  }

  /// **Starts With Rule** - Value must start with specific text
  ///
  /// ```dart
  /// ValidationRules().startsWith('https://')
  /// ValidationRules().startsWith('Mr.', message: 'Title must start with Mr.')
  /// ```
  ValidationRules startsWith(String prefix, {String? message}) {
    _rules.add(
      (value) => Validator.startsWith(value, prefix, message: message),
    );
    return this;
  }

  /// **Ends With Rule** - Value must end with specific text
  ///
  /// ```dart
  /// ValidationRules().endsWith('.com')
  /// ValidationRules().endsWith('.pdf', message: 'File must be PDF format')
  /// ```
  ValidationRules endsWith(String suffix, {String? message}) {
    _rules.add((value) => Validator.endsWith(value, suffix, message: message));
    return this;
  }

  /// **Contains Rule** - Value must contain specific text
  ///
  /// ```dart
  /// ValidationRules().contains('@')
  /// ValidationRules().contains('admin', message: 'Username must contain admin')
  /// ```
  ValidationRules contains(String substring, {String? message}) {
    _rules.add(
      (value) => Validator.contains(value, substring, message: message),
    );
    return this;
  }

  /// **Not Contains Rule** - Value must not contain specific text
  ///
  /// ```dart
  /// ValidationRules().notContains(' ')  // No spaces
  /// ValidationRules().notContains('admin', message: 'Username cannot contain admin')
  /// ```
  ValidationRules notContains(String substring, {String? message}) {
    _rules.add(
      (value) => Validator.notContains(value, substring, message: message),
    );
    return this;
  }

  /// **In List Rule** - Value must be one of allowed options
  ///
  /// ```dart
  /// ValidationRules().inList(['red', 'green', 'blue'])
  /// ValidationRules().inList(['admin', 'user'], message: 'Invalid role selected')
  /// ```
  ValidationRules inList(List<String> allowedValues, {String? message}) {
    _rules.add(
      (value) => Validator.inList(value, allowedValues, message: message),
    );
    return this;
  }

  /// **Not In List Rule** - Value must not be one of forbidden options
  ///
  /// ```dart
  /// ValidationRules().notInList(['admin', 'root'])  // For reuse
  /// ValidationRules(value).notInList(['test', 'temp'])  // Direct validation returns String?
  /// ```
  dynamic notInList(List<String> forbiddenValues, {String? message}) {
    _rules.add(
      (value) => Validator.notInList(value, forbiddenValues, message: message),
    );

    // If value was provided in constructor, execute validation immediately
    if (_value != null) {
      return call();
    }

    // Otherwise return this for chaining
    return this;
  }

  /// **� Alpha Dash Rule** - Letters, numbers, dashes, underscores only
  ///
  /// ```dart
  /// ValidationRules().alphaDash()  // For reuse
  /// ValidationRules(value).alphaDash()  // Direct validation returns String?
  /// ```
  dynamic alphaDash({String? message}) {
    _rules.add((value) => Validator.alphaDash(value, message: message));

    // If value was provided in constructor, execute validation immediately
    if (_value != null) {
      return call();
    }

    // Otherwise return this for chaining
    return this;
  }

  /// **Lowercase Rule** - Must be all lowercase
  ///
  /// ```dart
  /// ValidationRules().lowercase()  // For reuse
  /// ValidationRules(value).lowercase()  // Direct validation returns String?
  /// ```
  dynamic lowercase({String? message}) {
    _rules.add((value) => Validator.lowercase(value, message: message));

    // If value was provided in constructor, execute validation immediately
    if (_value != null) {
      return call();
    }

    // Otherwise return this for chaining
    return this;
  }

  /// **Uppercase Rule** - Must be all uppercase
  ///
  /// ```dart
  /// ValidationRules().uppercase()  // For reuse
  /// ValidationRules(value).uppercase()  // Direct validation returns String?
  /// ```
  dynamic uppercase({String? message}) {
    _rules.add((value) => Validator.uppercase(value, message: message));

    // If value was provided in constructor, execute validation immediately
    if (_value != null) {
      return call();
    }

    // Otherwise return this for chaining
    return this;
  }

  /// **Contains Uppercase Rule** - Must contain uppercase letters
  ///
  /// ```dart
  /// ValidationRules().containsUppercase()  // At least 1
  /// ValidationRules().containsUppercase(min: 2, max: 4)  // Between 2-4
  /// ValidationRules(value).containsUppercase()  // Direct validation
  /// ```
  dynamic containsUppercase({int min = 1, int? max, String? message}) {
    _rules.add(
      (value) => Validator.containsUppercase(
        value,
        min: min,
        max: max,
        message: message,
      ),
    );

    // If value was provided in constructor, execute validation immediately
    if (_value != null) {
      return call();
    }

    // Otherwise return this for chaining
    return this;
  }

  /// **Contains Lowercase Rule** - Must contain lowercase letters
  ///
  /// ```dart
  /// ValidationRules().containsLowercase()  // At least 1
  /// ValidationRules().containsLowercase(min: 2, max: 4)  // Between 2-4
  /// ValidationRules(value).containsLowercase()  // Direct validation
  /// ```
  dynamic containsLowercase({int min = 1, int? max, String? message}) {
    _rules.add(
      (value) => Validator.containsLowercase(
        value,
        min: min,
        max: max,
        message: message,
      ),
    );

    // If value was provided in constructor, execute validation immediately
    if (_value != null) {
      return call();
    }

    // Otherwise return this for chaining
    return this;
  }

  /// **Contains Digit Rule** - Must contain digits
  ///
  /// ```dart
  /// ValidationRules().containsDigit()  // At least 1
  /// ValidationRules().containsDigit(min: 2, max: 4)  // Between 2-4
  /// ValidationRules(value).containsDigit()  // Direct validation
  /// ```
  dynamic containsDigit({int min = 1, int? max, String? message}) {
    _rules.add(
      (value) =>
          Validator.containsDigit(value, min: min, max: max, message: message),
    );

    // If value was provided in constructor, execute validation immediately
    if (_value != null) {
      return call();
    }

    // Otherwise return this for chaining
    return this;
  }

  /// **Contains Special Character Rule** - Must contain special characters
  ///
  /// ```dart
  /// ValidationRules().containsSpecial()  // At least 1
  /// ValidationRules().containsSpecial(min: 2, max: 4)  // Between 2-4
  /// ValidationRules(value).containsSpecial()  // Direct validation
  /// ```
  dynamic containsSpecial({int min = 1, int? max, String? message}) {
    _rules.add(
      (value) => Validator.containsSpecial(
        value,
        min: min,
        max: max,
        message: message,
      ),
    );

    // If value was provided in constructor, execute validation immediately
    if (_value != null) {
      return call();
    }

    // Otherwise return this for chaining
    return this;
  }

  /// **Length Between Rule** - Length must be within range
  ///
  /// ```dart
  /// ValidationRules().lengthBetween(3, 8)  // For reuse
  /// ValidationRules(value).lengthBetween(5, 15)  // Direct validation
  /// ```
  dynamic lengthBetween(int min, int max, {String? message}) {
    _rules.add(
      (value) => Validator.lengthBetween(value, min, max, message: message),
    );

    // If value was provided in constructor, execute validation immediately
    if (_value != null) {
      return call();
    }

    // Otherwise return this for chaining
    return this;
  }

  /// **Equals Rule** - Must equal specific value
  ///
  /// ```dart
  /// ValidationRules().equals('expected')  // For reuse
  /// ValidationRules(value).equals('confirm')  // Direct validation
  /// ```
  dynamic equals(String expected, {String? message}) {
    _rules.add((value) => Validator.equals(value, expected, message: message));

    // If value was provided in constructor, execute validation immediately
    if (_value != null) {
      return call();
    }

    // Otherwise return this for chaining
    return this;
  }

  /// **Not Equals Rule** - Must not equal specific value
  ///
  /// ```dart
  /// ValidationRules().notEquals('admin')  // For reuse
  /// ValidationRules(value).notEquals('password')  // Direct validation
  /// ```
  dynamic notEquals(String forbidden, {String? message}) {
    _rules.add(
      (value) => Validator.notEquals(value, forbidden, message: message),
    );

    // If value was provided in constructor, execute validation immediately
    if (_value != null) {
      return call();
    }

    // Otherwise return this for chaining
    return this;
  }

  /// **�🔗 Custom Rule** - Add custom validation function
  ///
  /// ```dart
  /// ValidationRules().custom((value) {
  ///   if (value.contains('password')) {
  ///     return 'Password cannot contain the word "password"';
  ///   }
  ///   return null;
  /// })
  /// ```
  ValidationRules custom(String? Function(String) customValidator) {
    _rules.add(customValidator);
    return this;
  }

  /// **Rule Count** - Get number of validation rules
  ///
  /// Useful for debugging or testing:
  /// ```dart
  /// final validator = ValidationRules().required().min(8).email();
  /// print('Total rules: ${validator.ruleCount}'); // Total rules: 3
  /// ```
  int get ruleCount => _rules.length;

  /// **Clear Rules** - Remove all validation rules
  ///
  /// ```dart
  /// final validator = ValidationRules().required().min(8);
  /// validator.clear(); // Now has no rules
  /// ```
  ValidationRules clear() {
    _rules.clear();
    return this;
  }

  /// **Description** - Get human-readable description of rules
  ///
  /// Useful for debugging or displaying validation requirements:
  /// ```dart
  /// final validator = ValidationRules().required().min(8).email();
  /// print(validator.describe()); // "Required, Min 8 chars, Valid email"
  /// ```
  String describe() {
    if (_rules.isEmpty) return 'No validation rules';

    // This is a simplified description - you could enhance it by tracking rule types
    return 'Validation rules: ${_rules.length} rule${_rules.length == 1 ? '' : 's'} configured';
  }
}
