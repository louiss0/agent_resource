# Clix

<div align="center">
  <img src="https://raw.githubusercontent.com/altwaireb/clix/main/assets/logo.svg" alt="Clix Logo" height="80">
  
  <p><strong>Build beautiful, interactive CLI apps in Dart</strong></p>
  
  [![Pub Version](https://img.shields.io/pub/v/clix?style=flat-square&color=blue)](https://pub.dev/packages/clix)
  [![Dart CI](https://github.com/altwaireb/clix/workflows/Dart%20CI/badge.svg)](https://github.com/altwaireb/clix/actions)
  [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](https://opensource.org/licenses/MIT)
  [![Pub Points](https://img.shields.io/pub/points/clix?style=flat-square&color=brightgreen)](https://pub.dev/packages/clix/score)
  
</div>

---

## Why Clix? 

A modern, batteries-included CLI toolkit for Dart,
focused on interactive workflows and developer experience.

✨ **All-in-One** – Prompts, logging, progress, validation, styling, and more in a single package  
🚀 **Production Ready** – 537+ automated tests ensure rock-solid reliability  
🎯 **Type Safe** – Full null safety with comprehensive type support  
🧪 **Test Friendly** – Built-in mock I/O for effortless testing  
⚡ **Modern API** – Clean, fluent `.interact()` syntax throughout  

## When Clix Is a Good Fit

Clix is ideal for interactive CLI tools, setup wizards, and developer utilities.

For low-level argument parsing or simple one-off scripts, libraries like `args` may be more appropriate. Clix is designed to complement them, not replace them.

## Quick Start

```bash
dart pub add clix
```

Or add to your `pubspec.yaml`:

```yaml
dependencies:
  clix: ^1.2.0
```

```dart
import 'package:clix/clix.dart';

void main() async {
  // Get user input with validation
  final name = await Input('Your name').interact();
  final confirmed = await Confirm('Continue?').interact();
  
  // Beautiful logging
  final logger = CliLogger.defaults();
  logger.success('Welcome $name! 🎉');
  
  // Show progress
  final spinner = Spinner('Setting things up...');
  spinner.start();
  await Future.delayed(Duration(seconds: 2));
  spinner.complete('All done!');
}
```

![Basic Demo](https://raw.githubusercontent.com/altwaireb/clix/main/assets/gifs/prompts_demo.gif)

---

## Interactive Prompts

### Quick Examples

```dart
// Text input with validation
final email = await Input(
  'Email',
  validator: (value) => value.contains('@') ? null : 'Invalid email',
).interact();

// Number input with range
final age = await Number('Age', min: 0, max: 120).interact();

// Choose from options
final framework = await Select('Framework', [
  'Flutter', 'React', 'Vue', 'Angular'
]).interact();

// Multiple selection  
final features = await MultiSelect('Features', [
  'Auth', 'Database', 'API', 'Testing'
]).interact();

// Smart search through data
final country = await Search('Country', options: [
  'United States', 'United Kingdom', 'Germany', 'France'
]).interact();
```

### Unique Features

**Number & Decimal Prompts** – Built-in range validation, the only CLI package offering these:

```dart
final price = await Decimal('Price', min: 0.0, max: 999.99).interact();
final quantity = await Number('Quantity', min: 1, max: 100).interact();
```

**Smart Search** – Interactive search with auto-completion:

![Search Demo](https://raw.githubusercontent.com/altwaireb/clix/main/assets/gifs/search_demo.gif)

```dart
final result = await Search(
  'Find user',
  options: (query) async => await searchAPI(query), // Dynamic search
  minQueryLength: 2,
).interact();
```

---

## Validation System

**Two approaches for maximum flexibility:**

### Modern: ValidationRules (Recommended)

```dart
// Simple & clean - ValidationRules
final username = await Input(
  'Username',
  validator: ValidationRules()
    .required()
    .min(3)
    .alphaNumeric(),
).interact();

// Advanced with custom messages - Validator.rules
final password = await Input(
  'Password',
  validator: Validator.rules([
    (value) => Validator.required(value, 'Password is required'),
    (value) => Validator.min(value, 8, 'At least 8 characters'),
    (value) => Validator.pattern(value, RegExp(r'[A-Z]'), 'Must contain uppercase'),
    (value) => value.contains('password') ? 'Cannot contain "password"' : null,
  ]),
).interact();
```

**Two modern approaches:** ValidationRules fluent API and Validator.rules array-based chains.

**Available Rules:** `required()`, `min()`, `max()`, `email()`, `url()`, `numeric()`, `alpha()`, `alphaNumeric()`, `pattern()`, `custom()`, and more.

### Custom: Validator Functions

```dart
final username = await Input(
  'Username',
  validator: (value) {
    if (value.length < 3) return 'Too short';
    if (value.length > 20) return 'Too long';
    if (RegExp(r'[^a-zA-Z0-9]').hasMatch(value)) return 'Only letters and numbers';
    if (['admin', 'root'].contains(value.toLowerCase())) return 'Reserved name';
    return null; // Valid
  },
).interact();
```

---

## Logging & Output

### Simple & Effective

```dart
final logger = CliLogger();

// Basic levels
logger.info('App started');
logger.success('Task completed');
logger.warn('Warning message');  
logger.error('Something failed');

// With helpful hints
logger.successWithHint('Build completed', hint: 'Run: dart test');
logger.errorWithHint('Connection failed', hint: 'Check network');
```

![Logger Demo](https://raw.githubusercontent.com/altwaireb/clix/main/assets/gifs/logger_demo.gif)

### Colors & Styling

```dart
// Colors
logger.red('Error text');
logger.green('Success text');
logger.blue('Info text');

// Custom styling
final style = CliStyle()
  .withColor(CliColor.cyan)
  .makeBold()
  .makeUnderline();

print(style.format('Styled text'));
```

### Custom Themes

```dart
// Create custom theme with hex colors
final customTheme = CliTheme(
  primary: CliStyle().withColor(CliColor.hex('#FF6B6B')), // Coral Red
  secondary: CliStyle().withColor(CliColor.hex('#4ECDC4')), // Teal
  success: CliStyle().withColor(CliColor.hex('#45B7D1')), // Sky Blue
  warn: CliStyle().withColor(CliColor.hex('#FFA726')), // Orange
  error: CliStyle().withColor(CliColor.hex('#E74C3C')), // Red
);

final customLogger = CliLogger(theme: customTheme);
customLogger.primary('Custom branded colors');
customLogger.success('Success with custom theme');
```

### Additional Logger Features

```dart
// Background colors
logger.onSuccess('Success background');
logger.onError('Error background');
logger.onWarning('Warning background');

// Icons & formatting
logger.successIcon('Done!');
logger.errorIcon('Failed');
logger.tree('Project structure');
logger.point('Bullet point');
logger.newLine(); // Spacing
```

---

## Progress & Feedback

### Spinners

```dart
final spinner = Spinner('Loading...');

// Update message
spinner.update('Processing...');
await Future.delayed(Duration(seconds: 2));

// Finish
spinner.complete('Success!');
// or spinner.fail('Failed');
```

![Spinner Demo](https://raw.githubusercontent.com/altwaireb/clix/main/assets/gifs/spinner_demo.gif)

**Spinner Types:** `dots`, `line`, `pipe`, `clock`, `arrow`, `triangle`, `square`, `circle`

### Progress Bars & Multi-Spinners

```dart
// Progress bar
final progress = logger.progress(total: 100);
for (int i = 0; i <= 100; i += 10) {
  progress.update(i, 'Step $i/100');
  await Future.delayed(Duration(milliseconds: 100));
}
progress.complete();

// Multiple concurrent tasks
final multiSpinner = logger.multiSpinner();

// Add tasks
multiSpinner.add('packages', 'Downloading packages');
multiSpinner.add('env', 'Setting up environment');

// Start tasks
multiSpinner.startTask('packages');
multiSpinner.startTask('env');

// Complete first task
await Future.delayed(Duration(milliseconds: 800));
multiSpinner.complete('packages', 'Packages downloaded');

// Update second task message
await Future.delayed(Duration(milliseconds: 600));
multiSpinner.updateMessage('env', 'Configuring environment');

// Complete second task
await Future.delayed(Duration(milliseconds: 400));
multiSpinner.complete('env', 'Environment ready');

// Stop all tasks
await Future.delayed(Duration(milliseconds: 200));
multiSpinner.stop();
```

---

## Data Display

### Tables

```dart
logger.table(
  columns: [
    TableColumn('Name'),
    TableColumn('Age', alignment: TableAlignment.center),
    TableColumn('City', alignment: TableAlignment.right),
  ],
  rows: [
    ['Alice', '25', 'New York'],
    ['Bob', '30', 'London'], 
    ['Charlie', '35', 'Tokyo'],
  ],
);
```

### Configuration Management

```dart
// JSON configuration
final config = CliConfig.fromJson('config.json');
await config.load();

final apiUrl = config.getValue<String>('api.url');
final timeout = config.getValue<int>('api.timeout', defaultValue: 30);

// Validation
final errors = config.validate();
if (errors.isNotEmpty) {
  logger.error('Config errors: ${errors.join(', ')}');
}
```

---

## Testing Made Easy

Clix includes built-in mock I/O for seamless testing:

```dart
import 'package:test/test.dart';
import 'package:clix/clix.dart';

test('user interaction', () async {
  final mockIO = MockIO();
  final theme = CliTheme.defaultTheme();
  
  // Setup responses
  mockIO.setInput(['John', 'y']);
  
  // Test prompts
  final name = await Input('Name').interact(mockIO, theme);
  final confirmed = await Confirm('Continue?').interact(mockIO, theme);
  
  expect(name, equals('John'));
  expect(confirmed, isTrue);
});
```

---

## Complete Example

```dart
import 'package:clix/clix.dart';

Future<void> main() async {
  final logger = CliLogger();
  
  logger.primary('Project Setup Wizard');
  logger.newLine();
  
  try {
    // Gather project info
    final name = await Input(
      'Project name',
      validator: ValidationRules()
        .required('Project name is required')
        .pattern(RegExp(r'^[a-z][a-z0-9_]*$'), 'Invalid format'),
    ).interact();
    
    final framework = await Select('Framework', [
      'Flutter', 'Dart Console', 'Web App'
    ]).interact();
    
    final features = await MultiSelect('Features', [
      'Authentication', 'Database', 'API', 'Testing'
    ]).interact();
    
    // Confirm setup
    final proceed = await Confirm('Create project?').interact();
    
    if (proceed) {
      // Show progress
      final spinner = Spinner('Creating project...');
      
      await Future.delayed(Duration(seconds: 2));
      spinner.update('Installing dependencies...');
      await Future.delayed(Duration(seconds: 1));
      
      spinner.complete('Project created! 🎉');
      
      // Results
      logger.successWithHint(
        'Project: $name',
        hint: 'cd $name',
      );
      logger.infoWithHint(
        'Framework: $framework',
        hint: 'dart run',
      );
      logger.primary('Features: ${features.join(', ')}');
    }
    
  } catch (e) {
    logger.error('Setup failed: $e');
  }
}
```

---

## Key Features

| Feature | Description |
|---------|-------------|
| **🎯 Interactive Prompts** | Input, Select, MultiSelect, Confirm, Number, Decimal, Search, Password |
| **✅ Smart Validation** | ValidationRules fluent API + traditional validator functions |
| **🎨 Rich Styling** | Colors, themes, backgrounds, icons, and custom formatting |
| **📝 Advanced Logging** | Multi-level logging with hints, icons, and timestamps |
| **🎬 Progress Indicators** | Spinners, progress bars, multi-spinners with customization |
| **📊 Data Display** | Tables, structured output, and configuration management |
| **🧪 Testing Support** | Built-in MockIO for comprehensive testing |
| **🛡️ Production Ready** | 537+ automated tests, null safety, comprehensive error handling |

---

## Examples & Resources

```bash
# Try the examples
dart run example/basic_prompts.dart
dart run example/config_example.dart
dart run example/validation_demo.dart
dart run example/complete_demo.dart
```

- 📖 [Full API Documentation](https://pub.dev/documentation/clix)
- 🐛 [Report Issues](https://github.com/altwaireb/clix/issues)
- 📦 [Pub Package](https://pub.dev/packages/clix)

---

<div align="center">
  
**Built with ❤️ for the Dart community**

[⭐ Star on GitHub](https://github.com/altwaireb/clix) • [📖 Documentation](https://pub.dev/documentation/clix) • [💬 Discussions](https://github.com/altwaireb/clix/discussions)

</div>

