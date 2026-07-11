import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/desktop/widgets/server_profile_dialog.dart';
import 'package:flutter_hbb/desktop/widgets/server_profile_selector.dart';
import 'package:flutter_hbb/models/server_profile_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeServerProfileModel extends ServerProfileModelBase {
  FakeServerProfileModel({
    required List<ServerProfile> profiles,
    required String activeProfileId,
  })  : _profiles = List.of(profiles),
        _activeProfileId = activeProfileId;

  final List<ServerProfile> _profiles;
  String _activeProfileId;
  bool busyValue = false;
  bool loadingValue = false;
  bool switchingValue = false;
  String? errorValue;
  Object? addError;
  Object? switchError;
  Object? initializeError;
  Completer<void>? pendingAdd;
  Completer<void>? pendingSwitch;
  List<ServerProfile>? initializeProfiles;
  List<ServerProfile>? recoverProfiles;
  final addCalls = <(String, String, String)>[];
  final updateCalls = <(String, String, String, String)>[];
  final removeCalls = <String>[];
  final switchCalls = <String>[];
  int initializeCalls = 0;
  int loadCalls = 0;
  int recoverCalls = 0;
  bool _initialized = false;

  @override
  ServerProfile get active =>
      _profiles.firstWhere((profile) => profile.id == _activeProfileId);

  @override
  String? get activeProfileId => _activeProfileId;

  @override
  bool get busy => busyValue;

  @override
  String? get error => errorValue;

  @override
  bool get loading => loadingValue;

  @override
  List<ServerProfile> get profiles => _profiles;

  @override
  bool get switching => switchingValue;

  @override
  Future<void> add(String name, String idServer, String key) async {
    addCalls.add((name, idServer, key));
    await pendingAdd?.future;
    final error = addError;
    if (error != null) throw error;
  }

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    initializeCalls += 1;
    await _performLoad();
  }

  @override
  Future<void> load() async {
    loadCalls += 1;
    await _performLoad();
  }

  Future<void> _performLoad() async {
    final error = initializeError;
    if (error != null) {
      errorValue = error.toString();
      throw error;
    }
    final next = initializeProfiles;
    if (next != null) {
      _profiles
        ..clear()
        ..addAll(next);
      _activeProfileId = next.first.id;
    }
    _initialized = true;
    errorValue = null;
    notifyListeners();
  }

  @override
  Future<void> recover() async {
    recoverCalls += 1;
    final next = recoverProfiles;
    if (next != null) {
      _profiles
        ..clear()
        ..addAll(next);
      _activeProfileId = next.first.id;
    }
    errorValue = null;
    notifyListeners();
  }

  @override
  Future<void> remove(String id) async {
    removeCalls.add(id);
  }

  @override
  Future<void> switchTo(String id) async {
    switchCalls.add(id);
    await pendingSwitch?.future;
    final error = switchError;
    if (error != null) throw error;
    _activeProfileId = id;
    notifyListeners();
  }

  @override
  Future<void> update(
      String id, String name, String idServer, String key) async {
    updateCalls.add((id, name, idServer, key));
  }
}

const profiles = [
  ServerProfile(
    id: 'active',
    name: 'Active',
    idServer: 'active.example.com',
    key: 'active-secret',
  ),
  ServerProfile(
    id: 'other',
    name: 'Other',
    idServer: 'other.example.com',
    key: 'other-secret',
  ),
];

