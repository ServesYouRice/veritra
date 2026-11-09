import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_state.dart';
import '../../core/profile_photo.dart';
import '../../crypto/profile_record_codec.dart';
import '../../l10n/l10n.dart';
import '../../ui/avatar.dart';
import '../../ui/format.dart';
import '../../ui/photo_avatar.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets/large_title_bar.dart';

/// Picks the bytes of a picture, or null when the person cancels.
typedef PhotoPicker = Future<Uint8List?> Function();

/// The default picker: a file chooser for common picture types.
Future<Uint8List?> pickPhotoFile() async {
  const images = XTypeGroup(
    extensions: <String>['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'],
  );
  final file = await openFile(acceptedTypeGroups: const <XTypeGroup>[images]);
  if (file == null) return null;
  if (await file.length() > profilePhotoMaxSourceBytes) {
    throw const ProfilePhotoException();
  }
  return file.readAsBytes();
}

/// W11: sets a display name and photo, for the signed-in account or for a
/// group. Both are encrypted on this device before anything is uploaded;
/// only people who share a chat with the subject can read them.
class ProfileEditScreen extends StatefulWidget {
  const ProfileEditScreen.account({
    required this.state,
    this.pickPhoto = pickPhotoFile,
    super.key,
  }) : conversationId = null;

  const ProfileEditScreen.group({
    required this.state,
    required String this.conversationId,
    this.pickPhoto = pickPhotoFile,
    super.key,
  });

  final AppState state;

  /// The group being edited, or null for this account.
  final String? conversationId;
  final PhotoPicker pickPhoto;

  bool get isGroup => conversationId != null;

  @override
  State<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends State<ProfileEditScreen> {
  late final TextEditingController _name;
  ProfilePhoto? _photo;
  String? _photoError;
  bool _saving = false;

  String get _kind =>
      widget.isGroup ? profileKindConversation : profileKindAccount;

  int get _maxName =>
      widget.isGroup ? profileConversationNameMax : profileAccountNameMax;

  @override
  void initState() {
    super.initState();
    final service = widget.state.profiles;
    final current = widget.isGroup
        ? service?.conversation(widget.conversationId!)
        : service?.own;
    _name = TextEditingController(text: current?.name ?? '');
    final png = current?.photoPng;
    _photo = png == null ? null : profilePhotoFromPng(png);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String? _nameError() {
    final l10n = context.l10n;
    final text = _name.text.trim();
    if (text.isEmpty) return null;
    if (text.length > _maxName) return l10n.profileNameTooLong(_maxName);
    if (!ProfileRecordCodec.validName(text, kind: _kind)) {
      return l10n.profileNameInvalid;
    }
    return null;
  }

  Future<void> _choose() async {
    try {
      final bytes = await widget.pickPhoto();
      if (bytes == null) return;
      final photo = await prepareProfilePhoto(bytes);
      if (!mounted) return;
      setState(() {
        _photo = photo;
        _photoError = null;
      });
    } on ProfilePhotoException {
      if (!mounted) return;
      setState(() => _photoError = context.l10n.profilePhotoUnusable);
    }
  }

  Future<void> _save() async {
    if (_saving || _nameError() != null) return;
    final state = widget.state;
    final name = _name.text.trim();
    setState(() => _saving = true);
    final bool ok;
    if (widget.isGroup) {
      ok = await state.saveGroupProfile(widget.conversationId!,
          name: name.isEmpty ? null : name, photo: _photo);
    } else {
      ok = await state.saveOwnProfile(
          name: name.isEmpty ? null : name, photo: _photo);
    }
    if (!mounted) return;
    setState(() => _saving = false);
    final messenger = ScaffoldMessenger.of(context);
    if (ok) {
      messenger
          .showSnackBar(SnackBar(content: Text(context.l10n.profileSaved)));
      Navigator.of(context).maybePop();
    } else {
      messenger.showSnackBar(SnackBar(
          content: Text(
              state.errorFor(Ops.profile) ?? context.l10n.profileSaveInvalid)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final seed = widget.isGroup
        ? widget.conversationId!
        : (widget.state.session?.accountId ?? 'unknown');
    final colors = avatarColorsFor(context, seed);
    final initialFallback = Container(
      width: 96,
      height: 96,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors.fill,
        shape: BoxShape.circle,
        border: Border.all(color: colors.ring),
      ),
      child: widget.isGroup
          ? Icon(Icons.group_outlined, size: 40, color: colors.glyph)
          : Text(
              accountInitials(seed, widget.state.session?.username),
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.w600,
                color: colors.glyph,
              ),
            ),
    );
    final nameError = _nameError();
    return Scaffold(
      appBar: LargeTitleBar(
        title: widget.isGroup ? l10n.groupProfileTitle : l10n.profileEditTitle,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          BoneSpacing.gutter,
          BoneSpacing.md,
          BoneSpacing.gutter,
          BoneSpacing.xl,
        ),
        children: <Widget>[
          Center(
            child: _photo == null
                ? ExcludeSemantics(child: initialFallback)
                : PhotoAvatar(
                    png: _photo!.png,
                    radius: 48,
                    fallback: initialFallback,
                  ),
          ),
          const SizedBox(height: BoneSpacing.md),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: BoneSpacing.sm,
            children: <Widget>[
              OutlinedButton.icon(
                key: const Key('profile-photo-choose'),
                onPressed: _saving ? null : _choose,
                icon: const Icon(Icons.photo_outlined),
                label: Text(l10n.profilePhotoChoose),
              ),
              if (_photo != null)
                TextButton(
                  key: const Key('profile-photo-remove'),
                  onPressed:
                      _saving ? null : () => setState(() => _photo = null),
                  child: Text(l10n.profilePhotoRemove),
                ),
            ],
          ),
          if (_photoError != null)
            Padding(
              padding: const EdgeInsets.only(top: BoneSpacing.sm),
              child: Text(
                _photoError!,
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          const SizedBox(height: BoneSpacing.lg),
          TextField(
            key: const Key('profile-name'),
            controller: _name,
            enabled: !_saving,
            maxLength: _maxName,
            textInputAction: TextInputAction.done,
            inputFormatters: <TextInputFormatter>[
              // Control and direction characters never reach the field; the
              // check on save is for whatever a paste still brings.
              FilteringTextInputFormatter.deny(RegExp(
                  '[\\u0000-\\u001f\\u007f-\\u009f\\u200e\\u200f\\u061c\\u202a-\\u202e\\u2066-\\u2069]')),
            ],
            decoration: InputDecoration(
              labelText: widget.isGroup
                  ? l10n.groupProfileNameLabel
                  : l10n.profileDisplayNameLabel,
              hintText: widget.isGroup ? null : l10n.profileDisplayNameHint,
              errorText: nameError,
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: BoneSpacing.sm),
          Text(
            widget.isGroup ? l10n.groupProfileHelp : l10n.profileDisplayHelp,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: BoneSpacing.lg),
          FilledButton(
            key: const Key('profile-save'),
            onPressed: _saving || nameError != null ? null : _save,
            child: _saving
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l10n.profileSave),
          ),
        ],
      ),
    );
  }
}
