import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/desktop/widgets/server_profile_dialog.dart';
import 'package:flutter_hbb/models/server_profile_model.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeServerProfileModel extends ServerProfileModelBase {
  FakeServerProfileModel({
    required List<ServerProfile> profiles,
    required String activeProfileId,
  })  : _profiles = profiles,
        _activeProfileId = activeProfileId;

  final List<ServerProfile> _profiles;
  final String _activeProfileId;
  bool busyValue = false;
  String? errorValue;
  Object? addError;
  Completer<void>? pendingAdd;
  final addCalls = <(String, String, String)>[];
  final updateCalls = <(String, String, String, String)>[];
  final removeCalls = <String>[];

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
  bool get loading => false;

  @override
  List<ServerProfile> get profiles => _profiles;

  @override
  bool get switching => false;

  @override
  Future<void> add(String name, String idServer, String key) async {
    addCalls.add((name, idServer, key));
    await pendingAdd?.future;
    final error = addError;
    if (error != null) throw error;
  }

  @override
  Future<void> recover() async {}

  @override
  Future<void> remove(String id) async {
    removeCalls.add(id);
  }

  @override
  Future<void> switchTo(String id) async {}

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

  testWidgets('server test result is cleared and stale results are ignored',
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
    first.complete('first result');
    await tester.pump();
    expect(find.text('translated:first result'), findsNothing);

    await tester.tap(find.byKey(const Key('test-profile-server')));
    second.complete('second result');
    await tester.pump();
    expect(find.text('translated:second result'), findsOneWidget);
    expect(testedServers, ['first.example.com', 'second.example.com']);

    await tester.enterText(
        find.byKey(const Key('profile-id-server')), 'third.example.com');
    await tester.pump();
    expect(find.text('translated:second result'), findsNothing);
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
}
