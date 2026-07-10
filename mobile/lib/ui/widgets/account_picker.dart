import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../format.dart';

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
    this.label = 'Username',
    super.key,
  });

  final AppState state;
  final ValueChanged<List<SelectedAccount>> onChanged;

  /// Maximum number of members; null means unlimited. When the limit is 1,
  /// picking a new account replaces the previous selection.
  final int? maxSelection;
  final String label;

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
    controller.dispose();
    super.dispose();
  }

  static final _accountIdPattern = RegExp(r'^acct_[0-9a-fA-F]{8,}$');

  bool get _atLimit =>
      widget.maxSelection != null &&
      widget.maxSelection! > 1 &&
      selected.length >= widget.maxSelection!;

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => _lookup(value));
  }

  Future<void> _lookup(String value) async {
    final query = value.trim();
    final generation = ++_lookupGeneration;
    if (query.isEmpty || _accountIdPattern.hasMatch(query)) {
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

  void _add(SelectedAccount account) {
    setState(() {
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
    final rawIdAddable = _accountIdPattern.hasMatch(rawId) &&
        !selected.any((existing) => existing.id == rawId);
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
            labelText: widget.label,
            helperText: 'Exact username, or paste an account ID (acct_…).',
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
        if (rawIdAddable)
          ListTile(
            dense: true,
            leading: const Icon(Icons.alternate_email),
            title: Text('Add by ID ${shortId(rawId)}'),
            onTap: () =>
                _add(SelectedAccount(id: rawId, label: shortId(rawId))),
          )
        else if (matches.isNotEmpty)
          for (final account in matches)
            ListTile(
              dense: true,
              leading: const Icon(Icons.person_outline),
              title: Text(account.label),
              subtitle: Text(shortId(account.id)),
              onTap: () => _add(account),
            )
        else if (searched && !searching && rawId.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'No account found with that exact username.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}
