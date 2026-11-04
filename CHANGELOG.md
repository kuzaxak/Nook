# Changelog

## Unreleased

### Fixed

- Cmd+W closes the tab instead of the window on Russian and other non-Latin keyboard layouts, and in any window with a tab; it closes the command bar when that is open, a held Cmd+W stops at the empty window, and the File menu lists Close Tab and Close Window
- Moving a space off a profile no other space uses no longer forces deleting it: Move and Keep Profile leaves it in Settings → Profiles with its logins, cookies and history, ready for a space to use again
- A link opened in the background (Command-click, middle click, Open Link in New Tab) loads at once and fills in its title and icon, as in Arc, instead of waiting until you select it

## 1.5.2

Links from other apps can open in the current space, as in Arc, and ClickUp lists scroll smoothly.

### Added

- Links from other apps can open in the current space instead of a mini window: Settings → Air Traffic Control, as in Arc

### Fixed

- ClickUp lists scroll smoothly: Nook rewrites one ClickUp chat style that made WebKit restyle the whole page for every new row

## 1.5.1

One-time codes from Pawl Vault, an offer to become the default browser, segment-by-segment address completion, editable word stops, and fixes for Peek, the command bar and deleted profiles.

### Added

- Pawl Vault one-time codes: click a verification-code field (or press ↓ in it) to pick an account with a one-time code, and Nook fills the current code, one digit per box when the site splits it; the form is never submitted and codes are never kept
- Default browser: Settings → General shows whether Nook is your default browser and makes it one with a click; Nook offers it at launch until you agree, and asks again 30 days after Not Now

### Changed

- The command bar's top row says where Return opens: this tab, a new tab below the named one, or the top of Tabs
- Word stops can be changed in Settings → General; history search splits words at the same characters as ⌥→ and Control-W, so `_` now stays inside a word
- The command bar's grey completion finishes only the host or path segment you are typing, as in Firefox; Return opens exactly the bold and grey text, typing `/` offers the next segment, ⌫ removes the grey text first, and deeper pages stay in the list

### Fixed

- Deleting a profile deletes its history and its command bar entries too
- Cmd+T opens the command bar over a Peek, as in Arc
- "What's new in Nook" opens this fork's release notes instead of upstream's

## 1.5.0

The first release of this fork: it builds for Intel and Apple silicon, updates from its own releases, and works more like Arc.

### Added

- Pawl Vault passwords and passkeys (Settings → Privacy → Passwords, off by default): pick an account under a login field, save a new password after signing in, sign in and register with passkeys; Nook checks the vault's code signature, keeps no credentials, and asks again only for saves or after 15 minutes
- Profiles pane, as in Arc (Settings → Profiles): add, rename and delete profiles; each sets its search engine, its download location (Downloads, a chosen folder, or ask every time starting where the last file went) and clears its website data
- Kagi Session Link: paste it in Settings → General and Kagi searches are signed in from every space; the token stays in the Keychain and out of history and tabs; Settings links to Kagi's page that shows it
- Search suggestions from Kagi when Kagi is the search engine
- Peek, as in Arc: links a page opens in a new tab and Shift-clicked links open over the page with back, forward, reload and Copy URL, and Close, Open as Tab and Open in Split View beside it; each tab keeps its own Peek and shows its icon in the sidebar (Settings → General → Peek)
- Split view, as in Arc: each pane has its own toolbar above the page; the split row has one menu for the pair; drop a dragged tab on the left or right half of the page to split
- Developer Mode, as in Arc: Ctrl+D turns it on for the current site; its bar replaces the toolbar, and its tools work from the bar with shortcuts (⌥⌘N Network, ⌥⌘G Performance, ⇧⌘2 Copy Screenshot, ⌥⌘P Portrait, ⌥⌘J Console); the lock opens Site Controls
- Cmd+Shift+D moves the address and navigation buttons between the sidebar and a toolbar above the page
- History index for the command bar: every visited page stays findable, ranked by frecency (Settings → Privacy → History); secret and tracking parameters (token, code, state, session, utm_*, fbclid, gclid) are dropped
- Command bar keys from zsh and fish: → or Ctrl+E takes the grey completion, ⌥→ takes one word, Ctrl+W and ⌥⌫ delete a word, Ctrl+U clears, Ctrl+N/P move
- Command bar: arrows no longer rewrite what you typed; Tab on a row narrows the field to its site; ⌘↩ opens in the background and keeps the bar open; ⇧↩ opens in split view
- Command bar rows show the title over a short address; hold ⌘ for the full one
- Command bar finds sidebar folders and renamed pinned links by word; Tab on a folder searches inside it, Return shows it in the sidebar
- Command bar scopes: `t ` lists tabs by space, `h ` or Ctrl+R lists history, `> ` lists actions; commands such as Copy Current URL, Pin to Space or Move to Space run from the bar with their shortcuts shown
- Command bar developer shortcuts: `loc` or `127` lists local servers one row per port; keywords such as `gh owner/repo` open their address (Settings → General → URL Shortcuts)
- New bindable actions: Pin to Space, Add to Favorites, Add to Folder, Move to Space, Rename Tab, Translate Page, Toggle Extension Library, Manage Extensions, Toggle Dark Mode, Toggle Developer Mode for Site
- Normal tabs not seen for 3 days are archived to Reopen Closed Tab (12 hours to 30 days in Settings → General → Tabs)
- Favorites are shared by spaces that use the same profile; opening one keeps you in the current space
- The space switcher shows each space's icon or initial instead of dots; choose the icon in Settings → Spaces
- Control-Tab shows up to 20 recent tabs in rows, with each tab's Peek; arrows, Ctrl+F/B/N/P and Return work while it is open
- Copy URL buttons in the sidebar, the toolbar and Peek, with ⇧⌘C in their tooltips

