import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common.dart';
import '../../models/server_profile_model.dart';
import '../../models/state_model.dart';
import 'server_profile_dialog.dart';

typedef ServerProfileToast = void Function(String message);
typedef OpenServerProfileSettings = Future<void> Function(
  BuildContext context,
  ServerProfileModelBase model,
);
typedef ConfirmServerProfileRecovery = void Function(
  Future<void> Function() action,
  String title,
);

class ServerProfileSelector extends StatelessWidget {
  const ServerProfileSelector({
    super.key,
    required this.model,
    this.translator,
    this.showToast,
    this.openSettings,
    this.confirmRecovery,
  });

  final ServerProfileModelBase model;
  final String Function(String value)? translator;
  final ServerProfileToast? showToast;
  final OpenServerProfileSettings? openSettings;
  final ConfirmServerProfileRecovery? confirmRecovery;

  String _tr(String value) => translator?.call(value) ?? translate(value);

  Future<void> _select(BuildContext context, _ProfileMenuChoice choice) async {
    if (choice.settings) {
      final opener = openSettings ?? _openSettings;
      await opener(context, model);
      return;
    }
    if (choice.retry) {
      await _runSafe(model.load);
      return;
    }
    if (choice.recover) {
      final confirm = confirmRecovery;
      if (confirm != null) {
        confirm(_recover, _tr('Confirmation'));
      } else {
        _defaultConfirmRecovery(context, _recover, _tr('Confirmation'));
      }
      return;
    }
    final id = choice.profileId;
    if (id == null || id == model.activeProfileId || model.busy) return;
    try {
      await model.switchTo(id);
    } catch (error) {
      final message = _redactProfileKeys(_safeMessage(error), model.profiles);
      (showToast ?? showToastMessage)(_tr(message));
    }
  }

  Future<void> _runSafe(Future<void> Function() operation) async {
    if (model.busy) return;
    try {
      await operation();
    } catch (_) {
      (showToast ?? showToastMessage)(_tr('Failed'));
    }
  }

  Future<void> _recover() => _runSafe(model.recover);

