import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../common.dart';
import '../../common/widgets/dialog.dart';
import '../../models/platform_model.dart';
import '../../models/server_profile_model.dart';

typedef DeleteServerProfileConfirm = void Function(
  Future<void> Function() action,
  String title,
);

typedef TestServerProfileServer = Future<String> Function(String server);

class ServerProfileDialog extends StatefulWidget {
  const ServerProfileDialog({
    super.key,
    required this.model,
    this.testServer,
    this.confirmDelete,
    this.translator,
  });

  final ServerProfileModelBase model;
  final TestServerProfileServer? testServer;
  final DeleteServerProfileConfirm? confirmDelete;
  final String Function(String value)? translator;

  @override
  State<ServerProfileDialog> createState() => _ServerProfileDialogState();
}

class _ServerProfileDialogState extends State<ServerProfileDialog> {
  ServerProfile? _editingProfile;
  bool _adding = false;
  bool _localBusy = false;
  String? _operationError;
  final _editorKey = GlobalKey<_ServerProfileEditorState>();

  bool get _busy => widget.model.busy || _localBusy;
  String _tr(String value) =>
      widget.translator?.call(value) ?? translate(value);

  void _openEditor([ServerProfile? profile]) {
    if (_busy) return;
    setState(() {
      _editingProfile = profile;
      _adding = profile == null;
      _operationError = null;
    });
  }

  void _closeEditor() {
    if (_busy) return;
    setState(() {
      _editingProfile = null;
      _adding = false;
      _operationError = null;
    });
  }

