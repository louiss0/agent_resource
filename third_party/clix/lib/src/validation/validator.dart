/// **Validator Class - Static validation methods**
///
/// Provides static validation methods for common input validation scenarios.
/// Each method returns `null` for valid input, or an error message string for invalid input.
library;

/// **Validator - S  /// **Alpha Dash Validation** - Letters, numbers, dashes, underscores onlyatic validation methods collection**
///
/// Comprehensive validation methods for input validation:
/// ```dart
/// // Basic usage
/// final error =  /// **Rules Combiner** - Combine multiple validatorsValidator.required(value);
/// if (error != null) print(error);
///
/// // With custom message
/// final error = Validator.email(email, message: 'Please enter valid email');
///
/// // Combined validation
/// validator: Validator.rules([
///   (value) => Validator.required(value),
///   (value) => Validator.min(value, 8),
///   (value) => Validator.email(value),
/// ]),
/// ```
class Validator {
  /// **Required Validation** - Ensures value is not empty
  ///
  /// Returns error message if value is empty or only whitespace:
  /// ```dart
  /// Validator.required('hello') // null (valid)
  /// Validator.required('   ')   // 'This field is required'
  /// Validator.required('')      // 'This field is required'
  /// ```
  static String? required(String value, {String? message}) {
    if (value.trim().isEmpty) {
      return message ?? 'This field is required';
    }
    return null;
  }

  /// **Minimum Length Validation** - Ensures minimum character count
  ///
  /// Returns error message if value length is less than minimum:
  /// ```dart
  /// Validator.min('hello', 3) // null (valid)
  /// Validator.min('hi', 3)    // 'Must be at least 3 characters'
  /// ```
  static String? min(String value, int minLength, {String? message}) {
    if (value.length < minLength) {
      return message ?? 'Must be at least $minLength characters';
    }
    return null;
  }

  /// **Maximum Length Validation** - Ensures maximum character count
  ///
  /// Returns error message if value length exceeds maximum:
  /// ```dart
  /// Validator.max('hello', 10) // null (valid)
  /// Validator.max('hello', 3)  // 'Must be no more than 3 characters'
  /// ```
  static String? max(String value, int maxLength, {String? message}) {
    if (value.length > maxLength) {
      return message ?? 'Must be no more than $maxLength characters';
    }
    return null;
  }

  /// **Email Validation** - Validates email format
  ///
  /// Uses comprehensive regex to validate email addresses:
  /// ```dart
  /// Validator.email('user@example.com') // null (valid)
  /// Validator.email('invalid-email')    // 'Please enter a valid email address'
  /// ```
  static String? email(String value, {String? message}) {
    final emailRegex = RegExp(
      r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$',
    );
    if (!emailRegex.hasMatch(value)) {
      return message ?? 'Please enter a valid email address';
    }
    return null;
  }

  /// **Pattern Validation** - Custom regex validation
  ///
  /// Validates value against custom regular expression:
  /// ```dart
  /// Validator.pattern('abc123', RegExp(r'^[a-z]+$'))     // 'Invalid format'
  /// Validator.pattern('hello', RegExp(r'^[a-z]+$'))      // null (valid)
  /// ```
  static String? pattern(String value, RegExp pattern, {String? message}) {
    if (!pattern.hasMatch(value)) {
      return message ?? 'Invalid format';
    }
    return null;
  }

  /// **Alphabetic Characters** - Only letters allowed
  ///
  /// Validates that value contains only alphabetic characters:
  /// ```dart
  /// Validator.alpha('hello')    // null (valid)
  /// Validator.alpha('hello123') // 'Only letters are allowed'
  /// ```
  static String? alpha(String value, {String? message}) {
    final alphaRegex = RegExp(r'^[a-zA-Z]+$');
    if (!alphaRegex.hasMatch(value)) {
      return message ?? 'Only letters are allowed';
    }
    return null;
  }

