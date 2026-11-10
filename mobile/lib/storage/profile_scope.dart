import 'dart:io';

// B7 account switcher: which names belong to which local profile.
//
// The primary profile keeps every name it has today, byte for byte: the empty
// namespace in release builds (`<support>/`, `veritra.database_key.v1`) and
// `demo` or `demo-<profile>` in demo builds. Any other slot gets its own
// names, so two slots never share a file or a key.

/// The profile one runtime uses. [primaryNamespace] is fixed by the entry
/// point; [namespace] is the slot being opened.
class ProfileScope {
  const ProfileScope({this.namespace = '', this.primaryNamespace = ''});

  final String namespace;
  final String primaryNamespace;

  bool get isPrimary => namespace == primaryNamespace;

  ProfileScope forNamespace(String other) =>
      ProfileScope(namespace: other, primaryNamespace: primaryNamespace);

  /// A global setting key of the old layout (`veritra.<name>`); the primary
  /// slot keeps it, others get `veritra.<namespace>.<name>`.
  String secureKey(String name) =>
      isPrimary ? 'veritra.$name' : 'veritra.$namespace.$name';

  /// The database key name, as SecureLocalStore has always built it.
  String get databaseKey => namespace.isEmpty
      ? 'veritra.database_key.v1'
      : 'veritra.$namespace.database_key.v1';

  String get legacyRecordKey => namespace.isEmpty
      ? 'veritra.account_state.v2'
      : 'veritra.$namespace.account_state.v2';

  /// This slot's folder under the application support directory: the
  /// directory itself for the empty namespace, else `profiles/<namespace>`.
  Directory directoryIn(Directory support) => namespace.isEmpty
      ? support
      : Directory('${support.path}${Platform.pathSeparator}profiles'
          '${Platform.pathSeparator}$namespace');

  /// A working-file root for this slot under [support]. The primary slot
  /// keeps the shared root it uses today; others get their own folder, so
  /// one slot's partial recovery file is never picked up by another.
  Directory workingDirectoryIn(Directory support) =>
      isPrimary ? support : directoryIn(support);

  /// The opened-files subfolder of the shared temporary folder.
  String get openedFilesFolder => isPrimary ? 'primary' : namespace;

  /// The scope of pasted images and voice recordings.
  String get pasteScope => isPrimary
      ? (primaryNamespace.isEmpty ? 'default' : primaryNamespace)
      : namespace;
}
