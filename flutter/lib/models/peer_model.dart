import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'platform_model.dart';
// ignore: depend_on_referenced_packages
import 'package:collection/collection.dart';

class Peer {
  final String id;
  String hash; // personal ab hash password
  String password; // shared ab password
  String username; // pc username
  String hostname;
  String platform;
  String alias;
  List<dynamic> tags;
  bool forceAlwaysRelay = false;
  String rdpPort;
  String rdpUsername;
  bool online = false;
  String loginName; //login username
  String device_group_name;
  String note;
  bool? sameServer;

  String getId() {
    if (alias != '') {
      return alias;
    }
    return id;
  }

  Peer.fromJson(Map<String, dynamic> json)
      : id = json['id'] ?? '',
        hash = json['hash'] ?? '',
        password = json['password'] ?? '',
        username = json['username'] ?? '',
        hostname = json['hostname'] ?? '',
        platform = json['platform'] ?? '',
        alias = json['alias'] ?? '',
        tags = json['tags'] ?? [],
        forceAlwaysRelay = json['forceAlwaysRelay'] == 'true',
        rdpPort = json['rdpPort'] ?? '',
        rdpUsername = json['rdpUsername'] ?? '',
        loginName = json['loginName'] ?? '',
        device_group_name = json['device_group_name'] ?? '',
        note = json['note'] is String ? json['note'] : '',
        sameServer = json['same_server'];

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      "id": id,
      "hash": hash,
      "password": password,
      "username": username,
      "hostname": hostname,
      "platform": platform,
      "alias": alias,
      "tags": tags,
      "forceAlwaysRelay": forceAlwaysRelay.toString(),
      "rdpPort": rdpPort,
      "rdpUsername": rdpUsername,
      'loginName': loginName,
      'device_group_name': device_group_name,
      'note': note,
      'same_server': sameServer,
    };
  }

  Map<String, dynamic> toCustomJson({required bool includingHash}) {
    var res = <String, dynamic>{
      "id": id,
      "username": username,
      "hostname": hostname,
      "platform": platform,
      "alias": alias,
      "tags": tags,
    };
    if (includingHash) {
      res['hash'] = hash;
    }
    return res;
  }

  Map<String, dynamic> toGroupCacheJson() {
    return <String, dynamic>{
      "id": id,
      "username": username,
      "hostname": hostname,
      "platform": platform,
      "login_name": loginName,
      "device_group_name": device_group_name,
    };
  }

  Peer({
    required this.id,
    required this.hash,
    required this.password,
    required this.username,
    required this.hostname,
    required this.platform,
    required this.alias,
    required this.tags,
    required this.forceAlwaysRelay,
    required this.rdpPort,
    required this.rdpUsername,
    required this.loginName,
    required this.device_group_name,
    required this.note,
    this.sameServer,
  });

  Peer.loading()
      : this(
          id: '...',
          hash: '',
          password: '',
          username: '...',
          hostname: '...',
          platform: '...',
          alias: '',
          tags: [],
          forceAlwaysRelay: false,
          rdpPort: '',
          rdpUsername: '',
          loginName: '',
          device_group_name: '',
          note: '',
        );
  bool equal(Peer other) {
    return id == other.id &&
        hash == other.hash &&
        password == other.password &&
        username == other.username &&
        hostname == other.hostname &&
        platform == other.platform &&
        alias == other.alias &&
        tags.equals(other.tags) &&
        forceAlwaysRelay == other.forceAlwaysRelay &&
        rdpPort == other.rdpPort &&
        rdpUsername == other.rdpUsername &&
        device_group_name == other.device_group_name &&
        loginName == other.loginName &&
        note == other.note;
  }

  factory Peer.copy(Peer other) {
    final peer = Peer(
        id: other.id,
        hash: other.hash,
        password: other.password,
        username: other.username,
        hostname: other.hostname,
        platform: other.platform,
        alias: other.alias,
        tags: other.tags.toList(),
        forceAlwaysRelay: other.forceAlwaysRelay,
        rdpPort: other.rdpPort,
        rdpUsername: other.rdpUsername,
        loginName: other.loginName,
        device_group_name: other.device_group_name,
        note: other.note,
        sameServer: other.sameServer);
    peer.online = other.online;
    return peer;
  }
}

enum UpdateEvent { online, load }

typedef GetInitPeers = RxList<Peer> Function();
typedef RecentPeersSnapshotLoader = Future<String> Function(String profileId);

class RecentPeersLoadException implements Exception {
  const RecentPeersLoadException(this.message);

  final String message;

  @override
  String toString() => message;
}