  /// **Alphanumeric Characters** - Letters and numbers only
  ///
  /// Validates that value contains only letters and numbers:
  /// ```dart
  /// Validator.alphaNumeric('hello123') // null (valid)
  /// Validator.alphaNumeric('hello@123') // 'Only letters and numbers are allowed'
  /// ```
  static String? alphaNumeric(String value, {String? message}) {
    final alphaNumRegex = RegExp(r'^[a-zA-Z0-9]+$');
    if (!alphaNumRegex.hasMatch(value)) {
      return message ?? 'Only letters and numbers are allowed';
    }
    return null;
  }

  /// **Numeric Validation** - Numbers only
  ///
  /// Validates that value contains only numeric characters:
  /// ```dart
  /// Validator.numeric('12345')  // null (valid)
  /// Validator.numeric('123abc') // 'Only numbers are allowed'
  /// ```
  static String? numeric(String value, {String? message}) {
    final numericRegex = RegExp(r'^[0-9]+$');
    if (!numericRegex.hasMatch(value)) {
      return message ?? 'Only numbers are allowed';
    }
    return null;
  }

  /// **URL Validation** - Valid URL format
  ///
  /// Validates URL format with http/https protocols:
  /// ```dart
  /// Validator.url('https://example.com') // null (valid)
  /// Validator.url('invalid-url')         // 'Please enter a valid URL'
  /// ```
  static String? url(String value, {String? message}) {
    try {
      final uri = Uri.parse(value);
      if (!uri.hasScheme ||
          !['http', 'https'].contains(uri.scheme.toLowerCase())) {
        return message ?? 'Please enter a valid URL';
      }
      if (uri.host.isEmpty) {
        return message ?? 'Please enter a valid URL';
      }
      return null;
    } catch (e) {
      return message ?? 'Please enter a valid URL';
    }
  }

  /// **Starts With Validation** - Value must start with specific text
  ///
  /// ```dart
  /// Validator.startsWith('hello world', 'hello') // null (valid)
  /// Validator.startsWith('world hello', 'hello') // 'Must start with "hello"'
  /// ```
  static String? startsWith(String value, String prefix, {String? message}) {
    if (!value.startsWith(prefix)) {
      return message ?? 'Must start with "$prefix"';
    }
    return null;
  }

  /// **Ends With Validation** - Value must end with specific text
  ///
  /// ```dart
  /// Validator.endsWith('hello world', 'world') // null (valid)
  /// Validator.endsWith('hello world', 'hello') // 'Must end with "hello"'
  /// ```
  static String? endsWith(String value, String suffix, {String? message}) {
    if (!value.endsWith(suffix)) {
      return message ?? 'Must end with "$suffix"';
    }
    return null;
  }

  /// **Contains Validation** - Value must contain specific text
  ///
  /// ```dart
  /// Validator.contains('hello world', 'world') // null (valid)
  /// Validator.contains('hello there', 'world') // 'Must contain "world"'
  /// ```
  static String? contains(String value, String substring, {String? message}) {
    if (!value.contains(substring)) {
      return message ?? 'Must contain "$substring"';
    }
    return null;
  }

  /// **Not Contains Validation** - Value must not contain specific text
  ///
  /// ```dart
  /// Validator.notContains('hello there', 'world') // null (valid)
  /// Validator.notContains('hello world', 'world') // 'Must not contain "world"'
  /// ```
  static String? notContains(
    String value,
    String substring, {
    String? message,
  }) {
    if (value.contains(substring)) {
      return message ?? 'Must not contain "$substring"';
    }
    return null;
  }

  /// **In List Validation** - Value must be one of allowed options
  ///
  /// ```dart
  /// Validator.inList('red', ['red', 'green', 'blue']) // null (valid)
  /// Validator.inList('yellow', ['red', 'green', 'blue']) // 'Must be one of: red, green, blue'
  /// ```
  static String? inList(
    String value,
    List<String> allowedValues, {
    String? message,
  }) {
    if (!allowedValues.contains(value)) {
      return message ?? 'Must be one of: ${allowedValues.join(', ')}';
    }
    return null;
  }

