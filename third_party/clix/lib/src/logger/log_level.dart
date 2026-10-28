enum LogLevel {
  plain(0), // Default plain text in white
  debug(1),
  info(2),
  warning(3),
  error(4),
  success(5);

  final int priority;
  const LogLevel(this.priority);

  bool shouldLog(LogLevel minimumLevel) => priority >= minimumLevel.priority;
}