void reportRecentPeersLoadFailure() {
  try {
    FlutterError.reportError(FlutterErrorDetails(
      exception: const RecentPeersLoadException(
          'Recent connections could not be refreshed.'),
      library: 'RustDesk recent connections',
    ));
  } catch (_) {
    debugPrint('Recent connections could not be refreshed.');
  }
}

class Peers extends ChangeNotifier {
  final String name;
  final String loadEvent;
  List<Peer> peers = List.empty(growable: true);
  // Part of the peers that are not in the rest peers list.
  // When there're too many peers, we may want to load the front 100 peers first,
  // so we can see peers in UI quickly. `restPeerIds` is the rest peers' ids.
  // And then load all peers later.
  List<String> restPeerIds = List.empty(growable: true);
  final GetInitPeers? getInitPeers;
  final bool listenForLoadEvents;
  UpdateEvent event = UpdateEvent.load;
  static const _cbQueryOnlines = 'callback_query_onlines';

  Peers(
      {required this.name,
      required this.getInitPeers,
      required this.loadEvent,
      this.listenForLoadEvents = true}) {
    peers = getInitPeers?.call() ?? [];
    platformFFI.registerEventHandler(_cbQueryOnlines, name, (evt) async {
      _updateOnlineState(evt);
    });
    if (listenForLoadEvents) {
      platformFFI.registerEventHandler(loadEvent, name, (evt) async {
        _updatePeers(evt);
      });
    }
  }

  @override
  void dispose() {
    platformFFI.unregisterEventHandler(_cbQueryOnlines, name);
    if (listenForLoadEvents) {
      platformFFI.unregisterEventHandler(loadEvent, name);
    }
    super.dispose();
  }

  Peer getByIndex(int index) {
    if (index < peers.length) {
      return peers[index];
    } else {
      return Peer.loading();
    }
  }

  int getPeersCount() {
    return peers.length;
  }

  void _updateOnlineState(Map<String, dynamic> evt) {
    int changedCount = 0;
    evt['onlines'].split(',').forEach((online) {
      for (var i = 0; i < peers.length; i++) {
        if (peers[i].id == online) {
          if (!peers[i].online) {
            changedCount += 1;
            peers[i].online = true;
          }
        }
      }
    });

    evt['offlines'].split(',').forEach((offline) {
      for (var i = 0; i < peers.length; i++) {
        if (peers[i].id == offline) {
          if (peers[i].online) {
            changedCount += 1;
            peers[i].online = false;
          }
        }
      }
    });

    if (changedCount > 0) {
      event = UpdateEvent.online;
      notifyListeners();
    }
  }

  void _updatePeers(Map<String, dynamic> evt) {
    final onlineStates = _getOnlineStates();
    if (getInitPeers != null) {
      peers = getInitPeers?.call() ?? [];
    } else {
      peers = _decodePeers(evt['peers']);
    }

    restPeerIds = [];
    if (evt['ids'] != null) {
      restPeerIds = (evt['ids'] as String).split(',');
    }

    for (var peer in peers) {
      final state = onlineStates[peer.id];
      peer.online = state != null && state != false;
    }
    event = UpdateEvent.load;
    notifyListeners();
  }

  Map<String, bool> _getOnlineStates() {
    var onlineStates = <String, bool>{};
    for (var peer in peers) {
      onlineStates[peer.id] = peer.online;
    }
    return onlineStates;
  }

  List<Peer> _decodePeers(String peersStr) {
    try {
      if (peersStr == "") return [];
      List<dynamic> peers = json.decode(peersStr);
      return peers.map((peer) {
        return Peer.fromJson(peer as Map<String, dynamic>);
      }).toList();
    } catch (e) {
      debugPrint('peers(): $e');
    }
    return [];
  }
}

class RecentPeersModel extends Peers {
  RecentPeersModel({required RecentPeersSnapshotLoader loader})
      : _loader = loader,
        super(
          name: 'recent',
          loadEvent: 'load_recent_peers',
          getInitPeers: null,
          listenForLoadEvents: false,
        );

  final RecentPeersSnapshotLoader _loader;
  int _epoch = 0;
  String? _profileId;
  final Map<String, Future<void>> _inFlight = {};
  bool _disposed = false;

  @visibleForTesting
  int get debugInFlightCount => _inFlight.length;

  Future<void> invalidateAndRefresh(String profileId) {
    if (_disposed) return Future.value();
    _profileId = profileId;
    _epoch += 1;
    peers = [];
    restPeerIds = [];
    event = UpdateEvent.load;
    notifyListeners();
    return _startLoad(profileId, _epoch, preserveOnline: false);
  }

  Future<void> refresh(String profileId) {
    if (_disposed) return Future.value();
    final sameIdentity = _profileId == profileId;
    if (!sameIdentity) {
      return invalidateAndRefresh(profileId);
    }
    return _startLoad(profileId, _epoch, preserveOnline: true);
  }

