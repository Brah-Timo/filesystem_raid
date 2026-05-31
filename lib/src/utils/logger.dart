/// Structured levelled logger for the filesystem_raid package.
library filesystem_raid.utils.logger;

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import '../../models/raid_config.dart';

// ---------------------------------------------------------------------------
// RaidLogger
// ---------------------------------------------------------------------------

/// Thin wrapper around the `logging` package that:
/// - Uses a shared [Logger] instance named `filesystem_raid`.
/// - Accepts a [RaidLogLevel] to filter verbosity.
/// - Adds a ANSI-coloured console handler on [RaidLogger.attachConsole].
class RaidLogger {
  // ── Constructors ──────────────────────────────────────────────────────────

  /// Creates a [RaidLogger] for the given [level].
  RaidLogger(this.level) {
    _logger = Logger('filesystem_raid');
    _mapLevel();
  }

  /// Creates a [RaidLogger] with [RaidLogLevel.info].
  factory RaidLogger.info() => RaidLogger(RaidLogLevel.info);

  /// Creates a [RaidLogger] with [RaidLogLevel.debug].
  factory RaidLogger.debug() => RaidLogger(RaidLogLevel.debug);

  /// Creates a silent [RaidLogger] (no output).
  factory RaidLogger.silent() => RaidLogger(RaidLogLevel.none);

  // ── Fields ────────────────────────────────────────────────────────────────

  /// Verbosity level.
  final RaidLogLevel level;

  late final Logger _logger;
  late final Level _logLevel;

  // ── Static helpers ────────────────────────────────────────────────────────

  /// Registers a [LogRecord] listener that prints to stdout with ANSI colours.
  ///
  /// Call this once, e.g. in `main()`, if you want visible console output.
  ///
  /// ```dart
  /// RaidLogger.attachConsole();
  /// ```
  static void attachConsole() {
    Logger.root.onRecord.listen(_printRecord);
  }

  static void _printRecord(LogRecord record) {
    final colour = _ansiColour(record.level);
    final reset = '\x1B[0m';
    final time = record.time.toIso8601String().substring(11, 23);
    final prefix = '$colour[${record.level.name.padRight(7)}]$reset $time '
        '${record.loggerName}: ';

    // ignore: avoid_print — intentional console sink; callers opt-in via attachConsole()
    print('$prefix${record.message}');
    if (record.error != null) {
      // ignore: avoid_print — intentional console sink; callers opt-in via attachConsole()
      print('  Error  : ${record.error}');
    }
    if (record.stackTrace != null) {
      // ignore: avoid_print — intentional console sink; callers opt-in via attachConsole()
      print('  Stack  : ${record.stackTrace}');
    }
  }

  static String _ansiColour(Level level) {
    if (level >= Level.SEVERE) return '\x1B[31m';  // red
    if (level >= Level.WARNING) return '\x1B[33m'; // yellow
    if (level >= Level.INFO) return '\x1B[32m';    // green
    return '\x1B[36m';                              // cyan (debug)
  }

  // ── Instance methods ──────────────────────────────────────────────────────

  /// Logs at [Level.FINE] (debug).
  void debug(String message, [Object? error, StackTrace? stackTrace]) {
    if (level == RaidLogLevel.debug) {
      _logger.fine(message, error, stackTrace);
    }
  }

  /// Logs at [Level.INFO].
  void info(String message, [Object? error, StackTrace? stackTrace]) {
    if (_shouldLog(RaidLogLevel.info)) {
      _logger.info(message, error, stackTrace);
    }
  }

  /// Logs at [Level.WARNING].
  void warning(String message, [Object? error, StackTrace? stackTrace]) {
    if (_shouldLog(RaidLogLevel.warning)) {
      _logger.warning(message, error, stackTrace);
    }
  }

  /// Logs at [Level.SEVERE] (error).
  void error(String message, [Object? error, StackTrace? stackTrace]) {
    if (_shouldLog(RaidLogLevel.error)) {
      _logger.severe(message, error, stackTrace);
    }
  }

  void _mapLevel() {
    switch (level) {
      case RaidLogLevel.none:
        _logLevel = Level.OFF;
      case RaidLogLevel.error:
        _logLevel = Level.SEVERE;
      case RaidLogLevel.warning:
        _logLevel = Level.WARNING;
      case RaidLogLevel.info:
        _logLevel = Level.INFO;
      case RaidLogLevel.debug:
        _logLevel = Level.FINE;
    }
    Logger.root.level = _logLevel;
  }

  bool _shouldLog(RaidLogLevel msgLevel) {
    if (level == RaidLogLevel.none) return false;
    return msgLevel.index <= level.index;
  }
}

// ---------------------------------------------------------------------------
// OperationLogger — simple scoped timing helper
// ---------------------------------------------------------------------------

/// Measures and logs the duration of a named async operation.
///
/// ```dart
/// final op = OperationLogger(logger, 'write bigfile.zip');
/// // ... do work ...
/// op.done(); // logs: "write bigfile.zip completed in 1.23 s"
/// ```
@immutable
class OperationLogger {
  /// Creates an [OperationLogger] and records the start timestamp.
  OperationLogger(this._log, this.operationName)
      : _start = DateTime.now() {
    _log.debug('→ $operationName started');
  }

  final RaidLogger _log;

  /// Human-readable name of the operation being timed.
  final String operationName;

  final DateTime _start;

  /// Records a successful completion and logs elapsed time.
  void done({String? extra}) {
    final ms = DateTime.now().difference(_start).inMilliseconds;
    _log.info(
      '✓ $operationName completed in ${(ms / 1000).toStringAsFixed(3)} s'
      '${extra != null ? " — $extra" : ""}',
    );
  }

  /// Records a failure and logs the error.
  void failed(Object error) {
    final ms = DateTime.now().difference(_start).inMilliseconds;
    _log.error(
      '✗ $operationName failed after ${(ms / 1000).toStringAsFixed(3)} s',
      error,
    );
  }
}
