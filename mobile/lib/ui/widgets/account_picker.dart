import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../format.dart';
import '../../l10n/l10n.dart';

/// A member selected in an [AccountPicker]: the resolved account ID plus a
/// human-readable label (username when known, shortened ID otherwise).
class SelectedAccount {
  const SelectedAccount({required this.id, required this.label});

  final String id;
  final String label;
}

/// Resolves usernames to account IDs so users never have to exchange raw
/// `acct_…` identifiers. The server's metadata search only matches accounts
/// on an exact username (by design, to prevent user enumeration), so this is
/// a lookup field rather than a browse-as-you-type directory. Pasting a raw
/// account ID still works as an advanced fallback.
class AccountPicker extends StatefulWidget {
  const AccountPicker({
    required this.state,
    required this.onChanged,
    this.maxSelection,
    this.label,
    this.suggestions = const <SelectedAccount>[],
    this.onSuggestionPicked,
    super.key,
  });

  final AppState state;
  final ValueChanged<List<SelectedAccount>> onChanged;

  /// Maximum number of members; null means unlimited. When the limit is 1,
  /// picking a new account replaces the previous selection.
  final int? maxSelection;

  /// The field label; defaults to "Username".
  final String? label;

  /// People to offer before anything is typed, such as everyone this device
  /// already shares a chat with (U27). Typing filters them by name or ID; the
  /// exact-username lookup below them still runs for anyone else. Empty keeps
  /// the plain lookup field.
  final List<SelectedAccount> suggestions;

  /// Called after a person picked from [suggestions] was added and
  /// [onChanged] ran, so a one-person picker can go on at once.
  final ValueChanged<SelectedAccount>? onSuggestionPicked;

  @override
  State<AccountPicker> createState() => _AccountPickerState();
}

class _AccountPickerState extends State<AccountPicker> {
  final controller = TextEditingController();
  final selected = <SelectedAccount>[];
  Timer? _debounce;
  int _lookupGeneration = 0;
  List<SelectedAccount> matches = <SelectedAccount>[];
  bool searching = false;
  bool searched = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _lookupGeneration++;
    controller.dispose();
    super.dispose();
  }

  bool get _atLimit =>
      widget.maxSelection != null &&
      widget.maxSelection! > 1 &&
      selected.length >= widget.maxSelection!;

  void _onChanged(String value) {
    _debounce?.cancel();
    // Every edit makes what was asked before it out of date at once, not only
    // when the new text finally gets looked up: an older answer that arrives
    // while the debounce runs is dropped, and the results on screen belong to
    // text that is gone, so they go too.
    final generation = ++_lookupGeneration;
    setState(() {
      matches = <SelectedAccount>[];
      searching = false;
      searched = false;
    });
    _debounce = Timer(
      const Duration(milliseconds: 400),
      () => _lookup(value, generation),
    );
  }

  Future<void> _lookup(String value, int generation) async {
    final query = value.trim();
    if (!mounted || generation != _lookupGeneration) return;
    if (query.isEmpty) {
      setState(() {
        matches = <SelectedAccount>[];
        searching = false;
        searched = false;
      });
      return;
    }
    setState(() => searching = true);
    List<SelectedAccount> found;
    try {
      final results = await widget.state.searchMetadata(query);
      found = results
          .where((result) => result.type == 'account')
          .map((result) => SelectedAccount(id: result.id, label: result.label))
          .toList();
    } catch (_) {
      found = <SelectedAccount>[];
    }
    if (!mounted || generation != _lookupGeneration) {
      return;
    }
    final ownAccountId = widget.state.session?.accountId;
    setState(() {
      matches = found
          .where((account) =>
              account.id != ownAccountId &&
              !selected.any((existing) => existing.id == account.id))
          .toList();
      searching = false;
      searched = true;
    });
  }

  /// The suggestions still open to pick that match what is typed.
  List<SelectedAccount> get _known {
    final query = controller.text.trim().toLowerCase();
    return <SelectedAccount>[
      for (final account in widget.suggestions)
        if (!selected.any((existing) => existing.id == account.id) &&
            (query.isEmpty ||
                account.label.toLowerCase().contains(query) ||
                account.id.toLowerCase().contains(query)))
          account,
    ];
  }

  void _add(SelectedAccount account) {
    final alreadyChosen = selected.any((existing) => existing.id == account.id);
    // The field is off at the limit, but a tap on a tile drawn before it was
    // reached must not add one more.
    if (_atLimit && !alreadyChosen) return;
    // Choosing ends the search: nothing asked before may answer, and a
    // debounce still waiting must not start one.
    _debounce?.cancel();
    _lookupGeneration++;
    setState(() {
      searching = false;
      if (widget.maxSelection == 1) {
        selected.clear();
      }
      if (!selected.any((existing) => existing.id == account.id)) {
        selected.add(account);
      }
      controller.clear();
      matches = <SelectedAccount>[];
      searched = false;
    });
    widget.onChanged(List<SelectedAccount>.unmodifiable(selected));
  }

  void _remove(SelectedAccount account) {
    setState(
        () => selected.removeWhere((existing) => existing.id == account.id));
    widget.onChanged(List<SelectedAccount>.unmodifiable(selected));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rawId = controller.text.trim();
    final known = _known;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (selected.isNotEmpty) ...<Widget>[
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: <Widget>[
              for (final account in selected)
                InputChip(
                  avatar: const Icon(Icons.person_outline, size: 18),
                  label: Text(account.label),
                  onDeleted: () => _remove(account),
                ),
            ],
          ),
          const SizedBox(height: 8),
        ],
        TextField(
          controller: controller,
          enabled: !_atLimit,
          autocorrect: false,
          onChanged: _onChanged,
          decoration: InputDecoration(
            labelText: widget.label ?? context.l10n.connectUsername,
            helperText: context.l10n.accountPickerHelper,
            prefixIcon: const Icon(Icons.person_search_outlined),
            suffixIcon: searching
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : null,
          ),
        ),
        if (known.isNotEmpty) ...<Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child: Text(
              context.l10n.accountPickerKnown,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          for (final account in known)
            ListTile(
              key: ValueKey<String>('known-${account.id}'),
              dense: true,
              leading: const Icon(Icons.person_outline),
              title: Text(account.label),
              subtitle: Text(shortId(account.id)),
              onTap: () {
                _add(account);
                widget.onSuggestionPicked?.call(account);
              },
            ),
        ],
        if (matches.isNotEmpty) ...<Widget>[
          for (final account in matches)
            // Someone already listed above is not listed twice.
            if (!known.any((listed) => listed.id == account.id))
              ListTile(
                dense: true,
                leading: const Icon(Icons.person_outline),
                title: Text(account.label),
                subtitle: Text(shortId(account.id)),
                onTap: () => _add(account),
              ),
        ] else if (searched && !searching && rawId.isNotEmpty && known.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              context.l10n.accountPickerNoMatch,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}