  /// **Not In List Validation** - Value must not be one of forbidden options
  ///
  /// ```dart
  /// Validator.notInList('yellow', ['red', 'green']) // null (valid)
  /// Validator.notInList('red', ['red', 'green']) // 'Cannot be one of: red, green'
  /// ```
  static String? notInList(
    String value,
    List<String> forbiddenValues, {
    String? message,
  }) {
    if (forbiddenValues.contains(value)) {
      return message ?? 'Cannot be one of: ${forbiddenValues.join(', ')}';
    }
    return null;
  }

  /// **� Alpha Dash Validation** - Letters, numbers, dashes, underscores only
  ///
  /// Validates that value contains only letters, numbers, dashes, and underscores:
  /// ```dart
  /// Validator.alphaDash('hello_world-123') // null (valid)
  /// Validator.alphaDash('hello@world')     // 'Only letters, numbers, dashes, and underscores are allowed'
  /// ```
  static String? alphaDash(String value, {String? message}) {
    final alphaDashRegex = RegExp(r'^[a-zA-Z0-9_-]+$');
    if (!alphaDashRegex.hasMatch(value)) {
      return message ??
          'Only letters, numbers, dashes, and underscores are allowed';
    }
    return null;
  }

  /// **Lowercase Validation** - Must be all lowercase
  ///
  /// Validates that value contains only lowercase characters:
  /// ```dart
  /// Validator.lowercase('hello world') // null (valid)
  /// Validator.lowercase('Hello World') // 'Must be lowercase'
  /// ```
  static String? lowercase(String value, {String? message}) {
    if (value != value.toLowerCase()) {
      return message ?? 'Must be lowercase';
    }
    return null;
  }

  /// **Uppercase Validation** - Must be all uppercase
  ///
  /// Validates that value contains only uppercase characters:
  /// ```dart
  /// Validator.uppercase('HELLO WORLD') // null (valid)
  /// Validator.uppercase('Hello World') // 'Must be uppercase'
  /// ```
  static String? uppercase(String value, {String? message}) {
    if (value != value.toUpperCase()) {
      return message ?? 'Must be uppercase';
    }
    return null;
  }

  /// **Contains Uppercase Validation** - Must contain uppercase letters
  ///
  /// Validates minimum and optionally maximum uppercase letter count:
  /// ```dart
  /// Validator.containsUppercase('Hello', min: 1)     // null (valid)
  /// Validator.containsUppercase('hello', min: 1)     // 'Must contain at least 1 uppercase letter'
  /// Validator.containsUppercase('HELLO', max: 2)     // 'Must contain at most 2 uppercase letters'
  /// ```
  static String? containsUppercase(
    String value, {
    int min = 1,
    int? max,
    String? message,
  }) {
    final uppercaseCount = value.replaceAll(RegExp(r'[^A-Z]'), '').length;

    if (uppercaseCount < min) {
      if (message != null) return message;
      return min == 1
          ? 'Must contain at least 1 uppercase letter'
          : 'Must contain at least $min uppercase letters';
    }

    if (max != null && uppercaseCount > max) {
      if (message != null) return message;
      return max == 1
          ? 'Must contain at most 1 uppercase letter'
          : 'Must contain at most $max uppercase letters';
    }

    return null;
  }

  /// **Contains Lowercase Validation** - Must contain lowercase letters
  ///
  /// Validates minimum and optionally maximum lowercase letter count:
  /// ```dart
  /// Validator.containsLowercase('Hello', min: 1)     // null (valid)
  /// Validator.containsLowercase('HELLO', min: 1)     // 'Must contain at least 1 lowercase letter'
  /// Validator.containsLowercase('hello', max: 2)     // 'Must contain at most 2 lowercase letters'
  /// ```
  static String? containsLowercase(
    String value, {
    int min = 1,
    int? max,
    String? message,
  }) {
    final lowercaseCount = value.replaceAll(RegExp(r'[^a-z]'), '').length;

    if (lowercaseCount < min) {
      if (message != null) return message;
      return min == 1
          ? 'Must contain at least 1 lowercase letter'
          : 'Must contain at least $min lowercase letters';
    }

    if (max != null && lowercaseCount > max) {
      if (message != null) return message;
      return max == 1
          ? 'Must contain at most 1 lowercase letter'
          : 'Must contain at most $max lowercase letters';
    }

    return null;
  }