Future<void> pumpDialog(
  WidgetTester tester,
  FakeServerProfileModel model, {
  Future<String> Function(String server)? testServer,
  DeleteServerProfileConfirm? confirmDelete,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ServerProfileDialog(
          model: model,
          testServer: testServer,
          confirmDelete: confirmDelete,
          translator: (value) => 'translated:$value',
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('active profile is checked and editable but cannot be deleted',
      (tester) async {
    final model = FakeServerProfileModel(
      profiles: profiles,
      activeProfileId: 'active',
    );
    await pumpDialog(tester, model);

    expect(find.byKey(const Key('active-active')), findsOneWidget);
    expect(find.byKey(const Key('delete-active')), findsNothing);
    expect(find.byKey(const Key('edit-active')), findsOneWidget);
    expect(find.byKey(const Key('delete-other')), findsOneWidget);
    expect(find.text('other.example.com'), findsOneWidget);

    await tester.tap(find.byKey(const Key('edit-active')));
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('profile-id-server')))
          .controller!
          .text,
      'active.example.com',
    );
  });

  testWidgets('non-active profile deletion is confirmed before removal',
      (tester) async {
    final model = FakeServerProfileModel(
      profiles: profiles,
      activeProfileId: 'active',
    );
    Future<void> Function()? confirmedAction;
    await pumpDialog(
      tester,
      model,
      confirmDelete: (action, _) => confirmedAction = action,
    );

    await tester.tap(find.byKey(const Key('delete-other')));
    expect(model.removeCalls, isEmpty);
    expect(confirmedAction, isNotNull);
    await confirmedAction!();
    await tester.pump();
    expect(model.removeCalls, ['other']);
  });

  testWidgets('add validates trimmed required and case-insensitive unique name',
      (tester) async {
    final model = FakeServerProfileModel(
      profiles: profiles,
      activeProfileId: 'active',
    );
    await pumpDialog(tester, model);
    await tester.tap(find.byKey(const Key('add-profile')));
    await tester.pump();

    await tester.enterText(find.byKey(const Key('profile-name')), ' other ');
    await tester.enterText(
        find.byKey(const Key('profile-id-server')), ' server.example.com ');
    await tester.tap(find.byKey(const Key('save-profile')));
    await tester.pump();

    expect(
      find.text('translated:Name: translated:Already exists'),
      findsOneWidget,
    );
    expect(model.addCalls, isEmpty);

    await tester.enterText(find.byKey(const Key('profile-name')), '   ');
    await tester.enterText(find.byKey(const Key('profile-id-server')), '   ');
    await tester.tap(find.byKey(const Key('save-profile')));
    await tester.pump();
    expect(find.text('translated:Name: translated:Empty'), findsOneWidget);
    expect(find.text('translated:ID Server: translated:Empty'), findsOneWidget);
  });

  testWidgets('add trims all values passed to the model', (tester) async {
    final model = FakeServerProfileModel(
      profiles: profiles,
      activeProfileId: 'active',
    );
    await pumpDialog(tester, model);
    await tester.tap(find.byKey(const Key('add-profile')));
    await tester.pump();

    await tester.enterText(find.byKey(const Key('profile-name')), ' Home ');
    await tester.enterText(
        find.byKey(const Key('profile-id-server')), ' id.example.com ');
    await tester.enterText(find.byKey(const Key('profile-key')), ' key-value ');
    await tester.tap(find.byKey(const Key('save-profile')));
    await tester.pump();

    expect(model.addCalls, [('Home', 'id.example.com', 'key-value')]);
  });

  testWidgets('edit keeps id and passes trimmed updated values',
      (tester) async {
    final model = FakeServerProfileModel(
      profiles: profiles,
      activeProfileId: 'active',
    );
    await pumpDialog(tester, model);
    await tester.tap(find.byKey(const Key('edit-other')));
    await tester.pump();

    expect(find.text('other'), findsNothing);
    await tester.enterText(find.byKey(const Key('profile-name')), ' Office ');
    await tester.enterText(
        find.byKey(const Key('profile-id-server')), ' office.example.com ');
    await tester.enterText(
        find.byKey(const Key('profile-key')), ' new-secret ');
    await tester.tap(find.byKey(const Key('save-profile')));
    await tester.pump();

    expect(
      model.updateCalls,
      [('other', 'Office', 'office.example.com', 'new-secret')],
    );
  });

  testWidgets('failed connectivity test does not prevent save', (tester) async {
    final model = FakeServerProfileModel(
      profiles: profiles,
      activeProfileId: 'active',
    );
    final testedServers = <String>[];
    await pumpDialog(
      tester,
      model,
      testServer: (server) async {
        testedServers.add(server);
        return 'Server is unreachable';
      },
    );
    await tester.tap(find.byKey(const Key('add-profile')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('profile-name')), ' Remote ');
    await tester.enterText(
        find.byKey(const Key('profile-id-server')), ' remote.example.com ');

    await tester.tap(find.byKey(const Key('test-profile-server')));
    await tester.pumpAndSettle();
    expect(testedServers, ['remote.example.com']);
    expect(find.text('translated:Server is unreachable'), findsOneWidget);

    await tester.tap(find.byKey(const Key('save-profile')));
    await tester.pump();
    expect(model.addCalls, [('Remote', 'remote.example.com', '')]);
  });

  testWidgets('operation errors never expose the key value', (tester) async {
    const secret = 'private-key-value';
    final model = FakeServerProfileModel(
      profiles: profiles,
      activeProfileId: 'active',
    )..addError = const ServerProfileException('rejected private-key-value');
    await pumpDialog(tester, model);
    await tester.tap(find.byKey(const Key('add-profile')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('profile-name')), 'Remote');
    await tester.enterText(
        find.byKey(const Key('profile-id-server')), 'remote.example.com');
    await tester.enterText(find.byKey(const Key('profile-key')), secret);

    await tester.tap(find.byKey(const Key('save-profile')));
    await tester.pump();

    final error = tester.widget<Text>(find.byKey(const Key('profile-error')));
    expect(error.data, 'translated:rejected <redacted>');
    expect(error.data, isNot(contains(secret)));
  });

  testWidgets('an in-flight save disables duplicate submission',
      (tester) async {
    final pendingAdd = Completer<void>();
    final model = FakeServerProfileModel(
      profiles: profiles,
      activeProfileId: 'active',
    )..pendingAdd = pendingAdd;
    await pumpDialog(tester, model);
    await tester.tap(find.byKey(const Key('add-profile')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('profile-name')), 'Remote');
    await tester.enterText(
        find.byKey(const Key('profile-id-server')), 'remote.example.com');

    await tester.tap(find.byKey(const Key('save-profile')));
    await tester.pump();
    expect(
      tester
          .widget<ElevatedButton>(find.byKey(const Key('save-profile')))
          .onPressed,
      isNull,
    );
    expect(model.addCalls, hasLength(1));

    pendingAdd.complete();
    await tester.pump();
    expect(model.addCalls, hasLength(1));
  });

  testWidgets('editing server invalidates request and allows a newer test',
      (tester) async {
    final first = Completer<String>();
    final second = Completer<String>();
    final testedServers = <String>[];
    final model = FakeServerProfileModel(
      profiles: profiles,
      activeProfileId: 'active',
    );
    await pumpDialog(
      tester,
      model,
      testServer: (server) {
        testedServers.add(server);
        return testedServers.length == 1 ? first.future : second.future;
      },
    );
    await tester.tap(find.byKey(const Key('add-profile')));
    await tester.pump();
    await tester.enterText(
        find.byKey(const Key('profile-id-server')), ' first.example.com ');
    await tester.tap(find.byKey(const Key('test-profile-server')));
    await tester.pump();

    await tester.enterText(
        find.byKey(const Key('profile-id-server')), ' second.example.com ');
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('test-profile-server')))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const Key('test-profile-server')));
    await tester.pump();

    first.complete('first result');
    await tester.pump();
    expect(find.text('translated:first result'), findsNothing);
    expect(find.text('translated:second result'), findsNothing);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('test-profile-server')))
          .onPressed,
      isNull,
    );

    second.complete('second result');
    await tester.pump();
    expect(find.text('translated:second result'), findsOneWidget);
    expect(testedServers, ['first.example.com', 'second.example.com']);

    await tester.enterText(
        find.byKey(const Key('profile-id-server')), 'third.example.com');
    await tester.pump();
    expect(find.text('translated:second result'), findsNothing);
  });

  testWidgets('editing away and back still invalidates the old server test',
      (tester) async {
    final pending = Completer<String>();
    final model = FakeServerProfileModel(
      profiles: profiles,
      activeProfileId: 'active',
    );
    await pumpDialog(
      tester,
      model,
      testServer: (_) => pending.future,
    );
    await tester.tap(find.byKey(const Key('add-profile')));
    await tester.pump();
    final field = find.byKey(const Key('profile-id-server'));
    await tester.enterText(field, 'same.example.com');
    await tester.tap(find.byKey(const Key('test-profile-server')));
    await tester.pump();

    await tester.enterText(field, 'different.example.com');
    await tester.enterText(field, 'same.example.com');
    pending.complete('old result');
    await tester.pump();

    expect(find.text('translated:old result'), findsNothing);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('test-profile-server')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('field labels and validation use the injected translator',
      (tester) async {
    final model = FakeServerProfileModel(
      profiles: profiles,
      activeProfileId: 'active',
    );
    await pumpDialog(tester, model);
    await tester.tap(find.byKey(const Key('add-profile')));
    await tester.pump();

    expect(find.text('translated:Name'), findsOneWidget);
    expect(find.text('translated:ID Server'), findsOneWidget);
    expect(find.text('translated:Key'), findsOneWidget);
  });

  testWidgets('desktop enter submits and escape cancels the editor',
      (tester) async {
    final model = FakeServerProfileModel(
      profiles: profiles,
      activeProfileId: 'active',
    );
    await pumpDialog(tester, model);
    await tester.tap(find.byKey(const Key('add-profile')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('profile-name')), 'Remote');
    await tester.enterText(
        find.byKey(const Key('profile-id-server')), 'remote.example.com');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(model.addCalls, [('Remote', 'remote.example.com', '')]);
    expect(find.byKey(const Key('profile-name')), findsNothing);

    await tester.tap(find.byKey(const Key('add-profile')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const Key('profile-name')), findsNothing);
  });

  testWidgets('model busy disables profile operations', (tester) async {
    final model = FakeServerProfileModel(
      profiles: profiles,
      activeProfileId: 'active',
    )..busyValue = true;
    await pumpDialog(tester, model);

    expect(
      tester.widget<IconButton>(find.byKey(const Key('add-profile'))).onPressed,
      isNull,
    );
    expect(
      tester.widget<IconButton>(find.byKey(const Key('edit-other'))).onPressed,
      isNull,
    );
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('delete-other')))
          .onPressed,
      isNull,
    );
  });

  Future<void> pumpSelector(
    WidgetTester tester,
    FakeServerProfileModel model, {
    ValueChanged<String>? toast,
    ConfirmServerProfileRecovery? confirmRecovery,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ServerProfileSelector(
            model: model,
            translator: (value) => 'translated:$value',
            showToast: toast,
            confirmRecovery: confirmRecovery,
          ),
        ),
      ),
    );
  }

  testWidgets('selecting another profile switches exactly once',
      (tester) async {
    final model = FakeServerProfileModel(
      profiles: profiles,
      activeProfileId: 'active',
    );
    await pumpSelector(tester, model);

    await tester.tap(find.byKey(const Key('server-profile-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('profile-option-other')));
    await tester.pumpAndSettle();

    expect(model.switchCalls, ['other']);
    expect(find.text('Other'), findsOneWidget);
  });

  testWidgets('selecting the current profile does not switch', (tester) async {
    final model = FakeServerProfileModel(
      profiles: profiles,
      activeProfileId: 'active',
    );
    await pumpSelector(tester, model);

    await tester.tap(find.byKey(const Key('server-profile-selector')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('profile-current-active')), findsOneWidget);
    await tester.tap(find.byKey(const Key('profile-option-active')));
    await tester.pumpAndSettle();

    expect(model.switchCalls, isEmpty);
  });

  testWidgets('switching shows progress and prevents duplicate selection',
      (tester) async {
    final model = FakeServerProfileModel(
      profiles: profiles,
      activeProfileId: 'active',
    )
      ..busyValue = true
      ..switchingValue = true;
    await pumpSelector(tester, model);

    expect(
      tester
          .widget<InkWell>(
            find.byKey(const Key('server-profile-selector')),
          )
          .onTap,
      isNull,
    );
    expect(
      find.byKey(const Key('server-profile-switch-progress')),
      findsOneWidget,
    );
  });

  testWidgets('settings opens the server profile dialog', (tester) async {
    final model = FakeServerProfileModel(
      profiles: profiles,
      activeProfileId: 'active',
    );
    await pumpSelector(tester, model);

    await tester.tap(find.byKey(const Key('server-profile-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('server-profile-settings')));
    await tester.pumpAndSettle();

    expect(find.byType(ServerProfileDialog), findsOneWidget);
  });

  testWidgets('switch errors are toasted without exposing profile keys',
      (tester) async {
    final messages = <String>[];
    final model = FakeServerProfileModel(
      profiles: profiles,
      activeProfileId: 'active',
    )..switchError = const ServerProfileException(
        'rejected other-secret',
      );
    await pumpSelector(tester, model, toast: messages.add);

    await tester.tap(find.byKey(const Key('server-profile-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('profile-option-other')));
    await tester.pumpAndSettle();

    expect(messages, hasLength(1));
    expect(messages.single, contains('rejected'));
    expect(messages.single, isNot(contains('other-secret')));
    expect(model.activeProfileId, 'active');
  });

  testWidgets('selector presents ready connecting and not-ready states',
      (tester) async {
    final model = FakeServerProfileModel(
      profiles: profiles,
      activeProfileId: 'active',
    );
    await pumpSelector(tester, model);

    stateGlobal.svcStatus.value = SvcStatus.ready;
    await tester.pump();
    expect(find.text('translated:Ready'), findsOneWidget);

    stateGlobal.svcStatus.value = SvcStatus.connecting;
    await tester.pump();
    expect(find.text('translated:connecting_status'), findsOneWidget);

    stateGlobal.svcStatus.value = SvcStatus.notReady;
    await tester.pump();
    expect(find.text('translated:not_ready_status'), findsOneWidget);
  });

  testWidgets('loading state is safe before profiles are available',
      (tester) async {
    final model = FakeServerProfileModel(
      profiles: const [],
      activeProfileId: 'missing',
    )
      ..busyValue = true
      ..loadingValue = true;
    await pumpSelector(tester, model);

    expect(find.text('translated:Waiting'), findsOneWidget);
    expect(
      tester
          .widget<InkWell>(
            find.byKey(const Key('server-profile-selector')),
          )
          .onTap,
      isNull,
    );
  });

  testWidgets('failed initialization can be retried from the empty-state menu',
      (tester) async {
    final model = FakeServerProfileModel(
      profiles: const [],
      activeProfileId: 'missing',
    )..initializeError = const ServerProfileException('offline');
    await expectLater(
      model.initialize(),
      throwsA(isA<ServerProfileException>()),
    );
    await pumpSelector(tester, model);

    expect(find.text('translated:Error'), findsOneWidget);
    expect(
      tester
          .widget<InkWell>(find.byKey(const Key('server-profile-selector')))
          .onTap,
      isNotNull,
    );
    await tester.tap(find.byKey(const Key('server-profile-selector')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('server-profile-retry')), findsOneWidget);
    expect(find.byKey(const Key('server-profile-settings')), findsOneWidget);

    model
      ..initializeError = null
      ..initializeProfiles = profiles;
    await tester.tap(find.byKey(const Key('server-profile-retry')));
    await tester.pumpAndSettle();

    expect(model.initializeCalls, 1);
    expect(model.loadCalls, 1);
    expect(model.activeProfileId, 'active');
    expect(find.text('Active'), findsOneWidget);
  });

  testWidgets('settings remains available with no loaded profiles',
      (tester) async {
    final model = FakeServerProfileModel(
      profiles: const [],
      activeProfileId: 'missing',
    )..errorValue = 'unavailable';
    await pumpSelector(tester, model);

    await tester.tap(find.byKey(const Key('server-profile-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('server-profile-settings')));
    await tester.pumpAndSettle();

    expect(find.byType(ServerProfileDialog), findsOneWidget);
  });

  testWidgets('recover requires confirmation and restores profiles once',
      (tester) async {
    Future<void> Function()? confirmedAction;
    final model = FakeServerProfileModel(
      profiles: const [],
      activeProfileId: 'missing',
    )
      ..errorValue = 'corrupt'
      ..recoverProfiles = profiles;
    await pumpSelector(
      tester,
      model,
      confirmRecovery: (action, _) => confirmedAction = action,
    );

    await tester.tap(find.byKey(const Key('server-profile-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('server-profile-recover')));
    await tester.pumpAndSettle();
    expect(model.recoverCalls, 0);
    expect(confirmedAction, isNotNull);

    await confirmedAction!();
    await tester.pumpAndSettle();
    expect(model.recoverCalls, 1);
    expect(model.activeProfileId, 'active');
    expect(find.text('Active'), findsOneWidget);
  });

  testWidgets('a busy transition prevents a stale retry menu selection',
      (tester) async {
    final model = FakeServerProfileModel(
      profiles: const [],
      activeProfileId: 'missing',
    )..errorValue = 'offline';
    await pumpSelector(tester, model);

    await tester.tap(find.byKey(const Key('server-profile-selector')));
    await tester.pumpAndSettle();
    model
      ..busyValue = true
      ..notifyListeners();
    await tester.tap(find.byKey(const Key('server-profile-retry')));
    await tester.pumpAndSettle();

    expect(model.loadCalls, 0);
  });

  testWidgets('retry errors use a generic toast and never expose profile keys',
      (tester) async {
    final messages = <String>[];
    final model = FakeServerProfileModel(
      profiles: profiles,
      activeProfileId: 'active',
    )
      ..errorValue = 'previous failure'
      ..initializeError = const ServerProfileException(
        'rejected active-secret',
      );
    await pumpSelector(tester, model, toast: messages.add);

    await tester.tap(find.byKey(const Key('server-profile-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('server-profile-retry')));
    await tester.pumpAndSettle();

    expect(messages, ['translated:Failed']);
    expect(messages.single, isNot(contains('active-secret')));
  });

  testWidgets('responsive header keeps selector and card visible when narrow',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ServerProfileHomeHeader(
            connectionCard: SizedBox(
              key: Key('connection-card'),
              width: 360,
              height: 100,
            ),
            selector: SizedBox(
              key: Key('selector-slot'),
              width: 220,
              height: 40,
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('connection-card')), findsOneWidget);
    expect(find.byKey(const Key('selector-slot')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const Key('selector-slot'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('connection-card'))).dy),
    );
    expect(
      tester.getTopRight(find.byKey(const Key('selector-slot'))).dx,
      390,
    );
  });

  testWidgets('responsive header uses one row when wide', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ServerProfileHomeHeader(
            connectionCard: SizedBox(
              key: Key('connection-card'),
              width: 360,
              height: 100,
            ),
            selector: SizedBox(
              key: Key('selector-slot'),
              width: 220,
              height: 40,
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(
      tester.getTopLeft(find.byKey(const Key('selector-slot'))).dy,
      tester.getTopLeft(find.byKey(const Key('connection-card'))).dy,
    );
    expect(
      tester.getTopRight(find.byKey(const Key('selector-slot'))).dx,
      888,
    );
  });
}
