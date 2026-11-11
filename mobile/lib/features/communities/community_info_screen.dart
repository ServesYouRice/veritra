import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/profile_photo.dart';
import '../../l10n/l10n.dart';
import '../../ui/photo_avatar.dart';
import '../../ui/tokens.dart';
import '../../ui/validation.dart';
import '../../ui/widgets/large_title_bar.dart';
import '../../ui/widgets/section_header.dart';
import '../../ui/widgets/tile_group.dart';
import '../settings/profile_edit_screen.dart' show PhotoPicker, pickPhotoFile;

/// C3: a community's icon, its categories and where each channel sits. All of
/// it is in encrypted info records (docs/designs/C3-private-channels-and-info.md);
/// the server sees IDs only. Owners and admins edit the icon, the categories
/// and open channels' places; a private channel's place is in its own record,
/// which its members may edit (D80).
class CommunityInfoScreen extends StatefulWidget {
  const CommunityInfoScreen({
    required this.state,
    required this.community,
    this.pickPhoto = pickPhotoFile,
    super.key,
  });

  final AppState state;
  final Community community;
  final PhotoPicker pickPhoto;

  @override
  State<CommunityInfoScreen> createState() => _CommunityInfoScreenState();
}

class _CommunityInfoScreenState extends State<CommunityInfoScreen> {
  bool _saving = false;
  String? _error;

  AppState get state => widget.state;
  String get _communityId => widget.community.id;

  Future<void> _save(Future<bool> Function() write) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final ok = await write();
    if (!mounted) return;
    setState(() {
      _saving = false;
      _error = ok ? null : context.l10n.communityInfoSaveFailed;
    });
  }

  Future<void> _chooseIcon() async {
    try {
      final bytes = await widget.pickPhoto();
      if (bytes == null || !mounted) return;
      final icon = await prepareProfilePhoto(bytes);
      await _save(() => state.setCommunityIcon(_communityId, icon));
    } on ProfilePhotoException {
      if (mounted) {
        setState(() => _error = context.l10n.profilePhotoUnusable);
      }
    }
  }

  Future<String?> _askName(String title, {String initial = ''}) async {
    final controller = TextEditingController(text: initial);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (context, value, _) {
            final error = displayNameError(value.text, l10n: context.l10n);
            return AlertDialog(
              title: Text(title),
              content: TextField(
                key: const Key('community-category-name'),
                controller: controller,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: context.l10n.communityCategoryName,
                  errorText: value.text.isEmpty ? null : error,
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: Text(context.l10n.commonCancel),
                ),
                FilledButton(
                  onPressed: error == null
                      ? () => Navigator.of(dialogContext).pop(true)
                      : null,
                  child: Text(context.l10n.channelSave),
                ),
              ],
            );
          },
        ),
      );
      return confirmed == true ? controller.text.trim() : null;
    } finally {
      controller.dispose();
    }
  }

  Future<void> _newCategory() async {
    final name = await _askName(context.l10n.communityCategoryNew);
    if (name == null || !mounted) return;
    await _save(() async =>
        await state.createCommunityCategory(_communityId, name) != null);
  }

  Future<void> _renameCategory(String categoryId) async {
    final name = await _askName(context.l10n.communityCategoryRename,
        initial: state.categoryDisplayName(categoryId) ?? '');
    if (name == null || !mounted) return;
    await _save(
        () => state.renameCommunityCategory(_communityId, categoryId, name));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final l10n = context.l10n;
        final admin = state.mayEditCommunityInfo(_communityId, 'community');
        final categories = state.communityCategories(_communityId);
        final icon = state.communityIcon(widget.community);
        final channels =
            (state.channelsByCommunity[_communityId] ?? const <Channel>[])
                .where((c) => c.isRouted)
                .toList();
        const fallback = Icon(Icons.groups_outlined, size: 40);
        String categoryName(String id) =>
            state.categoryDisplayName(id) ?? l10n.communityCategoryPlaceholder;
        return Scaffold(
          appBar: LargeTitleBar(title: l10n.communityInfoTitle),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(
              BoneSpacing.gutter,
              BoneSpacing.sm,
              BoneSpacing.gutter,
              BoneSpacing.xl,
            ),
            children: <Widget>[
              Center(
                child: icon == null
                    ? const ExcludeSemantics(child: fallback)
                    : PhotoAvatar(
                        png: icon.png, radius: 40, fallback: fallback),
              ),
              if (admin) ...<Widget>[
                const SizedBox(height: BoneSpacing.md),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: BoneSpacing.sm,
                  children: <Widget>[
                    OutlinedButton.icon(
                      key: const Key('community-icon-choose'),
                      onPressed: _saving ? null : _chooseIcon,
                      icon: const Icon(Icons.photo_outlined),
                      label: Text(l10n.communityIconChoose),
                    ),
                    if (icon != null)
                      TextButton(
                        key: const Key('community-icon-remove'),
                        onPressed: _saving
                            ? null
                            : () => _save(() =>
                                state.setCommunityIcon(_communityId, null)),
                        child: Text(l10n.communityIconRemove),
                      ),
                  ],
                ),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: BoneSpacing.sm),
                  child: Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              SectionHeader(l10n.communityCategories),
              TileGroup(
                children: <Widget>[
                  for (final id in categories)
                    ListTile(
                      leading: const Icon(Icons.folder_outlined),
                      title: Text(categoryName(id)),
                      trailing: admin
                          ? IconButton(
                              tooltip: l10n.communityCategoryRename,
                              onPressed:
                                  _saving ? null : () => _renameCategory(id),
                              icon: const Icon(Icons.edit_outlined),
                            )
                          : null,
                    ),
                  if (admin)
                    ListTile(
                      key: const Key('community-category-new'),
                      leading: const Icon(Icons.create_new_folder_outlined),
                      title: Text(l10n.communityCategoryNew),
                      enabled: !_saving,
                      onTap: _newCategory,
                    ),
                ],
              ),
              if (categories.isNotEmpty && channels.isNotEmpty) ...<Widget>[
                SectionHeader(l10n.communityChannelPlaces),
                TileGroup(
                  children: <Widget>[
                    for (final channel in channels)
                      ListTile(
                        leading: Icon(channel.kind == 'private'
                            ? Icons.lock_outline
                            : Icons.tag),
                        title: Text(state.channelDisplayName(channel) ??
                            (channel.kind == 'private'
                                ? l10n.channelPrivatePlaceholderName
                                : l10n.channelPlaceholderName)),
                        trailing: DropdownButton<String?>(
                          value: state.channelCategory(channel),
                          onChanged: _saving ||
                                  !(channel.kind == 'private'
                                      ? state.mayEditCommunityInfo(
                                              _communityId, 'channel') &&
                                          state.channelDisplayName(channel) !=
                                              null
                                      : admin)
                              ? null
                              : (id) =>
                                  _save(() => state.placeChannel(channel, id)),
                          items: <DropdownMenuItem<String?>>[
                            DropdownMenuItem<String?>(
                              value: null,
                              child: Text(l10n.communityCategoryNone),
                            ),
                            for (final id in categories)
                              DropdownMenuItem<String?>(
                                value: id,
                                child: Text(categoryName(id)),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
