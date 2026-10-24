import 'package:flutter/material.dart';

import '../../core/reaction_emoji.dart';
import '../../l10n/l10n.dart';
import '../../ui/tokens.dart';
import 'emoji_data.dart';

/// Asks for one emoji to react with (W6). Returns it, or null when the sheet
/// is dismissed.
///
/// The list is grouped and searchable by Unicode name (English). Typing or
/// pasting any single emoji into the search field offers it directly, so an
/// emoji missing from the list still works.
Future<String?> showEmojiPicker(BuildContext context) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * 0.7,
        child: const EmojiPicker(),
      ),
    );

/// Entries whose name contains every word of [query], in catalog order.
List<EmojiEntry> searchEmoji(String query) {
  final words = query
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .toList(growable: false);
  if (words.isEmpty) return const <EmojiEntry>[];
  return <EmojiEntry>[
    for (final entries in emojiCatalog.values)
      for (final entry in entries)
        if (words.every(entry.name.contains)) entry,
  ];
}

class EmojiPicker extends StatefulWidget {
  const EmojiPicker({super.key});

  @override
  State<EmojiPicker> createState() => _EmojiPickerState();
}

class _EmojiPickerState extends State<EmojiPicker> {
  final _query = TextEditingController();
  EmojiGroup _group = EmojiGroup.smileys;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  static String groupLabel(AppLocalizations l10n, EmojiGroup group) =>
      switch (group) {
        EmojiGroup.smileys => l10n.emojiGroupSmileys,
        EmojiGroup.people => l10n.emojiGroupPeople,
        EmojiGroup.animals => l10n.emojiGroupAnimals,
        EmojiGroup.food => l10n.emojiGroupFood,
        EmojiGroup.travel => l10n.emojiGroupTravel,
        EmojiGroup.activities => l10n.emojiGroupActivities,
        EmojiGroup.objects => l10n.emojiGroupObjects,
        EmojiGroup.symbols => l10n.emojiGroupSymbols,
        EmojiGroup.flags => l10n.emojiGroupFlags,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final query = _query.text.trim();
    final typed = asSingleEmoji(query);
    final searching = query.isNotEmpty && typed == null;
    final entries = searching ? searchEmoji(query) : emojiCatalog[_group]!;
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: BoneSpacing.gutter),
          child: TextField(
            controller: _query,
            onChanged: (_) => setState(() {}),
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: l10n.emojiSearchHint,
            ),
          ),
        ),
        if (typed != null)
          ListTile(
            leading: Text(typed, style: const TextStyle(fontSize: 28)),
            title: Text(l10n.emojiUseTyped(typed)),
            onTap: () => Navigator.of(context).pop(typed),
          )
        else if (!searching)
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                  horizontal: BoneSpacing.gutter, vertical: BoneSpacing.xs),
              children: <Widget>[
                for (final group in EmojiGroup.values)
                  Padding(
                    padding: const EdgeInsets.only(right: BoneSpacing.sm),
                    child: ChoiceChip(
                      label: Text(groupLabel(l10n, group)),
                      selected: group == _group,
                      onSelected: (_) => setState(() => _group = group),
                    ),
                  ),
              ],
            ),
          ),
        if (typed == null)
          Expanded(
            child: entries.isEmpty
                ? Center(
                    child: Text(
                      l10n.emojiNoResults,
                      style: theme.textTheme.bodyMedium,
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.all(BoneSpacing.sm),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: BoneSpacing.minTapTarget,
                    ),
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      return Semantics(
                        label: entry.name,
                        button: true,
                        excludeSemantics: true,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(BoneRadii.md),
                          onTap: () => Navigator.of(context).pop(entry.emoji),
                          child: Center(
                            child: Text(
                              entry.emoji,
                              style: const TextStyle(fontSize: 26),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
      ],
    );
  }
}