### Changed

- Universal build for Apple silicon and Intel, with its own bundle id
- Updates come from this fork's GitHub releases, signed with the fork's key; a version tag builds, signs with Developer ID, notarizes and publishes the release
- New tabs open ungrouped, below the selected tab's folder (Settings → General → Tabs); tabs opened from a pinned tab, a favorite or a folder land in Tabs; a run of background links keeps click order
- Option to stop nesting link tabs under their opener; Back still returns to the opener
- Duplicate Tab keeps the copy next to the original, in Pinned, Favorites or the same folder
- Tabs inside folders are bookmarks: closing one ends its page and keeps it, as a pinned tab does; Cmd+D bookmarks a tab or turns a bookmark back into a normal tab
- Rename as in Arc: double-click a tab or folder; the name starts selected, Enter or clicking away saves, Esc cancels
- Long tab and folder names fade at the end and show in full on hover; denser tab rows; the sidebar keeps the selected tab in view
- The command bar has a soft glow around it and gives the keyboard back to the page when it closes
- Toolbar text follows the page's colour, so titles stay readable on dark pages
- Settings: footers read from the leading edge, the update toggles work, clearer AI, history and shortcut rows, visible Kagi and URL Shortcut fields
- An empty Favorites area is one row tall

### Fixed

- The passkey sheet no longer takes the Return that submitted a sign-up form as Continue
- The quit confirmation no longer opens behind Settings
- The toolbar's Copy URL button stays under the pointer
- The iOS target builds again

## 1.4.0

### Added

- Space themes with colors, texture and light or dark
- Space icons and emoji
- Library: swipe past the first space
- Control-Tab switches between recent tabs
- Download history and previews
- Tidy Downloads
- Link previews on Shift-hover
- Boosts
- Portrait capture
- Developer Mode per site

### Changed

- Sidebar snaps to its default width, drag to hide
- Address bar edits in place
- Split view panes resize
- Tidier tab titles
- Pages scroll at 120 Hz
- Smoother space switching

### Fixed

- Microphone and camera for websites
- Bugs

### Thanks

- @Fenrur, @AbdulRehman-18, @autaut03, @QusaiiSaleem

## 1.3.0

### Added

- Profiles: spaces can share logins
- Ctrl+1 to 9 switch spaces, new Spaces menu
- Fuller page context menu
- Arc import keeps folders, order, favorites, colors and extensions

### Changed

- Next and Previous Space on Cmd+Opt+arrows
- Cleaner Shortcuts settings
- Runs on macOS 15.5 again

### Fixed

- MCP tools with OpenAI-compatible providers
- Bugs

### Thanks

- @zannagh, @QusaiiSaleem, @Fenrur, @sean0407

## 1.2.4

### Added

- Reddit feeds sort by Hot

