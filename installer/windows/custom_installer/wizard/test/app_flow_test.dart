import 'dart:io';

import 'package:auradsp_setup/l10n/app_localizations.dart';
import 'package:auradsp_setup/src/app.dart';
import 'package:auradsp_setup/src/args.dart';
import 'package:auradsp_setup/src/engine/install_engine.dart';
import 'package:auradsp_setup/src/engine/models.dart';
import 'package:auradsp_setup/src/engine/update_policy.dart';
import 'package:auradsp_setup/src/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _wizard = WizardManifest(
  version: '0.1.0',
  fullVersion: '0.1.0.1',
  payloadSha256: '',
  payloadFiles: [],
);

InstallManifest _manifest(String dir) => InstallManifest(
  version: '0.1.0',
  fullVersion: '0.1.0.1',
  installDir: dir,
  allUsers: false,
  components: const ['app'],
  files: const [],
  shortcuts: const [],
  installedAtIso: '2026-11-28T00:00:00',
);

class _FakeEngine extends InstallEngine {
  _FakeEngine({required super.args, required super.wizard});

  InstallOptions? options;
  UpdatePlan? plan;
  bool? skipPrivilegedSteps;
  Object? uninstallError;

  @override
  Future<EngineResult> install(
    InstallOptions options,
    ProgressSink sink, {
    UpdatePlan? plan,
    FileErrorHandler? onFileError,
    bool skipPrivilegedSteps = false,
  }) async {
    this.options = options;
    this.plan = plan;
    this.skipPrivilegedSteps = skipPrivilegedSteps;
    return const EngineResult(ok: true);
  }

  @override
  Future<EngineResult> uninstall(
    InstallManifest manifest, {
    required bool keepData,
    required ProgressSink sink,
  }) async {
    if (uninstallError != null) throw uninstallError!;
    return const EngineResult(ok: true);
  }
}

class _FakeTargetInspector implements InstallTargetInspector {
  final List<String> operations = [];
  FileSystemException? writeError;

  @override
  Future<void> createDirectory(String path) async {
    operations.add('create:$path');
  }

  @override
  Future<File> createProbe(String path) async {
    operations.add('probe:$path');
    return File('$path\\.auradsp-write-probe-test');
  }

  @override
  Future<List<FileSystemEntity>> listDirectory(String path) async {
    operations.add('list:$path');
    return const [];
  }

  @override
  Future<String?> readManifest(File file) async {
    operations.add('read:${file.path}');
    return null;
  }

  @override
  Future<void> writeProbe(File file) async {
    operations.add('write:${file.path}');
    if (writeError != null) throw writeError!;
  }

  @override
  Future<void> deleteProbe(File file) async {
    operations.add('delete:${file.path}');
  }
}

Future<void> _pumpShell(
  WidgetTester tester, {
  Future<InstalledInfo?> Function()? installedInfoReader,
  Future<bool> Function({required bool autoStart, required bool autoUninstall})?
  elevationRequester,
  bool elevated = false,
  InstallEngine Function()? engineFactory,
  InstallTargetInspector? targetInspector,
  bool Function(String dir)? existingAppChecker,
  SetupArgs? args,
  void Function()? protectedSessionValidator,
}) async {
  final session = Directory.systemTemp.createTempSync('auradsp-flow-session-');
  addTearDown(() => session.deleteSync(recursive: true));
  final effectiveArgs =
      args ?? SetupArgs.parse(['--session-dir', session.path]);
  tester.view.physicalSize = const Size(960, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: Aurora.theme(),
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SetupShell(
        args: effectiveArgs,
        wizard: _wizard,
        installedInfoReader: installedInfoReader,
        elevationRequester: elevationRequester,
        elevatedChecker: () => elevated,
        engineFactory: engineFactory,
        targetInspector: targetInspector ?? _FakeTargetInspector(),
        existingAppChecker: existingAppChecker ?? (_) => false,
        protectedSessionValidator: protectedSessionValidator,
      ),
    ),
  );
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });
  await _pumpFrames(tester);
}

