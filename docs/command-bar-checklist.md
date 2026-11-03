# Command bar manual checklist

The pure parts (word splitting, segment completion, refine text, short addresses, URL shortcuts,
history ranking) are covered by `Packages/NookWeb/Checks/PaletteTextCheck.swift`,
`HistoryIndexCheck.swift` and `Packages/NookSettings/Checks/URLShortcutCheck.swift`. This list covers the view. Run it once with
a plain keyboard layout and once with an input method (for example Japanese Romaji) active: while
the input method is composing, every key below goes to it and the bar does nothing.

## Typing and completion

- [ ] Type `gith`: grey text completes the host only (`github.com`), not a deep page.
- [ ] Return opens exactly the bold and grey text shown.
- [ ] Type `/` after a host: grey text offers the next path segment that most visited pages share.
- [ ] → or Ctrl+E at the end of the field takes the grey text; ⌥→ or ⌥F takes one word of it.
- [ ] The first ⌫ with grey text showing removes only the grey text; Return then opens what is bold.
- [ ] The top row says where Return goes: "this tab" (Cmd+L), "a new tab below “…”", or "the top of Tabs".

## Keys

- [ ] ↑/↓ and Ctrl+N/Ctrl+P move the highlight; the field text never changes.
- [ ] Ctrl+W and ⌥⌫ delete one word back, stopping at the word stops in Settings → General.
- [ ] Ctrl+U clears the field, or drops the highlight when a row is highlighted.
- [ ] ⌥← and ⌥B move the caret back one word.
- [ ] Tab on a highlighted row puts its host and first path segment in the field and searches again.
- [ ] Tab after a site-search keyword (`yt`) with no row highlighted makes the YouTube chip.
- [ ] Ctrl+R enters history mode; Ctrl+R again steps to the next match.
- [ ] ⇧⌫ on a history row forgets it.
- [ ] ⌘↩ opens the target in a background tab and keeps the bar and query; ⇧↩ opens it in split view.
- [ ] Holding ⌘ shows the highlighted row's full address.
- [ ] Esc leaves a scope or chip first, then closes the bar; over a Peek it closes only the bar.

## Scopes and rows

- [ ] `t ` lists tabs grouped by space; ⌫ right after the chip restores `t ` as text.
- [ ] `h ` lists history; `> ` lists actions with their shortcuts.
- [ ] Without a scope: Tabs, History, Page text and Suggestions sections, about 8 rows.
- [ ] Rows show the title over host and last path segments; tabs from another space show its icon.
- [ ] A folder name finds the folder; Return reveals it in the sidebar; Tab browses inside it.
- [ ] `loc` or `127` lists local servers one row per port; `gh owner/repo` opens the repository.
