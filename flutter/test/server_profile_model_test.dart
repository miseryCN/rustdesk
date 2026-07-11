import 'dart:async';
import 'dart:convert';

import 'package:flutter_hbb/models/server_profile_model.dart';
import 'package:flutter_test/flutter_test.dart';

String _response({
  String activeProfileId = 'default',
  List<Map<String, Object?>>? profiles,
}) {
  return jsonEncode({
    'ok': true,
    'error': '',
    'config': {
      'version': 1,
      'active_profile_id': activeProfileId,
      'profiles': profiles ??
          [
            {
              'id': 'default',
              'name': 'Default',
              'id_server': 'default.example.com',
              'key': 'default-key',
            },
          ],
    },
  });
}

class FakeServerProfileApi implements ServerProfileApi {
  String getResponse = _response();
  String addResponse = _response();
  String updateResponse = _response();
  String removeResponse = _response();
  String switchResponse = _response();
  String recoverResponse = _response();
  Completer<String>? pendingGet;
  Completer<String>? pendingSwitch;
  Object? getError;
  int getCalls = 0;
  int switchCalls = 0;

  @override
  Future<String> getProfiles() {
    getCalls += 1;
    final error = getError;
    if (error != null) return Future.error(error);
    return pendingGet?.future ?? Future.value(getResponse);
  }

  @override
  Future<String> addProfile(String name, String idServer, String key) async =>
      addResponse;

  @override
  Future<String> updateProfile(
          String id, String name, String idServer, String key) async =>
      updateResponse;

  @override
  Future<String> removeProfile(String id) async => removeResponse;

  @override
  Future<String> switchProfile(String id) {
    switchCalls += 1;
    return pendingSwitch?.future ?? Future.value(switchResponse);
  }

  @override
  Future<String> recoverProfiles() async => recoverResponse;
}