Future<void> _pumpFrames(WidgetTester tester) async {
  for (var frame = 0; frame < 5; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _openOptions(WidgetTester tester) async {
  final license = find.byType(Checkbox).first;
  await tester.ensureVisible(license);
  await tester.tap(license);
  await _pumpFrames(tester);
  expect(tester.widget<Checkbox>(license).value, isTrue);
  final next = find.text('Next');
  expect(next, findsOneWidget);
  final nextButton = find.ancestor(
    of: next,
    matching: find.byType(FilledButton),
  );
  expect(tester.widget<FilledButton>(nextButton).onPressed, isNotNull);
  await tester.ensureVisible(next);
  await tester.tap(next);
  await _pumpFrames(tester);
  expect(find.text('Welcome to AuraDSP'), findsOneWidget);
  expect(find.text('Start install'), findsOneWidget);
}

void main() {
  testWidgets('welcome has one Next action into the original options page', (
    tester,
  ) async {
    await _pumpShell(tester, installedInfoReader: () async => null);

    expect(find.text('Install now'), findsNothing);
    expect(find.text('Custom install'), findsNothing);
    expect(find.text('Next'), findsOneWidget);
    await _openOptions(tester);
    expect(find.text('Start install'), findsOneWidget);
  });

  testWidgets('registered existing app hides the all-users option', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('auradsp-flow-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final engine = _FakeEngine(args: SetupArgs.parse([]), wizard: _wizard);
    await _pumpShell(
      tester,
      installedInfoReader: () async => InstalledInfo(
        fullVersion: '0.1.0.1',
        installDir: '${temp.path}\\AuraDSP',
        allUsers: true,
      ),
      elevated: true,
      engineFactory: () => engine,
    );

    await _openOptions(tester);
    expect(
      find.text('Install for all users (requires administrator)'),
      findsNothing,
    );
    final start = find.text('Start install');
    await tester.ensureVisible(start);
    await tester.tap(start);
    await _pumpFrames(tester);
    expect(engine.options?.allUsers, isTrue);
  });

  testWidgets('old app in the selected target also hides all-users', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('auradsp-flow-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final target = Directory('${temp.path}\\AuraDSP');
    target.createSync(recursive: true);
    File('${target.path}\\auradsp_app.exe').writeAsStringSync('old');
    await _pumpShell(
      tester,
      installedInfoReader: () async => null,
      existingAppChecker: (dir) =>
          dir == target.path &&
          File('${target.path}\\auradsp_app.exe').existsSync(),
    );

    await _openOptions(tester);
    await tester.enterText(find.byType(TextField), temp.path);
    await tester.pump();
    expect(
      find.text('Install for all users (requires administrator)'),
      findsNothing,
    );
  });

  testWidgets(
    'denied elevation skips privileged steps when target is writable',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync('auradsp-flow-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final engine = _FakeEngine(args: SetupArgs.parse([]), wizard: _wizard);
      final inspector = _FakeTargetInspector();
      var elevationCalls = 0;
      var validatedBeforeProbe = false;
      await _pumpShell(
        tester,
        installedInfoReader: () async => null,
        elevationRequester:
            ({required autoStart, required autoUninstall}) async {
              elevationCalls++;
              return false;
            },
        engineFactory: () => engine,
        targetInspector: inspector,
        protectedSessionValidator: () {
          validatedBeforeProbe = inspector.operations.isEmpty;
        },
      );

      await _openOptions(tester);
      await tester.enterText(find.byType(TextField), temp.path);
      final start = find.text('Start install');
      await tester.ensureVisible(start);
      await tester.tap(start);
      await _pumpFrames(tester);

      expect(validatedBeforeProbe, isTrue);
      expect(elevationCalls, 1);
      expect(engine.options, isNotNull);
      expect(engine.skipPrivilegedSteps, isTrue);
      expect(find.text('Administrator rights not granted'), findsNothing);
    },
  );

  testWidgets('corrupt elevated resume fails closed before auto install', (
    tester,
  ) async {
    final session = Directory.systemTemp.createTempSync('auradsp-resume-');
    addTearDown(() => session.deleteSync(recursive: true));
    final resume = File('${session.path}\\resume_options.json')
      ..writeAsStringSync('{broken');
    final engine = _FakeEngine(args: SetupArgs.parse([]), wizard: _wizard);
    var readerCalls = 0;
    await _pumpShell(
      tester,
      args: SetupArgs.parse([
        '--session-dir',
        session.path,
        '--resume-options',
        resume.path,
        '--elevated',
        '--auto-start',
      ]),
      installedInfoReader: () async {
        readerCalls++;
        return null;
      },
      engineFactory: () => engine,
      protectedSessionValidator: () {},
    );

    expect(readerCalls, 0);
    expect(engine.options, isNull);
    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.textContaining('resume'), findsOneWidget);
  });

  testWidgets('elevation exception clears waiting state and shows error', (
    tester,
  ) async {
    final engine = _FakeEngine(args: SetupArgs.parse([]), wizard: _wizard);
    await _pumpShell(
      tester,
      installedInfoReader: () async => null,
      elevationRequester: ({required autoStart, required autoUninstall}) async {
        throw StateError('elevate exploded');
      },
      engineFactory: () => engine,
    );

    await _openOptions(tester);
    final start = find.text('Start install');
    await tester.ensureVisible(start);
    await tester.tap(start);
    await _pumpFrames(tester);

    expect(engine.options, isNull);
    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.textContaining('elevate exploded'), findsOneWidget);
    expect(
      find.textContaining('Waiting for Windows administrator approval'),
      findsNothing,
    );
  });

  testWidgets(
    'overwrite probes read/write before UAC and reports denied access',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync('auradsp-flow-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final target = '${temp.path}\\AuraDSP';
      final inspector = _FakeTargetInspector()
        ..writeError = const FileSystemException(
          'denied',
          'probe',
          OSError('denied', 5),
        );
      final engine = _FakeEngine(args: SetupArgs.parse([]), wizard: _wizard);
      var elevationCalls = 0;
      await _pumpShell(
        tester,
        installedInfoReader: () async => InstalledInfo(
          fullVersion: '0.1.0.1',
          installDir: target,
          allUsers: true,
        ),
        elevationRequester:
            ({required autoStart, required autoUninstall}) async {
              elevationCalls++;
              return false;
            },
        engineFactory: () => engine,
        targetInspector: inspector,
      );

      await _openOptions(tester);
      final start = find.text('Start install');
      await tester.ensureVisible(start);
      await tester.tap(start);
      await _pumpFrames(tester);

      expect(elevationCalls, 1);
      expect(
        inspector.operations.where((op) => op.startsWith('list:')),
        hasLength(2),
      );
      expect(
        inspector.operations.where((op) => op.startsWith('read:')),
        hasLength(2),
      );
      expect(
        inspector.operations.where((op) => op.startsWith('write:')),
        hasLength(2),
      );
      expect(engine.options, isNull);
      expect(find.text('Something went wrong'), findsOneWidget);
      expect(find.textContaining(target), findsOneWidget);
    },
  );

  testWidgets('uninstall elevation exception clears waiting state', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('auradsp-uninstall-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final setupExe = '${temp.path}\\uninstall.exe';
    File(setupExe).writeAsStringSync('setup');
    File('${temp.path}\\install_manifest.json')
        .writeAsStringSync(_manifest(temp.path).encode());
    final engine = _FakeEngine(args: SetupArgs.parse([]), wizard: _wizard);
    await _pumpShell(
      tester,
      args: SetupArgs.parse([
        '--mode',
        'uninstall',
        '--setup-exe',
        setupExe,
        '--session-dir',
        temp.path,
      ]),
      elevationRequester: ({required autoStart, required autoUninstall}) async {
        throw StateError('uninstall elevation exploded');
      },
      engineFactory: () => engine,
    );

    await tester.tap(find.text('Uninstall'));
    await _pumpFrames(tester);
    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.textContaining('uninstall elevation exploded'), findsOneWidget);
    expect(
      find.textContaining('Waiting for Windows administrator approval'),
      findsNothing,
    );
  });

  testWidgets('uninstall engine exception clears running state', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('auradsp-uninstall-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final setupExe = '${temp.path}\\uninstall.exe';
    File(setupExe).writeAsStringSync('setup');
    File('${temp.path}\\install_manifest.json')
        .writeAsStringSync(_manifest(temp.path).encode());
    final engine = _FakeEngine(args: SetupArgs.parse([]), wizard: _wizard)
      ..uninstallError = StateError('uninstall engine exploded');
    await _pumpShell(
      tester,
      args: SetupArgs.parse([
        '--mode',
        'uninstall',
        '--setup-exe',
        setupExe,
        '--session-dir',
        temp.path,
      ]),
      elevated: true,
      engineFactory: () => engine,
    );

    await tester.tap(find.text('Uninstall'));
    await _pumpFrames(tester);
    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.textContaining('uninstall engine exploded'), findsOneWidget);
  });
}