  void _defaultConfirmRecovery(
    BuildContext context,
    Future<void> Function() action,
    String title,
  ) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text('${_tr('Restore')}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(_tr('Cancel')),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              await action();
            },
            child: Text(_tr('OK')),
          ),
        ],
      ),
    );
  }

  Future<void> _openSettings(
    BuildContext context,
    ServerProfileModelBase model,
  ) {
    return showDialog<void>(
      context: context,
      builder: (_) => ServerProfileDialog(
        model: model,
        translator: translator,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: model,
      builder: (context, _) => Obx(
        () => _buildSelector(context, stateGlobal.svcStatus.value),
      ),
    );
  }

  Widget _buildSelector(BuildContext context, SvcStatus status) {
    final enabled = !model.busy;
    return Builder(
      builder: (anchorContext) => InkWell(
        key: const Key('server-profile-selector'),
        borderRadius: BorderRadius.circular(10),
        onTap: enabled ? () => _showMenu(anchorContext) : null,
        child: Container(
          constraints: const BoxConstraints(minWidth: 190, maxWidth: 260),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: Theme.of(context).colorScheme.outline.withOpacity(0.35),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _StatusDot(status: status),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _activeName(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      _statusText(status),
                      key: const Key('server-profile-status-text'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (model.switching)
                const SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(
                    key: Key('server-profile-switch-progress'),
                    strokeWidth: 2,
                  ),
                )
              else
                const Icon(Icons.arrow_drop_down_rounded, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  String _activeName() {
    if (model.loading) return _tr('Waiting');
    if (model.error != null) return _tr('Error');
    if (model.profiles.isEmpty) return _tr('not_ready_status');
    final activeId = model.activeProfileId;
    for (final profile in model.profiles) {
      if (profile.id == activeId) return profile.name;
    }
    return _tr('ID Server');
  }

  String _statusText(SvcStatus status) {
    switch (status) {
      case SvcStatus.ready:
        return _tr('Ready');
      case SvcStatus.connecting:
        return _tr('connecting_status');
      case SvcStatus.notReady:
        return _tr('not_ready_status');
    }
  }

  Future<void> _showMenu(BuildContext context) async {
    final button = context.findRenderObject();
    final overlay = Navigator.of(context).overlay?.context.findRenderObject();
    if (button is! RenderBox || overlay is! RenderBox) return;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(
          Offset(0, button.size.height),
          ancestor: overlay,
        ),
        button.localToGlobal(
          button.size.bottomRight(Offset.zero),
          ancestor: overlay,
        ),
      ),
      Offset.zero & overlay.size,
    );
    final selected = await showMenu<_ProfileMenuChoice>(
      context: context,
      position: position,
      constraints: const BoxConstraints(minWidth: 220, maxWidth: 320),
      items: [
        for (final profile in model.profiles)
          PopupMenuItem<_ProfileMenuChoice>(
            key: Key('profile-option-${profile.id}'),
            value: _ProfileMenuChoice.profile(profile.id),
            child: Row(
              children: [
                SizedBox(
                  width: 28,
                  child: profile.id == model.activeProfileId
                      ? Icon(
                          Icons.check_rounded,
                          key: Key('profile-current-${profile.id}'),
                          size: 18,
                        )
                      : null,
                ),
                Expanded(
                  child: Text(
                    profile.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        if (model.profiles.isEmpty || model.error != null)
          PopupMenuItem<_ProfileMenuChoice>(
            key: const Key('server-profile-retry'),
            value: const _ProfileMenuChoice.retry(),
            child: Row(
              children: [
                const SizedBox(
                  width: 28,
                  child: Icon(Icons.refresh_rounded, size: 18),
                ),
                Text(_tr('Retry')),
              ],
            ),
          ),
        if (model.profiles.isEmpty || model.error != null)
          PopupMenuItem<_ProfileMenuChoice>(
            key: const Key('server-profile-recover'),
            value: const _ProfileMenuChoice.recover(),
            child: Row(
              children: [
                const SizedBox(
                  width: 28,
                  child: Icon(Icons.restore_rounded, size: 18),
                ),
                Text(_tr('Restore')),
              ],
            ),
          ),
        const PopupMenuDivider(),
        PopupMenuItem<_ProfileMenuChoice>(
          key: const Key('server-profile-settings'),
          value: const _ProfileMenuChoice.settings(),
          child: Row(
            children: [
              const SizedBox(
                width: 28,
                child: Icon(Icons.settings_outlined, size: 18),
              ),
              Text(_tr('Settings')),
            ],
          ),
        ),
      ],
    );
    if (selected != null && context.mounted) {
      await _select(context, selected);
    }
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status});

  final SvcStatus status;

  @override
  Widget build(BuildContext context) {
    final Color color;
    switch (status) {
      case SvcStatus.ready:
        color = const Color.fromARGB(255, 50, 190, 166);
        break;
      case SvcStatus.connecting:
        color = const Color.fromARGB(255, 224, 164, 79);
        break;
      case SvcStatus.notReady:
        color = const Color.fromARGB(255, 224, 79, 95);
        break;
    }
    return Container(
      key: const Key('server-profile-status-dot'),
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _ProfileMenuChoice {
  const _ProfileMenuChoice.profile(this.profileId)
      : settings = false,
        retry = false,
        recover = false;
  const _ProfileMenuChoice.settings()
      : profileId = null,
        settings = true,
        retry = false,
        recover = false;
  const _ProfileMenuChoice.retry()
      : profileId = null,
        settings = false,
        retry = true,
        recover = false;
  const _ProfileMenuChoice.recover()
      : profileId = null,
        settings = false,
        retry = false,
        recover = true;

  final String? profileId;
  final bool settings;
  final bool retry;
  final bool recover;
}

String _safeMessage(Object error) {
  if (error is ServerProfileException) return error.message;
  return 'Failed';
}

String _redactProfileKeys(String message, List<ServerProfile> profiles) {
  var result = message;
  for (final profile in profiles) {
    if (profile.key.isNotEmpty) {
      result = result.replaceAll(profile.key, '<redacted>');
    }
  }
  return result;
}

void showToastMessage(String message) => showToast(message);

class ServerProfileHomeHeader extends StatelessWidget {
  const ServerProfileHomeHeader({
    super.key,
    required this.connectionCard,
    required this.selector,
  });

  static const double breakpoint = 650;

  final Widget connectionCard;
  final Widget selector;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < breakpoint) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(alignment: Alignment.centerRight, child: selector),
              const SizedBox(height: 8),
              Align(alignment: Alignment.centerLeft, child: connectionCard),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            connectionCard,
            const Spacer(),
            selector,
            const SizedBox(width: 12),
          ],
        );
      },
    );
  }
}
