/// A drift database implementation built on `package:sqlite3/`.
///
/// The [NativeDatabase] class uses `dart:ffi` to access `sqlite3` APIs.
///
/// When using a [NativeDatabase], you need to ensure that `sqlite3` is
/// available when running your app. For mobile Flutter apps, you can simply
/// depend on the `sqlite3_flutter_libs` package to ship the latest sqlite3
/// version with your app.
/// For more information other platforms, see [other engines](https://drift.simonbinder.eu/docs/other-engines/vm/).
library drift.ffi;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:drift/drift.dart';
import 'package:drift/isolate.dart';
import 'package:meta/meta.dart';
import 'package:sqlite3/common.dart';
import 'package:sqlite3/sqlite3.dart';

import 'backends.dart';
import 'src/sqlite3/database.dart';
import 'src/sqlite3/database_tracker.dart';

export 'package:sqlite3/sqlite3.dart' show SqliteException;

/// Signature of a function that can perform setup work on a [database] before
/// drift is fully ready.
///
/// This could be used to, for instance, set encryption keys for SQLCipher
/// implementations.
typedef DatabaseSetup = void Function(Database database);

/// Signature of a function that can perform setup work on the isolate before
/// opening the database.
///
/// This could be used to override libraries.
/// For example:
/// ```
/// open.overrideFor(OperatingSystem.android, openCipherOnAndroid)
/// ```
typedef IsolateSetup = FutureOr<void> Function();

/// A drift database implementation based on `dart:ffi`, running directly in a
/// Dart VM or an AOT compiled Dart/Flutter application.
class NativeDatabase extends DelegatedDatabase {
  // when changing this, also update the documentation in `drift_vm_database_factory`.
  static const _cacheStatementsByDefault = false;

  NativeDatabase._(super.delegate, bool logStatements)
      : super(isSequential: false, logStatements: logStatements);

  /// Creates a database that will store its result in the [file], creating it
  /// if it doesn't exist.
  ///
  /// {@template drift_vm_database_factory}
  /// If [logStatements] is true (defaults to `false`), generated sql statements
  /// will be printed before executing. This can be useful for debugging.
  ///
  /// The [cachePreparedStatements] flag (defaults to `false`) controls whether
  /// drift will cache prepared statement objects, which improves performance as
  /// sqlite3 doesn't have to parse statements that are frequently used multiple
  /// times. This will be the default in the next minor drift version.
  ///
  /// The optional [setup] function can be used to perform a setup just after
  /// the database is opened, before drift is fully ready. This can be used to
  /// add custom user-defined sql functions or to provide encryption keys in
  /// SQLCipher implementations.
  /// {@endtemplate}
  factory NativeDatabase(
    File file, {
    bool logStatements = false,
    DatabaseSetup? setup,
    bool cachePreparedStatements = _cacheStatementsByDefault,
  }) {
    return NativeDatabase._(
        _NativeDelegate(
          file,
          setup,
          cachePreparedStatements,
        ),
        logStatements);
  }

  /// Creates a database storing its result in [file].
  ///
  /// This method will create the same database as the default constructor of
  /// the [NativeDatabase] class. It also behaves the same otherwise: The [file]
  /// is created if it doesn't exist, [logStatements] can be used to print
  /// statements and [setup] can be used to perform a one-time setup work when
  /// the database is created.
  ///
  /// The big distinction of this method is that the database is implicitly
  /// created on a background isolate, freeing up your main thread accessing the
  /// database from I/O work needed to run statements.
  /// When the database returned by this method is closed, the background
  /// isolate will shut down as well.
  ///
  /// __Important limitations__: If the [setup] parameter is given, it must be
  /// a static or top-level function. The reason is that it is executed on
  /// another isolate.
  static QueryExecutor createInBackground(
    File file, {
    bool logStatements = false,
    bool cachePreparedStatements = _cacheStatementsByDefault,
    DatabaseSetup? setup,
    IsolateSetup? isolateSetup,
  }) {
    return createBackgroundConnection(
      file,
      logStatements: logStatements,
      setup: setup,
      isolateSetup: isolateSetup,
      cachePreparedStatements: cachePreparedStatements,
    );
  }

  /// Like [createInBackground], except that it returns the whole
  /// [DatabaseConnection] instead of just the executor.
  ///
  /// This creates a database writing data to the given [file]. The database
  /// runs in a background isolate and is stopped when closed.
  static DatabaseConnection createBackgroundConnection(
    File file, {
    bool logStatements = false,
    DatabaseSetup? setup,
    IsolateSetup? isolateSetup,
    bool cachePreparedStatements = _cacheStatementsByDefault,
  }) {
    return DatabaseConnection.delayed(Future.sync(() async {
      final receiveIsolate = ReceivePort();
      await Isolate.spawn(
        _NativeIsolateStartup.start,
        _NativeIsolateStartup(
          file.absolute.path,
          logStatements,
          cachePreparedStatements,
          setup,
          isolateSetup,
          receiveIsolate.sendPort,
        ),
        debugName: 'Drift isolate worker for ${file.path}',
      );

      final driftIsolate = await receiveIsolate.first as DriftIsolate;
      receiveIsolate.close();

      return driftIsolate.connect(singleClientMode: true);
    }));
  }

  /// Creates an in-memory database won't persist its changes on disk.
  ///
  /// {@macro drift_vm_database_factory}
  factory NativeDatabase.memory({
    bool logStatements = false,
    DatabaseSetup? setup,
    bool cachePreparedStatements = _cacheStatementsByDefault,
  }) {
    return NativeDatabase._(
      _NativeDelegate(null, setup, cachePreparedStatements),
      logStatements,
    );
  }

