import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_test/flutter_test.dart';

String _snapshot(String profileId, List<String> peerIds,
        {List<String> restIds = const []}) =>
    jsonEncode({
      'ok': true,
      'profile_id': profileId,
      'peers': peerIds
          .map((id) => {
                'id': id,
                'platform': 'Linux',
              })
          .toList(),
      'ids': restIds,
      'error': '',
    });

Future<RecentPeersModel> _loadedHomeModelThen(String response) async {
  var calls = 0;
  final model = RecentPeersModel(loader: (_) async {
    if (calls++ == 0) {
      return _snapshot('home', ['previous-peer'], restIds: ['previous-rest']);
    }
    return response;
  });
  await model.refresh('home');
  return model;
}

void main() {
  test('slow old profile result cannot overwrite the switched profile',
      () async {
    final home = Completer<String>();
    final office = Completer<String>();
    final model = RecentPeersModel(loader: (profileId) {
      return profileId == 'home' ? home.future : office.future;
    });

    final oldLoad = model.invalidateAndRefresh('home');
    final newLoad = model.invalidateAndRefresh('office');
    office.complete(_snapshot('office', ['office-peer']));
    await newLoad;
    expect(model.peers.map((peer) => peer.id), ['office-peer']);

    home.complete(_snapshot('home', ['home-peer']));
    await oldLoad;
    expect(model.peers.map((peer) => peer.id), ['office-peer']);
  });

  test('an old epoch for the same logical profile is discarded', () async {
    final first = Completer<String>();
    final second = Completer<String>();
    var calls = 0;
    final model = RecentPeersModel(loader: (_) {
      calls += 1;
      return calls == 1 ? first.future : second.future;
    });

    final oldLoad = model.invalidateAndRefresh('home');
    final newLoad = model.invalidateAndRefresh('home');
    second.complete(_snapshot('home', ['new-identity-peer']));
    await newLoad;
    first.complete(_snapshot('home', ['retired-identity-peer']));
    await oldLoad;

    expect(model.peers.map((peer) => peer.id), ['new-identity-peer']);
  });

  test('same profile and epoch refreshes are single-flight', () async {
    final pending = Completer<String>();
    var calls = 0;
    final model = RecentPeersModel(loader: (_) {
      calls += 1;
      return pending.future;
    });

    final first = model.refresh('home');
    final second = model.refresh('home');
    expect(calls, 1);
    expect(second, same(first));

    pending.complete(_snapshot('home', ['peer']));
    await Future.wait([first, second]);
  });

  test('the load future completes only after the snapshot is applied',
      () async {
    final model = RecentPeersModel(
      loader: (_) async => _snapshot('home', ['peer']),
    );

    await model.refresh('home');

    expect(model.peers.map((peer) => peer.id), ['peer']);
  });

  test('a valid empty snapshot clears peers and rest ids', () async {
    final model = RecentPeersModel(
      loader: (_) async => _snapshot('home', const []),
    )
      ..peers = [Peer.loading()]
      ..restPeerIds = ['rest'];

    await model.refresh('home');

    expect(model.peers, isEmpty);
    expect(model.restPeerIds, isEmpty);
  });

  test('same-identity I/O and parse failures preserve the previous snapshot',
      () async {
    for (final response in [
      jsonEncode({
        'ok': false,
        'profile_id': 'home',
        'peers': [],
        'ids': [],
        'error': 'peer directory unavailable',
      }),
      '{bad json',
    ]) {
      final model = await _loadedHomeModelThen(response);

      await expectLater(
        model.refresh('home'),
        throwsA(isA<RecentPeersLoadException>()),
      );
      expect(model.peers.single.id, 'previous-peer');
      expect(model.restPeerIds, ['previous-rest']);
    }
  });

  test('a mismatched profile response is rejected without mutation', () async {
    final model =
        await _loadedHomeModelThen(_snapshot('other', ['wrong-peer']));

    await expectLater(
      model.refresh('home'),
      throwsA(isA<RecentPeersLoadException>()),
    );
    expect(model.peers.single.id, 'previous-peer');
    expect(model.restPeerIds, ['previous-rest']);
  });

  test('malformed success snapshots preserve the previous snapshot', () async {
    final malformed = <Map<String, Object?>>[
      {
        'ok': true,
        'profile_id': 'home',
        'peers': [],
        'ids': [],
        'error': 'success must not carry an error',
      },
      {
        'ok': true,
        'profile_id': 'home',
        'peers': [
          {'id': '', 'platform': 'Linux'}
        ],
        'ids': [],
        'error': '',
      },
      {
        'ok': true,
        'profile_id': 'home',
        'peers': [
          {'id': 'peer', 'platform': 42}
        ],
        'ids': [],
        'error': '',
      },
      {
        'ok': true,
        'profile_id': 'home',
        'peers': [],
        'ids': ['rest', 'rest'],
        'error': '',
      },
      {
        'ok': true,
        'profile_id': 'home',
        'peers': [],
        'ids': [''],
        'error': '',
      },
    ];

    for (final value in malformed) {
      final model = await _loadedHomeModelThen(jsonEncode(value));

      await expectLater(
        model.refresh('home'),
        throwsA(isA<RecentPeersLoadException>()),
      );
      expect(model.peers.single.id, 'previous-peer');
      expect(model.restPeerIds, ['previous-rest']);
    }
  });

  test('failed snapshots require a nonempty error and never apply payload',
      () async {
    for (final error in ['', '   ']) {
      final model = await _loadedHomeModelThen(jsonEncode({
        'ok': false,
        'profile_id': 'home',
        'peers': [
          {'id': 'must-not-apply', 'platform': 'Linux'}
        ],
        'ids': ['must-not-apply'],
        'error': error,
      }));

      await expectLater(
        model.refresh('home'),
        throwsA(isA<RecentPeersLoadException>()),
      );
      expect(model.peers.single.id, 'previous-peer');
      expect(model.restPeerIds, ['previous-rest']);
    }
  });

  test('identity invalidation clears immediately and stays empty on failure',
      () async {
    final pending = Completer<String>();
    final model = RecentPeersModel(loader: (_) => pending.future)
      ..peers = [Peer.loading()]
      ..restPeerIds = ['old-rest'];
    var notifications = 0;
    model.addListener(() => notifications += 1);

    final refresh = model.invalidateAndRefresh('office');

    expect(model.peers, isEmpty);
    expect(model.restPeerIds, isEmpty);
    expect(notifications, 1);
    pending.complete(jsonEncode({
      'ok': false,
      'profile_id': 'office',
      'peers': [],
      'ids': [],
      'error': 'storage unavailable',
    }));
    await expectLater(refresh, throwsA(isA<RecentPeersLoadException>()));
    expect(model.peers, isEmpty);
    expect(model.restPeerIds, isEmpty);
    expect(notifications, 1);
  });

  test('a normal refresh invalidates when the profile identity changes',
      () async {
    final office = Completer<String>();
    final model = RecentPeersModel(loader: (profileId) {
      if (profileId == 'home') {
        return Future.value(
            _snapshot('home', ['home-peer'], restIds: ['home-rest']));
      }
      return office.future;
    });
    await model.refresh('home');
    var notifications = 0;
    model.addListener(() => notifications += 1);

    final refresh = model.refresh('office');

    expect(model.peers, isEmpty);
    expect(model.restPeerIds, isEmpty);
    expect(notifications, 1);
    office.complete(jsonEncode({
      'ok': false,
      'profile_id': 'office',
      'peers': [],
      'ids': [],
      'error': 'storage unavailable',
    }));
    await expectLater(refresh, throwsA(isA<RecentPeersLoadException>()));
    expect(model.peers, isEmpty);
    expect(model.restPeerIds, isEmpty);
    expect(notifications, 1);
  });

  test('only a normal same-identity refresh inherits online state', () async {
    final responses = <String>[
      _snapshot('home', ['same-peer']),
      _snapshot('home', ['same-peer']),
      _snapshot('home', ['same-peer']),
    ];
    final model = RecentPeersModel(loader: (_) async => responses.removeAt(0));
    await model.refresh('home');
    model.peers.single.online = true;

    await model.refresh('home');
    expect(model.peers.single.online, isTrue);

    await model.invalidateAndRefresh('home');
    expect(model.peers.single.online, isFalse);
  });

  test('safe refresh reports one generic Flutter error and never throws',
      () async {
    const secret = 'never-report-this-key';
    final previousHandler = FlutterError.onError;
    final reports = <FlutterErrorDetails>[];
    FlutterError.onError = reports.add;
    addTearDown(() => FlutterError.onError = previousHandler);
    final model = RecentPeersModel(
      loader: (_) => Future.error(StateError(secret)),
    );

    final receipt = await model.refreshSafely('home');

    expect(receipt.applied, isFalse);
    expect(reports, hasLength(1));
    expect(reports.single.exceptionAsString(), isNot(contains(secret)));
    expect(reports.single.exceptionAsString().toLowerCase(),
        contains('recent connections'));
  });

  test('safe refresh reports applied only for the current profile epoch',
      () async {
    final old = Completer<String>();
    final current = Completer<String>();
    var calls = 0;
    final model = RecentPeersModel(loader: (_) {
      calls += 1;
      return calls == 1 ? old.future : current.future;
    });

    final oldRefresh = model.refreshSafely('home');
    final currentRefresh = model.invalidateAndRefresh('home');
    current.complete(_snapshot('home', ['current-peer']));
    final currentReceipt = await currentRefresh;
    old.complete(_snapshot('home', ['old-peer']));
    final oldReceipt = await oldRefresh;

    expect(currentReceipt.applied, isTrue);
    expect(model.isCurrentReceipt(currentReceipt), isTrue);
    expect(oldReceipt.applied, isFalse);
    expect(model.isCurrentReceipt(oldReceipt), isFalse);
    expect(model.peers.single.id, 'current-peer');
  });

  test('safe refresh does not apply a mismatched profile response', () async {
    final previousHandler = FlutterError.onError;
    final reports = <FlutterErrorDetails>[];
    FlutterError.onError = reports.add;
    addTearDown(() => FlutterError.onError = previousHandler);
    final model = RecentPeersModel(
      loader: (_) async => _snapshot('office', ['wrong-peer']),
    );

    final receipt = await model.refreshSafely('home');

    expect(receipt.applied, isFalse);
    expect(model.isCurrentReceipt(receipt), isFalse);
    expect(model.peers, isEmpty);
    expect(reports, hasLength(1));
  });

  test('dispose invalidates an in-flight result without applying or notifying',
      () async {
    final pending = Completer<String>();
    final model = RecentPeersModel(loader: (_) => pending.future);
    var notifications = 0;
    model.addListener(() => notifications += 1);
    final refresh = model.refresh('home');
    expect(notifications, 1);
    expect(model.debugInFlightCount, 1);

    model.dispose();
    pending.complete(_snapshot('home', ['late-peer']));
    final receipt = await refresh;

    expect(receipt.applied, isFalse);
    expect(notifications, 1);
    expect(model.peers, isEmpty);
    expect(model.debugInFlightCount, 0);
  });
}
