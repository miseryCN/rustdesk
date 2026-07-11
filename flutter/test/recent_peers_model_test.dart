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

  test('I/O and parse failures preserve the previous snapshot and throw',
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
      final model = RecentPeersModel(loader: (_) async => response)
        ..peers = [Peer.loading()]
        ..restPeerIds = ['rest'];

      await expectLater(
        model.refresh('home'),
        throwsA(isA<RecentPeersLoadException>()),
      );
      expect(model.peers.single.id, '...');
      expect(model.restPeerIds, ['rest']);
    }
  });

  test('a mismatched profile response is rejected without mutation', () async {
    final model = RecentPeersModel(
      loader: (_) async => _snapshot('other', ['wrong-peer']),
    )..peers = [Peer.loading()];

    await expectLater(
      model.refresh('home'),
      throwsA(isA<RecentPeersLoadException>()),
    );
    expect(model.peers.single.id, '...');
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
      final model = RecentPeersModel(loader: (_) async => jsonEncode(value))
        ..peers = [Peer.loading()]
        ..restPeerIds = ['previous'];

      await expectLater(
        model.refresh('home'),
        throwsA(isA<RecentPeersLoadException>()),
      );
      expect(model.peers.single.id, '...');
      expect(model.restPeerIds, ['previous']);
    }
  });

  test('failed snapshots require a nonempty error and never apply payload',
      () async {
    for (final error in ['', '   ']) {
      final model = RecentPeersModel(
        loader: (_) async => jsonEncode({
          'ok': false,
          'profile_id': 'home',
          'peers': [
            {'id': 'must-not-apply', 'platform': 'Linux'}
          ],
          'ids': ['must-not-apply'],
          'error': error,
        }),
      )..peers = [Peer.loading()];

      await expectLater(
        model.refresh('home'),
        throwsA(isA<RecentPeersLoadException>()),
      );
      expect(model.peers.single.id, '...');
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

    await model.refreshSafely('home');

    expect(reports, hasLength(1));
    expect(reports.single.exceptionAsString(), isNot(contains(secret)));
    expect(reports.single.exceptionAsString().toLowerCase(),
        contains('recent connections'));
  });

  test('dispose invalidates an in-flight result without applying or notifying',
      () async {
    final pending = Completer<String>();
    final model = RecentPeersModel(loader: (_) => pending.future);
    var notifications = 0;
    model.addListener(() => notifications += 1);
    final refresh = model.refresh('home');
    expect(model.debugInFlightCount, 1);

    model.dispose();
    pending.complete(_snapshot('home', ['late-peer']));
    await refresh;

    expect(notifications, 0);
    expect(model.peers, isEmpty);
    expect(model.debugInFlightCount, 0);
  });
}