  /// Creates a drift executor for an opened [database] from the `sqlite3`
  /// package.
  ///
  /// When the [closeUnderlyingOnClose] argument is set (which is the default),
  /// calling [QueryExecutor.close] on the returned [NativeDatabase] will also
  /// [CommonDatabase.dispose] the [database] passed to this constructor.
  ///
  /// Using [NativeDatabase.opened] may be useful when you want to use the same
  /// underlying [Database] in multiple drift connections. Drift uses this
  /// internally when running [integration tests for migrations](https://drift.simonbinder.eu/docs/advanced-features/migrations/#verifying-migrations).
  ///
  /// {@macro drift_vm_database_factory}
  factory NativeDatabase.opened(
    Database database, {
    bool logStatements = false,
    DatabaseSetup? setup,
    bool closeUnderlyingOnClose = true,
    bool cachePreparedStatements = _cacheStatementsByDefault,
  }) {
    return NativeDatabase._(
        _NativeDelegate.opened(
          database,
          setup,
          closeUnderlyingOnClose,
          cachePreparedStatements,
        ),
        logStatements);
  }

  /// Disposes resources allocated by all `VmDatabase` instances of this
  /// process.
  ///
  /// This method will call `sqlite3_close_v2` for every `VmDatabase` that this
  /// process has opened without closing later.
  ///
  /// __Warning__: This functionality appears to cause crashes on iOS, and it
  /// does nothing on Android. It's mainly intended for Desktop operating
  /// systems, so try to avoid calling it where it's not necessary.
  /// For safety measures, avoid calling [closeExistingInstances] in release
  /// builds.
  ///
  /// Ideally, all databases should be closed properly in Dart. In that case,
  /// it's not necessary to call [closeExistingInstances]. However, features
  /// like hot (stateless) restart can make it impossible to reliably close
  /// every database. In that case, we leak native sqlite3 database connections
  /// that aren't referenced by any Dart object. Drift can track those
  /// connections across Dart VM restarts by storing them in an in-memory sqlite
  /// database.
  /// Calling this method can cleanup resources and database locks after a
  /// restart.
  ///
  /// Note that calling [closeExistingInstances] when you're still actively
  /// using a [NativeDatabase] can lead to crashes, since the database would
  /// then attempt to use an invalid connection.
  /// This, this method should only be called when you're certain that there
  /// aren't any active [NativeDatabase]s, not even on another isolate.
  ///
  /// A suitable place to call [closeExistingInstances] is at an early stage
  /// of your `main` method, before you're using drift.
  ///
  /// ```dart
  /// void main() {
  ///   // Guard against zombie database connections caused by hot restarts
  ///   assert(() {
  ///     VmDatabase.closeExistingInstances();
  ///     return true;
  ///   }());
  ///
  ///   runApp(MyApp());
  /// }
  /// ```
  ///
  /// For more information, see [issue 835](https://github.com/simolus3/drift/issues/835).
  @experimental
  static void closeExistingInstances() {
    tracker.closeExisting();
  }
}

class _NativeDelegate extends Sqlite3Delegate<Database> {
  final File? file;

  _NativeDelegate(this.file, DatabaseSetup? setup, bool cachePreparedStatements)
      : super(
          setup,
          cachePreparedStatements: cachePreparedStatements,
        );

  _NativeDelegate.opened(
    Database super.db,
    super.setup,
    super.closeUnderlyingWhenClosed,
    bool cachePreparedStatements,
  )   : file = null,
        super.opened(
          cachePreparedStatements: cachePreparedStatements,
        );

  @override
  Database openDatabase() {
    final file = this.file;
    Database db;

    if (file != null) {
      // Create the parent directory if it doesn't exist. sqlite will emit
      // confusing misuse warnings otherwise
      final dir = file.parent;
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }

      db = sqlite3.open(file.path);
      try {
        tracker.markOpened(file.path, db);
      } on SqliteException {
        // ignore
      }
    } else {
      db = sqlite3.openInMemory();
    }

    return db;
  }

  @override
  Future<void> runBatched(BatchedStatements statements) {
    return Future.sync(() => runBatchSync(statements));
  }

  @override
  Future<void> runCustom(String statement, List<Object?> args) {
    return Future.sync(() => runWithArgsSync(statement, args));
  }

  @override
  Future<int> runInsert(String statement, List<Object?> args) {
    return Future.sync(() {
      runWithArgsSync(statement, args);
      return database.lastInsertRowId;
    });
  }

  @override
  Future<int> runUpdate(String statement, List<Object?> args) {
    return Future.sync(() {
      runWithArgsSync(statement, args);
      return database.updatedRows;
    });
  }

  @override
  Future<void> close() async {
    await super.close();

    if (closeUnderlyingWhenClosed) {
      try {
        tracker.markClosed(database);
      } on SqliteException {
        // ignore
      }

      database.dispose();
    }
  }
}

class _NativeIsolateStartup {
  final String path;
  final bool enableLogs;
  final bool cachePreparedStatements;
  final DatabaseSetup? setup;
  final IsolateSetup? isolateSetup;
  final SendPort sendServer;

  _NativeIsolateStartup(
    this.path,
    this.enableLogs,
    this.cachePreparedStatements,
    this.setup,
    this.isolateSetup,
    this.sendServer,
  );

  static Future<void> start(_NativeIsolateStartup startup) async {
    await startup.isolateSetup?.call();
    final isolate = DriftIsolate.inCurrent(() {
      return DatabaseConnection(NativeDatabase(
        File(startup.path),
        logStatements: startup.enableLogs,
        cachePreparedStatements: startup.cachePreparedStatements,
        setup: startup.setup,
      ));
    });

    startup.sendServer.send(isolate);
  }
}
