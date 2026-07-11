import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

abstract interface class ServerProfileApi {
  Future<String> getProfiles();

  Future<String> addProfile(String name, String idServer, String key);

  Future<String> updateProfile(
      String id, String name, String idServer, String key);

  Future<String> removeProfile(String id);

  Future<String> switchProfile(String id);

  Future<String> recoverProfiles();
}

Future<void> refreshRecentPeersTransaction<T>({
  required List<T> peers,
  required List<String> restPeerIds,
  required VoidCallback notify,
  required Future<void> Function() load,
}) async {
  final previousPeers = List<T>.of(peers);
  final previousRestPeerIds = List<String>.of(restPeerIds);
  peers.clear();
  restPeerIds.clear();
  notify();
  try {
    await load();
  } catch (_) {
    peers
      ..clear()
      ..addAll(previousPeers);
    restPeerIds
      ..clear()
      ..addAll(previousRestPeerIds);
    notify();
    rethrow;
  }
}

class ServerProfile {
  const ServerProfile({
    required this.id,
    required this.name,
    required this.idServer,
    required this.key,
  });

  final String id;
  final String name;
  final String idServer;
  final String key;

  factory ServerProfile.fromJson(Map<String, Object?> json) {
    return ServerProfile(
      id: _requiredString(json, 'id'),
      name: _requiredString(json, 'name'),
      idServer: _requiredString(json, 'id_server'),
      key: _requiredString(json, 'key'),
    );
  }
}

class ServerProfilesState {
  static const supportedVersion = 1;

  const ServerProfilesState({
    required this.version,
    required this.activeProfileId,
    required this.profiles,
  });

  final int version;
  final String activeProfileId;
  final List<ServerProfile> profiles;

  ServerProfile get active {
    for (final profile in profiles) {
      if (profile.id == activeProfileId) {
        return profile;
      }
    }
    throw ServerProfileException(
      'Active server profile "$activeProfileId" was not found.',
    );
  }

  factory ServerProfilesState.fromJson(Map<String, Object?> json) {
    final version = json['version'];
    final rawProfiles = json['profiles'];
    if (version is! int ||
        version != supportedVersion ||
        rawProfiles is! List<Object?> ||
        rawProfiles.isEmpty) {
      throw const ServerProfileException('Invalid server profile response.');
    }

    final profiles = <ServerProfile>[];
    final profileIds = <String>{};
    for (final rawProfile in rawProfiles) {
      if (rawProfile is! Map<String, Object?>) {
        throw const ServerProfileException('Invalid server profile response.');
      }
      final profile = ServerProfile.fromJson(rawProfile);
      if (profile.id.isEmpty || !profileIds.add(profile.id)) {
        throw const ServerProfileException('Invalid server profile response.');
      }
      profiles.add(profile);
    }

    final activeProfileId = _requiredString(json, 'active_profile_id');
    if (!profileIds.contains(activeProfileId)) {
      throw const ServerProfileException('Invalid server profile response.');
    }

    return ServerProfilesState(
      version: version,
      activeProfileId: activeProfileId,
      profiles: List.unmodifiable(profiles),
    );
  }
}

class ServerProfileException implements Exception {
  const ServerProfileException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ServerProfileRefreshException extends ServerProfileException {
  const ServerProfileRefreshException()
      : super(
          'Server profile configuration changed, but recent connections could not be refreshed.',
        );
}

abstract class ServerProfileModelBase extends ChangeNotifier {
  List<ServerProfile> get profiles;
  String? get activeProfileId;
  ServerProfile get active;
  bool get loading;
  bool get switching;
  bool get busy;
  String? get error;

