import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../l10n/l10n.dart';

/// Asks how long to mute a conversation (W6): 8 hours, 1 week or until the
/// user turns it back on. Returns null when dismissed; "unmute" is offered
/// only when [muted].
Future<MuteDuration?> chooseMuteDuration(
  BuildContext context, {
  bool muted = false,
}) =>
    showModalBottomSheet<MuteDuration>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final l10n = sheetContext.l10n;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (muted)
                ListTile(
                  leading: const Icon(Icons.notifications_active_outlined),
                  title: Text(l10n.chatListUnmute),
                  onTap: () => Navigator.of(sheetContext).pop(MuteDuration.off),
                ),
              ListTile(
                leading: const Icon(Icons.notifications_off_outlined),
                title: Text(l10n.muteEightHours),
                onTap: () =>
                    Navigator.of(sheetContext).pop(MuteDuration.eightHours),
              ),
              ListTile(
                leading: const Icon(Icons.notifications_off_outlined),
                title: Text(l10n.muteOneWeek),
                onTap: () =>
                    Navigator.of(sheetContext).pop(MuteDuration.oneWeek),
              ),
              ListTile(
                leading: const Icon(Icons.notifications_off_outlined),
                title: Text(l10n.muteAlways),
                onTap: () =>
                    Navigator.of(sheetContext).pop(MuteDuration.always),
              ),
            ],
          ),
        );
      },
    );