  Future<void> _runOperation(
    Future<void> Function() operation, {
    Iterable<String> sensitiveValues = const [],
    bool closeEditor = false,
  }) async {
    if (_busy || !mounted) return;
    setState(() {
      _localBusy = true;
      _operationError = null;
    });
    try {
      await operation();
      if (!mounted) return;
      setState(() {
        if (closeEditor) {
          _editingProfile = null;
          _adding = false;
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _operationError = _tr(_safeError(error, sensitiveValues));
      });
    } finally {
      if (mounted) {
        setState(() => _localBusy = false);
      }
    }
  }

  void _delete(ServerProfile profile) {
    if (_busy) return;
    final confirm = widget.confirmDelete ?? _defaultConfirmDelete;
    confirm(
      () => _runOperation(() => widget.model.remove(profile.id)),
      _tr('Delete'),
    );
  }

  void _defaultConfirmDelete(
    Future<void> Function() action,
    String title,
  ) {
    deleteConfirmDialog(action, title);
  }

  Future<String> _testServer(String server) async {
    final custom = widget.testServer;
    if (custom != null) return custom(server);
    final result = await bind.mainTestIfValidServer(
      server: server,
      testWithProxy: true,
    );
    return result.isEmpty ? 'Successful' : result;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.model,
      builder: (context, _) {
        final editor = _adding || _editingProfile != null;
        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): () {
              if (editor && !_busy) _closeEditor();
            },
            const SingleActivator(LogicalKeyboardKey.enter): () {
              if (editor && !_busy) _editorKey.currentState?._save();
            },
          },
          child: FocusTraversalGroup(
            child: AlertDialog(
              title: Row(
                children: [
                  Expanded(
                    child: Text('${_tr('ID Server')} ${_tr('Settings')}'),
                  ),
                  IconButton(
                    key: const Key('add-profile'),
                    tooltip: _tr('Add'),
                    onPressed: _busy || editor ? null : _openEditor,
                    icon: const Icon(Icons.add_rounded),
                  ),
                ],
              ),
              content: SizedBox(
                width: 560,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_operationError != null)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          _operationError!,
                          key: const Key('profile-error'),
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error),
                        ),
                      ),
                    if (_operationError != null) const SizedBox(height: 8),
                    if (editor)
                      _ServerProfileEditor(
                        key: _editorKey,
                        profile: _editingProfile,
                        profiles: widget.model.profiles,
                        busy: _busy,
                        translator: _tr,
                        testServer: _testServer,
                        onCancel: _closeEditor,
                        onSave: (name, idServer, key) => _runOperation(
                          () {
                            final profile = _editingProfile;
                            return profile == null
                                ? widget.model.add(name, idServer, key)
                                : widget.model.update(
                                    profile.id,
                                    name,
                                    idServer,
                                    key,
                                  );
                          },
                          sensitiveValues: [key],
                          closeEditor: true,
                        ),
                      )
                    else
                      _ProfileList(
                        profiles: widget.model.profiles,
                        activeProfileId: widget.model.activeProfileId,
                        busy: _busy,
                        translator: _tr,
                        onEdit: _openEditor,
                        onDelete: _delete,
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ProfileList extends StatelessWidget {
  const _ProfileList({
    required this.profiles,
    required this.activeProfileId,
    required this.busy,
    required this.translator,
    required this.onEdit,
    required this.onDelete,
  });

  final List<ServerProfile> profiles;
  final String? activeProfileId;
  final bool busy;
  final String Function(String value) translator;
  final ValueChanged<ServerProfile> onEdit;
  final ValueChanged<ServerProfile> onDelete;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 320,
      child: ListView.separated(
        itemCount: profiles.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final profile = profiles[index];
          final active = profile.id == activeProfileId;
          return ListTile(
            leading: active
                ? Icon(
                    Icons.check_circle_rounded,
                    key: Key('active-${profile.id}'),
                  )
                : const Icon(Icons.dns_outlined),
            title: Text(profile.name),
            subtitle: Text(profile.idServer),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: Key('edit-${profile.id}'),
                  tooltip: translator('Edit'),
                  onPressed: busy ? null : () => onEdit(profile),
                  icon: const Icon(Icons.edit_outlined),
                ),
                if (!active)
                  IconButton(
                    key: Key('delete-${profile.id}'),
                    tooltip: translator('Delete'),
                    onPressed: busy ? null : () => onDelete(profile),
                    icon: const Icon(Icons.delete_outline_rounded),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ServerProfileEditor extends StatefulWidget {
  const _ServerProfileEditor({
    super.key,
    required this.profile,
    required this.profiles,
    required this.busy,
    required this.translator,
    required this.testServer,
    required this.onCancel,
    required this.onSave,
  });

  final ServerProfile? profile;
  final List<ServerProfile> profiles;
  final bool busy;
  final String Function(String value) translator;
  final TestServerProfileServer testServer;
  final VoidCallback onCancel;
  final Future<void> Function(String name, String idServer, String key) onSave;

  @override
  State<_ServerProfileEditor> createState() => _ServerProfileEditorState();
}

class _ServerProfileEditorState extends State<_ServerProfileEditor> {
  late final TextEditingController _nameController;
  late final TextEditingController _idServerController;
  late final TextEditingController _keyController;
  String? _nameError;
  String? _idServerError;
  String? _testResult;
  bool _testing = false;
  int _testRequest = 0;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.profile?.name ?? '');
    _idServerController =
        TextEditingController(text: widget.profile?.idServer ?? '');
    _keyController = TextEditingController(text: widget.profile?.key ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _idServerController.dispose();
    _keyController.dispose();
    super.dispose();
  }

  bool _validate(String name, String idServer) {
    final duplicate = widget.profiles.any(
      (profile) =>
          profile.id != widget.profile?.id &&
          profile.name.trim().toLowerCase() == name.toLowerCase(),
    );
    setState(() {
      _nameError = name.isEmpty
          ? '${widget.translator('Name')}: ${widget.translator('Empty')}'
          : duplicate
              ? '${widget.translator('Name')}: '
                  '${widget.translator('Already exists')}'
              : null;
      _idServerError = idServer.isEmpty
          ? '${widget.translator('ID Server')}: ${widget.translator('Empty')}'
          : null;
    });
    return _nameError == null && _idServerError == null;
  }

  Future<void> _save() async {
    if (widget.busy || _testing) return;
    final name = _nameController.text.trim();
    final idServer = _idServerController.text.trim();
    final key = _keyController.text.trim();
    if (!_validate(name, idServer)) return;
    await widget.onSave(name, idServer, key);
  }

  Future<void> _test() async {
    if (widget.busy || _testing) return;
    final server = _idServerController.text.trim();
    if (server.isEmpty) {
      setState(() {
        _idServerError =
            '${widget.translator('ID Server')}: ${widget.translator('Empty')}';
      });
      return;
    }
    final request = ++_testRequest;
    setState(() {
      _testing = true;
      _idServerError = null;
      _testResult = null;
    });
    try {
      final result = await widget.testServer(server);
      if (mounted &&
          request == _testRequest &&
          _idServerController.text.trim() == server) {
        setState(() {
          _testResult = widget.translator(
            result.isEmpty ? 'Successful' : result,
          );
        });
      }
    } catch (_) {
      if (mounted &&
          request == _testRequest &&
          _idServerController.text.trim() == server) {
        setState(() => _testResult = widget.translator('Failed'));
      }
    } finally {
      if (mounted && request == _testRequest) {
        setState(() => _testing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final disabled = widget.busy || _testing;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          key: const Key('profile-name'),
          controller: _nameController,
          autofocus: true,
          enabled: !widget.busy,
          decoration: InputDecoration(
            labelText: widget.translator('Name'),
            errorText: _nameError,
          ),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                key: const Key('profile-id-server'),
                controller: _idServerController,
                enabled: !widget.busy,
                onChanged: (_) {
                  setState(() {
                    _testRequest += 1;
                    _testResult = null;
                    _testing = false;
                  });
                },
                decoration: InputDecoration(
                  labelText: widget.translator('ID Server'),
                  errorText: _idServerError,
                ),
              ),
            ),
            IconButton(
              key: const Key('test-profile-server'),
              tooltip: widget.translator('Test'),
              onPressed: disabled ? null : _test,
              icon: _testing
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.network_check_rounded),
            ),
          ],
        ),
        TextField(
          key: const Key('profile-key'),
          controller: _keyController,
          enabled: !widget.busy,
          obscureText: true,
          decoration: InputDecoration(labelText: widget.translator('Key')),
        ),
        if (_testResult != null)
          Align(
            alignment: Alignment.centerLeft,
            child: Text(_testResult!, key: const Key('server-test-result')),
          ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            OutlinedButton(
              onPressed: disabled ? null : widget.onCancel,
              child: Text(widget.translator('Cancel')),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              key: const Key('save-profile'),
              style: ElevatedButton.styleFrom(elevation: 0),
              onPressed: disabled ? null : _save,
              child: Text(widget.translator('OK')),
            ),
          ],
        ),
      ],
    );
  }
}

String _safeError(Object error, Iterable<String> sensitiveValues) {
  var message = error is ServerProfileException ? error.message : 'Failed';
  for (final value in sensitiveValues) {
    if (value.isNotEmpty) message = message.replaceAll(value, '<redacted>');
  }
  return message;
}