  Future<void> add(String name, String idServer, String key);
  Future<void> update(String id, String name, String idServer, String key);
  Future<void> remove(String id);
  Future<void> switchTo(String id);
  Future<void> recover();
}

ServerProfilesState parseServerProfilesResponse(
  String response, {
  Iterable<String> sensitiveValues = const [],
}) {
  Object? decoded;
  try {
    decoded = jsonDecode(response);
  } on FormatException {
    throw const ServerProfileException('Invalid server profile response.');
  }
  if (decoded is! Map<String, Object?>) {
    throw const ServerProfileException('Invalid server profile response.');
  }

  final ok = decoded['ok'];
  final error = decoded['error'];
  if (ok is! bool || error is! String) {
    throw const ServerProfileException('Invalid server profile response.');
  }
  if (!ok) {
    final safeError = _redact(error, sensitiveValues);
    throw ServerProfileException(
      safeError.isEmpty ? 'Server profile operation failed.' : safeError,
    );
  }

  final config = decoded['config'];
  if (config is! Map<String, Object?>) {
    throw const ServerProfileException('Invalid server profile response.');
  }
  return ServerProfilesState.fromJson(config);
}

class ServerProfileModel extends ServerProfileModelBase {
  ServerProfileModel({
    required ServerProfileApi api,
    FutureOr<void> Function()? refreshRecentPeers,
  })  : _api = api,
        _refreshRecentPeers = refreshRecentPeers;

  final ServerProfileApi _api;
  final FutureOr<void> Function()? _refreshRecentPeers;
  ServerProfilesState? _state;
  bool _busy = false;
  bool _loading = false;
  bool _switching = false;
  String? _error;

  ServerProfilesState? get state => _state;
  @override
  List<ServerProfile> get profiles => _state?.profiles ?? const [];
  @override
  String? get activeProfileId => _state?.activeProfileId;
  @override
  ServerProfile get active {
    final state = _state;
    if (state == null) {
      throw const ServerProfileException(
        'Server profiles have not been loaded.',
      );
    }
    return state.active;
  }

  @override
  bool get loading => _loading;
  @override
  bool get switching => _switching;
  @override
  bool get busy => _busy;
  @override
  String? get error => _error;

  Future<void> initialize() => load();

  Future<void> load() => _run(
        request: _api.getProfiles,
        loading: true,
      );

  @override
  Future<void> add(String name, String idServer, String key) => _run(
        request: () => _api.addProfile(name, idServer, key),
        loading: true,
        sensitiveValues: [key],
      );

  @override
  Future<void> update(String id, String name, String idServer, String key) =>
      _run(
        request: () => _api.updateProfile(id, name, idServer, key),
        loading: true,
        sensitiveValues: [key],
      );

  @override
  Future<void> remove(String id) => _run(
        request: () => _api.removeProfile(id),
        loading: true,
        refreshRecentPeers: true,
      );

  @override
  Future<void> switchTo(String id) => _run(
        request: () => _api.switchProfile(id),
        switching: true,
        refreshRecentPeers: true,
      );

  @override
  Future<void> recover() => _run(
        request: _api.recoverProfiles,
        loading: true,
        refreshRecentPeers: true,
      );

  Future<void> _run({
    required Future<String> Function() request,
    bool loading = false,
    bool switching = false,
    bool refreshRecentPeers = false,
    Iterable<String> sensitiveValues = const [],
  }) async {
    if (_busy) {
      throw const ServerProfileException(
        'Another server profile operation is already in progress.',
      );
    }

    _busy = true;
    _loading = loading;
    _switching = switching;
    _error = null;
    notifyListeners();
    try {
      final response = await request();
      final nextState = parseServerProfilesResponse(
        response,
        sensitiveValues: sensitiveValues,
      );
      _state = nextState;
      notifyListeners();
      if (refreshRecentPeers) {
        try {
          await _refreshRecentPeers?.call();
        } catch (_) {
          throw const ServerProfileRefreshException();
        }
      }
    } catch (error) {
      final safeError = _safeException(error, sensitiveValues);
      _error = safeError.message;
      throw safeError;
    } finally {
      _busy = false;
      _loading = false;
      _switching = false;
      notifyListeners();
    }
  }
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw const ServerProfileException('Invalid server profile response.');
  }
  return value;
}

ServerProfileException _safeException(
  Object error,
  Iterable<String> sensitiveValues,
) {
  if (error is ServerProfileRefreshException) {
    return error;
  }
  if (error is ServerProfileException) {
    return ServerProfileException(_redact(error.message, sensitiveValues));
  }
  return const ServerProfileException('Server profile operation failed.');
}

String _redact(String message, Iterable<String> sensitiveValues) {
  var safeMessage = message;
  for (final value in sensitiveValues) {
    if (value.isNotEmpty) {
      safeMessage = safeMessage.replaceAll(value, '<redacted>');
    }
  }
  return safeMessage;
}