### Fixed

- Bitwarden popup not opening
- Bugs

## 1.2.3

### Added

- Pull Requests live folder for GitHub
- Pull request card on GitHub favorites
- Seek bar and time on the PiP player

### Changed

- Command bar: top row is what Return does, better matching
- Air Traffic Control rules cover subdomains
- Floating video remembers its size and place
- Pages ask before opening another app

### Fixed

- PiP controls not showing until clicked
- Outside links to a routed site opening in the mini window
- Bugs

## 1.2.2

### Changed

- Faster Launch (up to 3x faster in testing)
- Background tabs use less memory
- Escape closes Peek
- Performance pass: memory, CPU and energy measured against other browsers

### Fixed

- Escape leaving full screen
- High CPU on some sites
- Pinned tab reset arrow moving on hover
- Bugs

## 1.2.1

### Added

- Return to Tab button on PiP and the media bar

### Changed

- Removed LiquidGlass styling. It did not match our calm browser philosophy.
- Improved Spaces switch speed and loading logic.
- Settings sidebar redesigned
- YouTube and Social Media merged into Tweaks

### Fixed

- Favicons not updating when a site changes its icon
- Crash when swiping to a space with a split view
- Bugs

## 1.2.0

### Added

- Links skip redirect pages
- Ad-blocked pages tell you they are blocked and allow you to access anyway
- Going back on a linked tab returns you to the previous tab
- Dragging PiP video into sidebar docks it

### Changed

- Liquid Glass styling
- PiP controls moved to page menu
- Sleeping tabs keep history

### Fixed

- YouTube detecting ad blocker
- X hiding posts with videos
- Password managers not working in Peek and mini
- Bugs

## 1.1.1

### Added

- Ask Nook, the AI chat in the sidebar, can run on Apple Intelligence on your Mac with no API key. It becomes the default when no other provider is set up. It answers questions about the page
- Links you open from a tab now nest under it, and new tabs open right below the tab you're on
- Back, forward and reload moved up beside the window buttons
- Liquid Glass throughout the sidebar, History and Downloads, Peek and Ask Nook
- PDF controls to zoom, print, save or open the file in Preview. Cmd+P prints any page, and a page's own print button works now
- Settings > Appearance > Hide border lets the page sit flush against the window (#370)

### Changed

- Peek opens on its own only for links from favorites and pinned tabs to another site. Option-click still peeks any link. On a regular tab, a link that would open a new window opens a new tab
- Peek is a little smaller, with close, split and new tab in one glass group on its left
- Peek and the sign-in window run like a normal tab now, with the full ad blocker, site tweaks, downloads and page dialogs
- Sidebar PiP only picks up a playing landscape video with sound, which keeps Shorts, reels and feed autoplay out. The player's title and progress bars no longer show in the sidebar
- The sidebar has a minimum width so back, forward and reload always fit
- Ask Nook shows its reply as it's written

### Fixed

- Videos on YouTube, Facebook and Instagram flashed black for single frames
- The top of a web page dragged the window, and text there couldn't be selected
- The window buttons now hide with the sidebar and stay hidden after leaving full screen
- Peek could draw the page cut off at the top and left
- Email, phone and other app links did nothing. They open in their app now
- The Settings button in Ask Nook and every Space Settings shortcut and menu item did nothing
- Gemini 3 failed after its first tool call, and GPT-5 and o-series models failed through the OpenAI-compatible provider
- Save Image could send the site's cookies along to wherever the image redirected
- In History, the time filter never refreshed and deleting a row lost your place. History older than 100 days is now cleared in every space; before, only the space Nook opened in was cleared
- In Downloads, Move to Trash opened Finder, and the download indicator could show the wrong download

## 1.1.0

Nook is being revived!

The bundle identifier has changed, so the updater in 1.0.x cannot install the latest version. Download the DMG and replace Nook in Applications to launch it.

The latest release requires macOS 26.

- Reworked and improved tab management
- Spaces and Profiles are simplified and combined now
- Enhanced the built-in adblocking system
- Added custom tweaks for YouTube and Social Media sites
- Improved split view
- PiP is more Arc-like (WIP, tested mainly on YouTube)
- Passkeys work through password managers. iCloud Keychain passkeys are still unavailable for now
- Performed multiple passes to harden security