  Future<void> refreshSafely(String profileId) async {
    try {
      await refresh(profileId);
    } catch (_) {
      if (_disposed) return;
      reportRecentPeersLoadFailure();
    }
  }

  Future<void> _startLoad(String profileId, int epoch,
      {required bool preserveOnline}) {
    final key = '$epoch\u0000$profileId';
    final pending = _inFlight[key];
    if (pending != null) return pending;

    late final Future<void> tracked;
    tracked = _load(profileId, epoch, preserveOnline).whenComplete(() {
      if (identical(_inFlight[key], tracked)) {
        _inFlight.remove(key);
      }
    });
    _inFlight[key] = tracked;
    return tracked;
  }

  Future<void> _load(String profileId, int epoch, bool preserveOnline) async {
    late final String response;
    try {
      response = await _loader(profileId);
    } catch (_) {
      if (_disposed) return;
      rethrow;
    }
    if (_disposed) return;
    final snapshot = _parseRecentPeersSnapshot(response, profileId);
    if (_disposed || _profileId != profileId || _epoch != epoch) return;

    if (preserveOnline) {
      final onlineStates = {for (final peer in peers) peer.id: peer.online};
      for (final peer in snapshot.peers) {
        peer.online = onlineStates[peer.id] ?? false;
      }
    }
    peers = snapshot.peers;
    restPeerIds = snapshot.restPeerIds;
    event = UpdateEvent.load;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch += 1;
    _inFlight.clear();
    super.dispose();
  }
}

class _RecentPeersSnapshot {
  const _RecentPeersSnapshot(this.peers, this.restPeerIds);

  final List<Peer> peers;
  final List<String> restPeerIds;
}

_RecentPeersSnapshot _parseRecentPeersSnapshot(
    String response, String expectedProfileId) {
  try {
    final decoded = jsonDecode(response);
    if (decoded is! Map<String, dynamic> ||
        decoded['ok'] is! bool ||
        decoded['profile_id'] is! String ||
        decoded['peers'] is! List ||
        decoded['ids'] is! List ||
        decoded['error'] is! String) {
      throw const RecentPeersLoadException(
          'Invalid recent connections response.');
    }
    if (decoded['profile_id'] != expectedProfileId) {
      throw const RecentPeersLoadException(
          'Recent connections response did not match the server profile.');
    }
    if (decoded['ok'] != true) {
      final error = decoded['error'] as String;
      if (error.trim().isEmpty) {
        throw const RecentPeersLoadException(
            'Invalid recent connections response.');
      }
      throw RecentPeersLoadException(error);
    }
    if ((decoded['error'] as String).isNotEmpty) {
      throw const RecentPeersLoadException(
          'Invalid recent connections response.');
    }

    final peers = <Peer>[];
    final peerIds = <String>{};
    for (final rawPeer in decoded['peers'] as List) {
      if (rawPeer is! Map<String, dynamic> || !_isValidPeerJson(rawPeer)) {
        throw const RecentPeersLoadException(
            'Invalid recent connections response.');
      }
      final id = rawPeer['id'] as String;
      if (!peerIds.add(id)) {
        throw const RecentPeersLoadException(
            'Invalid recent connections response.');
      }
      peers.add(Peer.fromJson(rawPeer));
    }
    final ids = <String>[];
    final restIds = <String>{};
    for (final id in decoded['ids'] as List) {
      if (id is! String || id.isEmpty || !restIds.add(id)) {
        throw const RecentPeersLoadException(
            'Invalid recent connections response.');
      }
      ids.add(id);
    }
    return _RecentPeersSnapshot(peers, ids);
  } on RecentPeersLoadException {
    rethrow;
  } catch (_) {
    throw const RecentPeersLoadException(
        'Invalid recent connections response.');
  }
}

bool _isValidPeerJson(Map<String, dynamic> peer) {
  final id = peer['id'];
  if (id is! String || id.isEmpty) return false;

  const stringFields = [
    'hash',
    'password',
    'username',
    'hostname',
    'platform',
    'alias',
    'rdpPort',
    'rdpUsername',
    'loginName',
    'device_group_name',
  ];
  for (final field in stringFields) {
    final value = peer[field];
    if (value != null && value is! String) return false;
  }
  final tags = peer['tags'];
  if (tags != null && tags is! List) return false;
  final forceAlwaysRelay = peer['forceAlwaysRelay'];
  if (forceAlwaysRelay != null && forceAlwaysRelay is! String) return false;
  final sameServer = peer['same_server'];
  if (sameServer != null && sameServer is! bool) return false;
  return true;
}