  /// **Contains Digit Validation** - Must contain digits
  ///
  /// Validates minimum and optionally maximum digit count:
  /// ```dart
  /// Validator.containsDigit('hello123', min: 2)      // null (valid)
  /// Validator.containsDigit('hello', min: 1)         // 'Must contain at least 1 digit'
  /// Validator.containsDigit('hello12345', max: 3)    // 'Must contain at most 3 digits'
  /// ```
  static String? containsDigit(
    String value, {
    int min = 1,
    int? max,
    String? message,
  }) {
    final digitCount = value.replaceAll(RegExp(r'[^0-9]'), '').length;

    if (digitCount < min) {
      if (message != null) return message;
      return min == 1
          ? 'Must contain at least 1 digit'
          : 'Must contain at least $min digits';
    }

    if (max != null && digitCount > max) {
      if (message != null) return message;
      return max == 1
          ? 'Must contain at most 1 digit'
          : 'Must contain at most $max digits';
    }

    return null;
  }

  /// **Contains Special Character Validation** - Must contain special characters
  ///
  /// Validates minimum and optionally maximum special character count:
  /// ```dart
  /// Validator.containsSpecial('hello!@', min: 1)     // null (valid)
  /// Validator.containsSpecial('hello', min: 1)       // 'Must contain at least 1 special character'
  /// Validator.containsSpecial('hello!@#\$', max: 2)   // 'Must contain at most 2 special characters'
  /// ```
  static String? containsSpecial(
    String value, {
    int min = 1,
    int? max,
    String? message,
  }) {
    final specialCount = value.replaceAll(RegExp(r'[a-zA-Z0-9]'), '').length;

    if (specialCount < min) {
      if (message != null) return message;
      return min == 1
          ? 'Must contain at least 1 special character'
          : 'Must contain at least $min special characters';
    }

    if (max != null && specialCount > max) {
      if (message != null) return message;
      return max == 1
          ? 'Must contain at most 1 special character'
          : 'Must contain at most $max special characters';
    }

    return null;
  }

  /// **Length Between Validation** - Length must be within range
  ///
  /// Validates that value length is between min and max (inclusive):
  /// ```dart
  /// Validator.lengthBetween('hello', 3, 8)   // null (valid)
  /// Validator.lengthBetween('hi', 3, 8)      // 'Must be between 3 and 8 characters'
  /// Validator.lengthBetween('very long', 3, 8) // 'Must be between 3 and 8 characters'
  /// ```
  static String? lengthBetween(
    String value,
    int min,
    int max, {
    String? message,
  }) {
    if (value.length < min || value.length > max) {
      return message ?? 'Must be between $min and $max characters';
    }
    return null;
  }

  /// **Equals Validation** - Must equal specific value
  ///
  /// Validates that value equals the expected value:
  /// ```dart
  /// Validator.equals('password', 'password')     // null (valid)
  /// Validator.equals('password', 'different')    // 'Values do not match'
  /// ```
  static String? equals(String value, String expected, {String? message}) {
    if (value != expected) {
      return message ?? 'Values do not match';
    }
    return null;
  }

  /// **Not Equals Validation** - Must not equal specific value
  ///
  /// Validates that value does not equal the forbidden value:
  /// ```dart
  /// Validator.notEquals('password', 'admin')     // null (valid)
  /// Validator.notEquals('admin', 'admin')        // 'Value cannot be "admin"'
  /// ```
  static String? notEquals(String value, String forbidden, {String? message}) {
    if (value == forbidden) {
      return message ?? 'Value cannot be "$forbidden"';
    }
    return null;
  }

  /// **�🔗 Rules Combiner** - Combine multiple validators
  ///
  /// Executes validators in order and returns first error found:
  /// ```dart
  /// validator: Validator.rules([
  ///   (value) => Validator.required(value),
  ///   (value) => Validator.min(value, 8),
  ///   (value) => Validator.email(value),
  /// ]),
  /// ```
  static String? Function(String) rules(
    List<String? Function(String)> validators,
  ) {
    return (String value) {
      for (final validator in validators) {
        final result = validator(value);
        if (result != null) return result;
      }
      return null;
    };
  }
}