void main() {
  test('initialize coalesces concurrent calls and remains idempotent',
      () async {
    final pending = Completer<String>();
    final api = FakeServerProfileApi()..pendingGet = pending;
    final model = ServerProfileModel(api: api);

    final first = model.initialize();
    final second = model.initialize();
    expect(api.getCalls, 1);

    pending.complete(_response());
    await Future.wait([first, second]);
    await model.initialize();

    expect(api.getCalls, 1);
    expect(model.activeProfileId, 'default');
  });

  test('initialize can retry after a failed attempt', () async {
    final api = FakeServerProfileApi()..getError = StateError('offline');
    final model = ServerProfileModel(api: api);

    await expectLater(
        model.initialize(), throwsA(isA<ServerProfileException>()));
    api.getError = null;
    await model.initialize();

    expect(api.getCalls, 2);
    expect(model.activeProfileId, 'default');
  });

  test('recent peer refresh restores both lists when loading fails', () async {
    final peers = <String>['peer-1'];
    final restPeerIds = <String>['peer-2'];
    var notifications = 0;

    await expectLater(
      refreshRecentPeersTransaction(
        peers: peers,
        restPeerIds: restPeerIds,
        notify: () => notifications += 1,
        load: () async {
          expect(peers, isEmpty);
          expect(restPeerIds, isEmpty);
          throw StateError('load failed');
        },
      ),
      throwsStateError,
    );

    expect(peers, ['peer-1']);
    expect(restPeerIds, ['peer-2']);
    expect(notifications, 2);
  });

  test('parses a successful response and resolves the active profile', () {
    final state = parseServerProfilesResponse(_response());

    expect(state.version, 1);
    expect(state.activeProfileId, 'default');
    expect(state.active.name, 'Default');
    expect(state.active.idServer, 'default.example.com');
    expect(state.active.key, 'default-key');
  });

  test('throws the safe Rust error for an unsuccessful response', () {
    final json = jsonEncode({
      'ok': false,
      'error': 'server profile is unavailable',
      'config': null,
    });

    expect(
      () => parseServerProfilesResponse(json),
      throwsA(
        isA<ServerProfileException>().having(
          (error) => error.message,
          'message',
          'server profile is unavailable',
        ),
      ),
    );
  });

  test('rejects malformed JSON and invalid response field types', () {
    final invalidResponses = <String>[
      'not json',
      jsonEncode({'ok': 'true', 'error': '', 'config': null}),
      jsonEncode({'ok': true, 'error': '', 'config': null}),
      jsonEncode({
        'ok': true,
        'error': '',
        'config': {
          'version': '1',
          'active_profile_id': 'default',
          'profiles': <Object?>[],
        },
      }),
    ];

    for (final response in invalidResponses) {
      expect(
        () => parseServerProfilesResponse(response),
        throwsA(isA<ServerProfileException>()),
      );
    }
  });

  test('rejects a config whose active profile is missing', () {
    final response = _response(
      activeProfileId: 'missing',
      profiles: [
        {
          'id': 'other',
          'name': 'Other',
          'id_server': 'other.example.com',
          'key': '',
        },
      ],
    );

    expect(
      () => parseServerProfilesResponse(response),
      throwsA(isA<ServerProfileException>()),
    );
  });

  test('rejects unsupported, empty, and duplicate profile configs', () {
    Map<String, Object?> config({
      int version = 1,
      List<Map<String, Object?>> profiles = const [],
    }) =>
        {
          'ok': true,
          'error': '',
          'config': {
            'version': version,
            'active_profile_id': 'default',
            'profiles': profiles,
          },
        };
    final duplicate = {
      'id': 'default',
      'name': 'Default',
      'id_server': '',
      'key': '',
    };

    for (final response in [
      config(version: 2, profiles: [duplicate]),
      config(),
      config(profiles: [duplicate, duplicate]),
    ]) {
      expect(
        () => parseServerProfilesResponse(jsonEncode(response)),
        throwsA(isA<ServerProfileException>()),
      );
    }
  });

  test('load atomically replaces model state', () async {
    final api = FakeServerProfileApi()
      ..getResponse = _response(
        activeProfileId: 'work',
        profiles: [
          {
            'id': 'work',
            'name': 'Work',
            'id_server': 'work.example.com',
            'key': 'work-key',
          },
        ],
      );
    final model = ServerProfileModel(api: api);

    await model.load();

    expect(model.loading, isFalse);
    expect(model.error, isNull);
    expect(model.activeProfileId, 'work');
    expect(model.profiles.single.name, 'Work');
  });

  test('failed operation preserves the previous state', () async {
    final api = FakeServerProfileApi();
    final model = ServerProfileModel(api: api);
    await model.load();
    final before = model.state;
    api.updateResponse = jsonEncode({
      'ok': false,
      'error': 'update rejected',
      'config': null,
    });

    await expectLater(
      model.update('default', 'Changed', 'changed.example.com', 'new-key'),
      throwsA(isA<ServerProfileException>()),
    );

    expect(model.state, same(before));
    expect(model.error, 'update rejected');
    expect(model.loading, isFalse);
  });

  test('a second switch is rejected while switching is busy', () async {
    final api = FakeServerProfileApi()..pendingSwitch = Completer<String>();
    final model = ServerProfileModel(api: api);
    await model.load();

    final firstSwitch = model.switchTo('default');
    expect(model.switching, isTrue);
    await expectLater(
      model.switchTo('default'),
      throwsA(isA<ServerProfileException>()),
    );
    expect(api.switchCalls, 1);

    api.pendingSwitch!.complete(_response());
    await firstSwitch;
    expect(model.switching, isFalse);
  });

  test('successful switch refreshes recent peers exactly once', () async {
    final api = FakeServerProfileApi()
      ..switchResponse = _response(
        activeProfileId: 'work',
        profiles: [
          {
            'id': 'default',
            'name': 'Default',
            'id_server': 'default.example.com',
            'key': '',
          },
          {
            'id': 'work',
            'name': 'Work',
            'id_server': 'work.example.com',
            'key': 'work-key',
          },
        ],
      );
    var refreshes = 0;
    final model = ServerProfileModel(
      api: api,
      refreshRecentPeers: () async => refreshes += 1,
    );
    await model.load();

    await model.switchTo('work');

    expect(model.activeProfileId, 'work');
    expect(refreshes, 1);
  });

  test('failed switch response does not refresh recent peers', () async {
    final api = FakeServerProfileApi()
      ..switchResponse = jsonEncode({
        'ok': false,
        'error': 'switch rejected',
        'config': null,
      });
    var refreshes = 0;
    final model = ServerProfileModel(
      api: api,
      refreshRecentPeers: () => refreshes += 1,
    );
    await model.load();

    await expectLater(
      model.switchTo('default'),
      throwsA(isA<ServerProfileException>()),
    );

    expect(refreshes, 0);
  });

  test('switch remove and recover commit state before refreshing', () async {
    final nextResponse = _response(
      activeProfileId: 'work',
      profiles: [
        {
          'id': 'work',
          'name': 'Work',
          'id_server': 'work.example.com',
          'key': 'work-key',
        },
      ],
    );
    final operations = <Future<void> Function(ServerProfileModel)>[
      (model) => model.switchTo('work'),
      (model) => model.remove('default'),
      (model) => model.recover(),
    ];

    for (final operation in operations) {
      final api = FakeServerProfileApi()
        ..switchResponse = nextResponse
        ..removeResponse = nextResponse
        ..recoverResponse = nextResponse;
      late final ServerProfileModel model;
      String? activeDuringRefresh;
      model = ServerProfileModel(
        api: api,
        refreshRecentPeers: () {
          activeDuringRefresh = model.activeProfileId;
        },
      );
      await model.load();

      await operation(model);

      expect(activeDuringRefresh, 'work');
      expect(model.activeProfileId, 'work');
    }
  });

  test('refresh failure keeps committed state and restores recent peers',
      () async {
    final api = FakeServerProfileApi()
      ..switchResponse = _response(
        activeProfileId: 'work',
        profiles: [
          {
            'id': 'work',
            'name': 'Work',
            'id_server': 'work.example.com',
            'key': 'work-key',
          },
        ],
      );
    final peers = <String>['peer-1'];
    final restPeerIds = <String>['peer-2'];
    late final ServerProfileModel model;
    model = ServerProfileModel(
      api: api,
      refreshRecentPeers: () => refreshRecentPeersTransaction(
        peers: peers,
        restPeerIds: restPeerIds,
        notify: () {},
        load: () async {
          expect(model.activeProfileId, 'work');
          throw StateError('refresh failed');
        },
      ),
    );
    await model.load();

    await expectLater(
      model.switchTo('work'),
      throwsA(
        isA<ServerProfileRefreshException>().having(
          (error) => error.message,
          'message',
          contains('recent connections could not be refreshed'),
        ),
      ),
    );

    expect(model.activeProfileId, 'work');
    expect(peers, ['peer-1']);
    expect(restPeerIds, ['peer-2']);
    expect(model.error, contains('recent connections could not be refreshed'));
    expect(model.switching, isFalse);
  });

  test('remove refreshes recent peers exactly once', () async {
    final api = FakeServerProfileApi();
    var refreshes = 0;
    final model = ServerProfileModel(
      api: api,
      refreshRecentPeers: () => refreshes += 1,
    );
    await model.load();

    await model.remove('unused');

    expect(refreshes, 1);
  });

  test('recover replaces state and refreshes recent peers', () async {
    final api = FakeServerProfileApi()
      ..recoverResponse = _response(
        profiles: [
          {
            'id': 'default',
            'name': 'Recovered',
            'id_server': 'recovered.example.com',
            'key': 'recovered-key',
          },
        ],
      );
    var refreshes = 0;
    final model = ServerProfileModel(
      api: api,
      refreshRecentPeers: () async => refreshes += 1,
    );
    await model.load();

    await model.recover();

    expect(model.active.name, 'Recovered');
    expect(refreshes, 1);
  });

  test('keeps keys in DTOs but never exposes the submitted key in errors',
      () async {
    const secret = 'never-print-this-key';
    final api = FakeServerProfileApi();
    final model = ServerProfileModel(api: api);
    await model.load();
    expect(model.active.key, 'default-key');
    api.addResponse = jsonEncode({
      'ok': false,
      'error': 'invalid key: $secret',
      'config': null,
    });

    await expectLater(
      model.add('Secret', 'secret.example.com', secret),
      throwsA(
        isA<ServerProfileException>().having(
          (error) => error.toString(),
          'text',
          isNot(contains(secret)),
        ),
      ),
    );
    expect(model.error, isNot(contains(secret)));
  });
}
