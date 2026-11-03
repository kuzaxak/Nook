# Changelog

## Unreleased (fork)

### Changed

- New tabs open ungrouped, below the selected tab's folder (Settings → General → Tabs)
- Tabs opened from a pinned tab, a favorite or a folder land in Tabs; a run of background links keeps click order
- Option to stop nesting link tabs under their opener; Back still returns to the opener
- Duplicate Tab keeps the copy next to the original, in Pinned, Favorites or the same folder
- Tabs inside folders are bookmarks: closing one ends its page and keeps it, as a pinned tab does
- Cmd+D bookmarks a tab (to Pinned) or turns a bookmark back into a normal tab
- Universal build for Apple silicon and Intel; own bundle id
- Own update stream: Sparkle reads the fork's GitHub releases, signed with the fork's key; scripts/release.sh builds, signs with Developer ID, notarizes and publishes

### Added

- Normal tabs not seen for 3 days are archived to Reopen Closed Tab (12 hours to 30 days in Settings → General → Tabs)
- History index for the command bar: every visited page stays findable, ranked by frecency (Settings → Privacy → History)
- Secret and tracking parameters (token, code, state, session, utm_*, fbclid, gclid) are dropped from history
- Command bar keys from zsh and fish: → or Ctrl+E takes the grey completion, ⌥→ takes one word, Ctrl+W and ⌥⌫ delete a word, Ctrl+U clears, Ctrl+N/P move
- Command bar: arrows no longer rewrite what you typed; Tab on a row narrows the field to its site; ⌘↩ opens in the background and keeps the bar open; ⇧↩ opens in split view
- Command bar rows show the title over a short address; hold ⌘ for the full one
- Command bar finds sidebar folders and renamed pinned links by word; Tab on a folder searches inside it (sub-folders too), Return shows it in the sidebar
- Command bar scopes: `t ` lists tabs by space, `h ` or Ctrl+R lists history; sections with headers and up to 8 rows
- Command bar actions: commands such as Copy Current URL, Pin to Space or Move to Space run from the bar with their shortcuts shown; `> ` lists only actions
- New bindable actions: Pin to Space, Add to Favorites, Add to Folder, Move to Space, Rename Tab, Translate Page, Toggle Extension Library, Manage Extensions, Toggle Dark Mode, Toggle Developer Mode for Site
- Kagi Session Link: paste it in Settings → General and Kagi searches are signed in from every space; the token stays in the Keychain and out of history and tabs
- Search suggestions from Kagi when Kagi is the search engine
- Search engine per space (Settings → Spaces → Search), e.g. Kagi in one space and Google in another
- Control-Tab shows up to 20 recent tabs in rows; arrow keys and Return work while it is open
- The sidebar keeps the selected tab in view; denser tab rows; tab titles stay faded before the close button while it is under the pointer
- Closing the command bar gives the keyboard back to the page
- Favorites are shared by spaces that use the same profile, as in Arc; opening one keeps you in the current space
- Rename like Arc: double-click a tab or folder (or use Rename); the name starts selected, Enter or clicking away saves, Esc cancels; the field gets the whole row
- Long tab and folder names fade at the end and show in full on hover
- Command bar developer shortcuts: `loc` or `127` lists local servers one row per port, ranked by use; keywords such as `gh owner/repo` open their address (Settings → General → URL Shortcuts)
- Pawl Vault passwords and passkeys (Settings → Privacy → Passwords, off by default): pick an account under a login field, save a new password after signing in, sign in and register with passkeys; Nook checks the vault's code signature and keeps no credentials

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
