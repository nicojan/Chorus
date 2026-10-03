# Changelog

All notable changes to Chorus are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Fixed

- Work you start with a click in Gmail — marking a message read, archiving or deleting it — now survives hiding Chorus, switching services, or quitting. Hiding happens at once, and the app gives the click time to reach Gmail before it clears hover state or puts the page aside. Reloading the very instant after a click can still drop the change if Gmail has not sent it yet: at that point there is nothing to save.
- Chorus tells Gmail it is Safari 27 rather than 26.

## [1.5.26] - 2026-10-03

### Added

- Add a Mac app to the rail, for chat apps with no web version such as LINE. Choose it under Add Service, in the Mac App tab. Click it and Chorus opens the app and lays its window over the space a web service would take, following the Chorus window as you move or resize it. Switch to another service and the app hides. The app's unread count shows on its rail icon once you allow Chorus under Privacy & Security, then Accessibility. macOS doesn't let one app's window sit inside another's, so it is still the app's own window, with its own menu bar, and it can't follow Chorus into full screen.
- Tips for features people miss: the four layouts, Mac apps, the ⌘K switcher, and each service's own settings. A tip points at the control it describes and has a button that takes you straight there. One a day, at most. Close a tip, or use the feature, and it's gone.
- After an update, a short sheet lists what's new, with a button to try each item.

### Fixed

- The ⌘K switcher no longer moves as you type. The search field stays in one place near the top of the window, and the list below it grows or shrinks with the matches.
- The switcher's first row could show the wrong service after you typed a filter. Enter still opened the right one, but the name was wrong.

## [1.5.25] - 2026-10-01

### Fixed

- Gmail could open with its top bar, and the search box in it, out of sight above the page until you moved the window. Chorus now has Gmail measure the window again once the page has loaded.

### Changed

- When the rail holds more services than fit, its bottom edge fades out above Add service instead of cutting a row in half. At the end of the list the fade moves to the top edge.

## [1.5.24] - 2026-09-30

### Fixed

- Figma's sign-in with Google stayed on the sign-in page after the Google window closed. Chorus reloaded the page as soon as the window shut, before Figma could finish signing you in. Chorus now waits a few seconds, and skips the reload if the page has moved on by itself.
- The list of services showed a teal loading mark for Figma instead of its logo. The list now shows the same logos as the rail.

## [1.5.23] - 2026-09-30

### Added

- Drag the edge of the rail to make it as wide as you like. Pull it in past its narrowest width and the rail slides down to its icons, with the unread badges popping onto them; push it back out and the names return. Settings still has the switch, and it remembers the width you chose.

### Changed

- Spaces and services move out of the way as you drag one past them, and the new order is saved as you go. In All services on the left you can drag a service into another space the same way. A dragged service shows its icon under the pointer.
- In All services on the left, each space's services sit on a card of their own, with the space's name above it. The other left-hand layouts drop the card round the rail, so the page is the one card in the window. The page's corners now follow the curve of its scroll bar.
- Unread counts look like the ones in Notes: a grey number at the end of the row. Without names, a service or space shows the red badge on its corner instead. A count that goes up flashes, and if you are elsewhere it turns red and pulses until you open that service.
- Buttons in the rail and the Back, Forward, Reload, Home and Share buttons now light up under the pointer, and a button that can't be used looks it. The blue ring that marks the keyboard's place appears once you use the keyboard, not on the first service when Chorus opens. LinkedIn Messaging has its own icon, a speech bubble.

### Fixed

- A space dragged downward in the list of spaces stayed where it was.
- A badge over 99 showed three dots instead of 99+.
- The corners of the rows and tiles in the rail did not follow the rail's own.

## [1.5.22] - 2026-09-29

### Added

- A download button joins the navigation buttons once something downloads. While files come in it fills a ring, and a click lists every download since Chorus opened, from every service: which service it came from, how far along it is, and how it ended. You can stop one that is still running, show a finished file in Finder, or double-click it to open it. Before this, the only sign of a download was the Downloads stack bouncing in the Dock.
- Music and video keep playing when you switch to another service, as they would in a browser tab. A service making sound shows a speaker in the rail, and right-clicking it offers Pause Audio. A page that was quiet when you left it still pauses, so a background page can't start playing on its own.
- Settings has one switch for where outside links open, a Chorus window or your browser. Each service can follow it or make its own choice when you edit it.
- Settings can save your spaces and services to a file, and add them back from one, on this Mac or another. Sign-ins stay behind, so you sign in to each service again after an import. An import only adds: a space merges into yours when the names match, and it removes nothing you have. Before you say yes it lists the sites the file would add, and camera and microphone choices stay behind, so each imported service asks again.
- The app now carries the license texts for the parts other people wrote, and About links to them. The HaGezi blocklist is GPL-3.0, and Chorus shipped it with only a link. The exact list text each release blocks from now sits in the source code. I also brought both blocklists up to date.
- You can add all of LinkedIn as a service now, with your feed, jobs and notifications. The one that shows only your messages is still there, as LinkedIn Messaging.

### Changed

- The window has a new look, borrowed from [Paguro](https://github.com/anguria-studio/Paguro). The page sits on a card with rounded corners and a narrow grey margin round it, and the rail has a card of its own. A selected service is grey with its name in black or white, not blue. Blue now marks only the row the keyboard is on. Rows are shorter, so more services fit, and in All services on the left each space's name heads its group. The window's own buttons at the top left sit in the middle of a taller band along the top, and the page buttons, such as Back and Reload, are round. On macOS 26 you can let the desktop show through behind the rail and the bars, from Settings; it starts off. Warnings are cards above the page now, clear of the window's buttons, and a long one shows all its words. No text in the rail or the notices is smaller than 12 points.

### Fixed

- Trello can sign in inside Chorus. Its Log in button goes to an Atlassian page on another domain, and Chorus sent that page to your browser, where signing in did nothing for Chorus. Chorus now keeps a sign-in page in the service when it says it will come back there, which should help other services that sign in on another domain too. Jira and Confluence use the same Atlassian page. The same goes for Zoho outside the US, Coda, and ChatGPT, and for company sign-ins through Okta, Auth0, OneLogin, Duo, PingOne, JumpCloud, Azure AD B2C, Cloudflare Access and AWS.
- A call keeps its sound when you switch to another service. Chorus paused the sound of every service you left, so the other person went quiet while your microphone kept sending.
- Before it quits, Chorus now tells every open page it is going away and gives it a moment to save, the way a browser does. A quit used to give pages no warning.
- Chorus no longer loads a hidden second copy of WhatsApp or another chat app to read its unread count. Two copies on one sign-in can sign WhatsApp out.
- The grey loading ring on a service stops when you press Stop or a download starts. It used to spin forever. A download no longer puts up "Unable to connect", and Reload now works on a service whose first page never loaded.
- A link that opens another of your services in a new window, such as a Linear link in Slack, now switches to that service. Sign-in windows still open as windows.
- A sign-in window that opens a second window stays open. It used to close, which broke some company sign-ins partway through.
- The window Chorus opens for an outside link now presents itself to sites as Safari, so Google and others stop calling your browser unsupported. A file link in that window now downloads in your browser. It used to do nothing.
- With "Always show scroll bars" on, the rail's scroll bar no longer pushes its icons off centre.
- A setting that fails to save stays unsaved. Before, it turned up later, when something else saved.

Much of this release comes from [Paguro](https://github.com/anguria-studio/Paguro), a fork of Chorus by Tommaso Laterza. Paguro found most of these bugs first, and the new look is Paguro's, drawn again in Chorus's own code. Chorus wrote most of the fixes its own way. Two small helpers, the ones that keep a page on screen after a failed load and let Reload work on a page that never loaded, follow Paguro's code closely and ship under its MIT license; `THIRD_PARTY_NOTICES.md` names them. Thank you, Tommaso.

## [1.5.21] - 2026-09-29

### Added

- A fourth layout, All services on the left, puts every space in one narrow rail with its services under it. Click a service in any space to go straight to it, or drag it to reorder it or move it to another space. In this layout, Command 1 to 9 and Command [ and ] step through the whole rail. MazzMat wrote it.

### Fixed

- You can now sign in to Gmail inside Chorus. Signed out, Gmail shows a page with a Sign in button, and that button opened a separate window. You signed in there, Gmail came up in that window, and the Gmail in Chorus still asked you to sign in. The sign-in page now opens in Chorus, and Gmail loads there when you finish. If this happened to you, click Sign in once more. Google already knows you from the other window, so you may only have to pick your account.
- A window a site opens for you, such as Sign in with Google, now presents itself to the site as Safari, the way the rest of Chorus does. Gmail in one of those windows said your browser was no longer supported.
- With service names turned off, the back button no longer sits under the green button in the corner of the window.

## [1.5.20] - 2026-09-22

### Added

- A switch in Settings turns the daily update check off. It was always on before, with no way to stop it.
- The navigation buttons gained a share button. It copies the address of the page you are on, opens that page in your usual browser, or hands it to the system share sheet. Until a service has finished loading for the first time there is no address to work with, and the button stays greyed out.

### Changed

- Chorus now asks a server I run whether an update is out, rather than asking GitHub. I count those requests. It is the only way I can tell how many people use Chorus, and GitHub kept no record of them. What I keep is a number per day and a breakdown by version, and I do not store your IP address. The README says what the request carries and how to switch it off.
- Chorus holds on to less memory over a long run. When you switch away from a service it keeps a picture of how the page looked, so coming back does not show you a blank rectangle while it loads. It was keeping one of those for every service you had ever left, at full window size, for as long as Chorus stayed open. It now keeps the last three and drops each one the moment the page it covers is back.
- A service you added by typing its address now says what hibernating it costs. Chorus keeps chat apps from its own list loaded so their messages reach you at once, but it cannot tell what a service you typed in is, so it hibernates that one like any other page and its notifications stop arriving until you open it. The setting says so now instead of leaving you to find out.

## [1.5.19] - 2026-09-03

### Added

- A small button in the top right of the window opens the donation page, and the About panel carries the same link. Chorus stays free. This is here if you want to pay for it anyway.
- A service that is still loading, or that failed to load, now says so in the rail. A grey ring on its icon means the page is coming up; an orange dot means it did not. Nothing shows when the page is fine. The three marks differ in shape as well as colour, so they still read if you cannot tell the colours apart, and a screen reader says which one it is.

- Google Keep is in the service catalog, with its own logo rather than a letter tile.

- Settings can turn the service names off. A service is then its icon alone in a narrower rail, and the name stays in the tooltip. Turn it off if you know your services by sight and would rather give the width to the page.

### Changed

- In the rail-on-the-left and bar-along-the-top layouts the strip of spaces is gone, and the space you are in is a header at the top of the service rail. Click it to switch spaces, add one, rename one or delete one. The width that strip used to take goes to the page you are reading.
- The layout with your spaces down the left and your services along the top is still here. Its strip of spaces carries their names, and a setting turns those off for a narrow column of emoji.
- The messages that appear across the top of the window all look like one thing now. There were three of them and they were drawn three different ways, including a solid red bar for being offline that shouted louder than the problem. They share one shape, and how serious it is comes through the icon and a thin rule rather than the colour of the whole strip.
- Keyboard focus is visible in the rail again. The service you are on and the service the keyboard is on are two different things, and they are now drawn two different ways: a filled row for the one you picked, an outline for the one the arrow keys will move from. A fix in 1.5.10 had removed the outline rather than reshaping it, because the old rail was too narrow to hold it.
- Every service in the rail now carries its name. It used to be an icon and nothing else, so two Slack workspaces were two identical squares and the only way to tell them apart was to hover one and wait for the tooltip. The unread count, the mute bell, the sleep moon and the camera dot move off the icon's corners and sit beside the name.
- The rail down the left side is wider, to fit those names.
- The bar along the top no longer loses its add button when there are more services than fit. The button now sits at the end of the bar and stays there, the tabs scroll under it, and the edge they run past is softened so you can see the row keeps going. Before this the last tab was cut through its icon and the add button was somewhere off the end.

### Fixed

- Deleting a space could quit Chorus on macOS 15. The space went, and Chorus closed with it. Whether your data survived depended on when it stopped, which is not a question you should have to ask about deleting a space. It happens on macOS 15 and not on macOS 26, so the machine Chorus is built on could never show it; a test run on an older system is what found it. Nothing about your spaces or services changes, and Chorus updates the shape of its data file when it first opens, keeping a backup before it does.
- A fresh install that took an update before you had set anything up could get stuck on temporary storage. Chorus said your saved data could not be loaded, offered no backup to restore, and came back the same way at every launch. Deleting Chorus and installing it again did not clear it, because neither your data file nor the marker Chorus keeps beside it lives inside the app. Chorus now starts you on a new, empty file when it can see there is nothing to lose, and the warning has a Start fresh button for the times it cannot tell. Your old file is kept as a backup either way, and the backup list shows it, so you can go back.
- Microsoft Teams and other services behind a company sign-in can stay signed in. Teams would show its own "sign in again" banner, the button led nowhere, and the state came back about a day after every successful sign-in. Chorus was blocking the hidden frame Teams reads its session from. Each service still keeps its cookies to itself.
- Signing in to a service no longer sends you a stream of approval requests. When a sleeping service needed signing in again, the background check that reads its unread count kept reloading it, and every reload asked your authenticator to approve. One person got 68 prompts in 14 hours. Chorus now stops checking a service that needs you, and picks it up again when you open it.
- Closing a window opened from a link leaves the service alone. It used to reload the page behind it, losing your place and anything you had typed and not sent. A sign-in window still reloads the service when it closes, which is the point of it.
- Starting fresh no longer leaves a copy of your old data on disk for good. Chorus keeps the last few, plus the very first one, and clears the rest. The first is the one worth keeping: it is your data as it stood before you started over at all.
- A service that opens a window through a script gets a real one. Some sign-in flows check whether the window opened and give up quietly if it did not, which looked like nothing happening at all.
- Clicks could stop landing on a page, most often after switching to a service and back. While a page loads, Chorus covers it with a picture of how it last looked, so the wait is not a blank rectangle. Chorus was not clearing that picture when there was no wait to fill, and it came back over the page on its next load. You were then clicking a still image of the page you wanted, which is why it read as frozen rather than broken. Found on TD EasyWeb's sign-in screen.
- A service you add by typing its address gets its icon from the site more often. Sites name their icon in the page, usually by a path relative to the page itself. Chorus resolved that path against the address you typed rather than the address you ended up at, looked in the wrong place, found nothing, and drew a letter. Typing easyweb.td.com lands you on authentication.td.com, and TD's icon is only on the second one.

## [1.5.18] - 2026-08-06

### Fixed

- Chorus keeps your spaces and services in its own folder now. It used to save them to a file whose name and location the system picks by default, which puts it outside any one app's folder. Another app that also took the default wrote to the same file. Whichever app opened it second reshaped it and dropped everything the other had stored. That is what was wiping your spaces and services, and it could happen at any launch, with no update involved. Chorus moves your data into a folder of its own on first launch. If the file at the old location turns out to belong to another app, Chorus leaves it alone and restores your data from its own backup instead.
- Being logged out of a service after your data went missing. When Chorus lost your spaces and services and you added a service back, the new one got a fresh, empty place to keep its cookies, so you had to sign in again. The old one stayed on disk, holding a session nothing could reach. Chorus now clears out the ones no service is using.
- Chat services in other spaces stay loaded, so their notifications arrive when the message does. Only the space you were looking at was kept loaded. A chat service anywhere else was silent: its unread count crept up on a three-minute cycle and no banner appeared at all.
- Notifications from services that send them through a background worker. Many web apps do, and Chorus never saw those.
- Chorus no longer cleans up after itself on a launch where your data arrived damaged or had just been restored. Deleting a service that looks unused, and erasing its cookies, is right on a healthy store and wrong on a broken one, where a service can look unused because a piece of the file is missing. It waits for a clean launch now.
- You can drag the window by its notice bar again. While a notice was showing across the top, the window would not move.

## [1.5.17] - 2026-07-31

### Fixed

- The Gmail badge counts only unread mail in your inbox. It was counting Spam too: Gmail keeps a folder's messages loaded in the page after you leave it, and Chorus counted every unread row it could find, so a spam folder holding 161 unread showed up as 99+ over an inbox with two.

## [1.5.16] - 2026-07-30

### Added

- A store recovery picker. Open Settings and choose "Restore from a backup" to see every backup Chorus keeps, what each one holds, and when it was taken, then put back the one you want. Chorus also offers this on its own, the moment it notices your spaces and services are missing. Either way, it sets your current data aside first, so choosing a backup never throws away what you had.

### Fixed

- Chorus can now read a backup taken after it was closed cleanly. SQLite removes two side files on a clean close, and a backup missing them could not be opened for reading at all, so the automatic recovery in 1.5.15 could pass over a perfectly good backup and report that it had nothing to restore from.

## [1.5.15] - 2026-07-29

### Fixed

- Chorus now opens your saved data through migration steps that are written out per version and covered by tests, instead of letting the system work out for itself what changed. Leaving it to the system was the cause of the data loss 1.5.14 was built to catch: on some updates the store opened empty, and Chorus wrote the default spaces and services over it. The 1.5.14 backup-and-restore net stays in place. If the new path cannot open a store, Chorus falls back to the old way of opening it, so no update is worse off than before.

### Added

- Chorus installs with Homebrew: `brew install --cask nicojan/tap/chorus`. The cask fetches the same signed, notarized DMG as the download link, and Sparkle keeps handling updates once the app is in place.

## [1.5.14] - 2026-07-24

### Fixed

- Chorus no longer replaces your spaces and services with the default set when
  an update leaves your saved data unreadable. Now it catches that at startup
  and restores your data from the backup it takes before every update, then
  tells you it did. If it can't restore, it stays on temporary storage and
  points you to the backups. It never writes over your data.

## [1.5.13] - 2026-07-23

### Changed

- A per-service hibernation setting. Each service can now follow the global
  hibernate setting, hibernate when you switch to another service, hibernate
  after a set idle time you choose, or never hibernate. This replaces the old
  "Keep loaded" toggle, which is now the "Never" choice. Chat services stay
  loaded whatever you pick, so their messages still reach you the moment they
  arrive.

## [1.5.12] - 2026-07-23

### Added

- A per-service "Always appear active" setting. Turn it on for Microsoft Teams
  and Chorus reports the page as focused while it sits in the background, so
  Teams keeps showing you as active instead of away. Chorus offers to switch it
  on when you add Teams from the catalog, and you can change it any time by
  editing the service. It is off by default, because faking focus can make a
  service hold back some of the notifications Chorus forwards.

## [1.5.11] - 2026-07-22

### Fixed

- A service's unread badge could be covered by the tab's selection outline or
  crowded against the top of the window in the top-bar and hybrid layouts. The
  badge now sits above the outline and clear of the window edge.

## [1.5.10] - 2026-07-22

### Fixed

- The selected space in the sidebar showed a stray blue box around its icon: a
  system focus outline drawn on top of the space's own highlight, which the
  narrow sidebar then clipped. Now only the app's own highlight shows.

## [1.5.9] - 2026-07-22

### Added

- Chorus can hibernate a service you have not opened in a while, freeing its
  memory and CPU until you go back to it. It stays off until you turn it on in
  Settings under General. Chat apps stay live, so their notifications still
  arrive the moment a message lands.
- You can open an outside link in a Chorus window instead of your browser. Turn
  it on for a service in that service's settings. It is off to start with.

### Changed

- Dark theming is now something you set for each service by hand. Chorus no
  longer guesses whether a site needs a dark theme. If a service used to go dark
  on its own, open its settings and turn its dark mode On to keep that. As
  before, a service is themed only while the app itself is dark.

### Removed

- Reader mode.

### Fixed

- Tightened how Chorus decides where a clicked link goes. A page can no longer
  pass itself off as one of your services by sharing a hosting domain with it,
  and a link that leaves the app through a scheme like mailto now needs a real
  click.
- Favicon lookups no longer follow a redirect to a private or local address.
- Reliability fixes in hibernation, in moving a service to another space, and in
  setting a custom icon.

## [1.5.8] - 2026-07-22

### Added

- Chorus now copies your saved data aside before a new version opens it, so if
  an update ever fails to load your spaces and services, the earlier copy is
  still on disk and recoverable.

### Changed

- The Google favicon fallback is off by default now. When a service has no icon
  of its own, Chorus no longer asks Google for one unless you turn it on in
  settings.
- Selected services now use Chorus's own highlight instead of the system focus
  ring.

### Fixed

- Two-color service icons no longer render as solid blocks.
- Chorus opens external links only when they use a known, safe scheme.
- Notification permission failures now go to the log instead of being dropped,
  so problems granting access are easier to track down later.

## [1.5.7] - 2026-07-21

### Fixed

- Gmail's Send button works again. Chorus now shows the JavaScript dialog panels
  Gmail uses to confirm and send a message.

## [1.5.6] - 2026-07-21

### Fixed

- Launch badges show unread counts again. Gmail and LinkedIn now count only the
  messages shown as unread, so the number matches what you see.

## [1.5.5] - 2026-07-20

### Changed

- Dark themes now load much faster after the first visit. When Chorus darkens a
  service for you (Gmail is the clearest case), it used to rebuild the dark
  theme on every load, which took several seconds on heavy pages. Chorus now
  saves the theme it builds the first time and reuses it, so the next time you
  open the service the page is dark right away and becomes usable seconds
  sooner. The saved theme refreshes itself as the page changes, and Chorus
  builds it fresh from the page when nothing is saved yet.

## [1.5.4] - 2026-07-18

### Added

- A "Re-detect dark theme" button in a service's settings, for services set to
  Auto. Use it after you switch a service to its own dark theme, so Chorus stops
  darkening it a second time.

### Fixed

- In dark mode, Gmail no longer shows a washed, low-contrast state for several
  seconds when it loads. Gmail runs light, so Chorus darkens its whole layout on
  every fresh load, and you used to see that half-themed state before it settled.
  Chorus now covers the view while it applies the dark theme and reveals the page
  once it is ready.
- Chorus now asks macOS for notification permission after it finishes launching
  instead of during startup, so the first-run prompt appears reliably.

## [1.5.3] - 2026-07-14

### Added

- **Camera and microphone.** Chorus can now use your camera and microphone, so
  video calls and voice work in the services that need them, from Google Meet to
  Microsoft Teams. Each service asks the first time it wants your camera or mic.
  You can set Allow, Ask, or Deny for a single service or as the default for all
  of them, mute every microphone at once with ⇧⌘M, and see a dot on a service
  while its camera or mic is live.
- **More services.** Twenty-four services were added to the picker, bringing the
  built-in list to more than seventy.

### Changed

- Services that already switch to a dark theme on their own are no longer
  darkened a second time, so they look the way their makers intended.

### Fixed

- Reliability and security fixes across saved data, downloads, and network
  handling.

## [1.5.2] - 2026-07-13

### Fixed

- You can now upload files to your services. Clicking a file-picker button, such
  as Slack's "Upload file" for a profile photo, used to do nothing because Chorus
  never opened the file browser. It now opens.
- Chorus no longer crashes at launch after you deleted a space on an earlier
  version. Deleting a space could leave a broken reference in your saved data;
  the next launch tried to read it and crashed before the window appeared, with
  no way back except deleting your data by hand. Chorus now finds and clears
  those broken references as it starts, and backs up your data file first.
  Version 1.5.1 stopped new deletions from causing this but could not repair a
  store already affected. This does.
- Downloads no longer stop if you switch away from a service while a file is
  still downloading.
- Badge counts no longer mix between two accounts of the same service, such as
  two Gmail accounts.
- More reliability fixes: deleting a space no longer risks losing a service's
  data if the save fails, Chorus won't keep polling a service while your Mac is
  offline, and closing the find bar now clears its highlights.

## [1.5.1] - 2026-07-13

### Fixed

- Chorus could fail to start after you deleted a space and quit. Deleting a
  space left behind stale links to the services it held, and the next launch
  failed on them. Now deleting a space removes those links, and Chorus repairs
  any left behind by an earlier version the next time it starts. Thanks to
  /u/roman_np on Reddit for reporting this.

## [1.5.0] - 2026-07-12

### Added

- **Move a service to another space.** Right-click a service and pick "Move to
  Space", then choose an existing space or make a new one.

### Fixed

- You can now move the window by dragging any empty part of the top bar. Before,
  only the right side worked.

## [1.4.0] - 2026-07-09

### Added

- **Ad and tracker blocking.** Chorus blocks known ad and tracking domains
  across your services, using the HaGezi "Light" blocklist. It's on by default;
  turn it off in Settings under Privacy. Because it works at the domain level, it
  won't remove ads a site serves from its own domain, such as YouTube or Facebook.
- **Passkey notice.** The first time you open a service, a brief banner explains
  that passkey sign-in isn't available in Chorus, so you'll sign in with a
  password or another method.
- **Auto dark mode.** A global Appearance setting gives services without their
  own dark theme a dark one while the app is dark. Chorus guesses which ones need
  it by sampling the page background. Override it per service with Auto, On, or
  Off.
- **Hide annoyances.** An optional content-blocking setting hides cookie notices,
  newsletter pop-ups, floating share bars, and similar clutter with Fanboy's
  Annoyance List. It's off by default, since it can occasionally hide something
  you wanted.
- **Reader mode.** A toolbar button strips an article page to clean, readable
  text with Mozilla's Readability. It runs on your Mac with no network; press it
  again to return to the full page.

### Changed

- Adding a service, or creating a space, now switches to it right away.
- Force dark mode now uses Dark Reader for real per-element dark theming instead
  of inverting the page's colors, and it follows the app's Light/Dark appearance
  rather than staying dark always.

### Fixed

- Downloading a file now saves it to your Downloads folder. Before, some
  downloads did nothing, including PDFs from Microsoft Teams.
- Microsoft Teams opens on its current address, so it no longer shows the
  "Teams has a new URL" banner.

## [1.3.0] - 2026-07-05

### Added

- Keyboard navigation for the spaces and services rails. With a rail focused,
  the arrow keys move the selection, and Option with an arrow reorders the
  focused item.

### Changed

- In the top-bar and hybrid layouts, a service tab shows its icon alone, with
  its name on hover, and you can drag the open part of the strip to move the
  window.
- The cookie-banner setting now spells out what it does: it accepts consent
  pop-ups for you, tracking cookies included. Turn it off to answer each site
  yourself.

### Fixed

- Dragging a service or space tab in a top or hybrid rail now reorders it
  instead of moving the window.
- A service's unread badge no longer goes stale after you follow a link that
  switches to it.
- The preview shown while a service loads fills the pane instead of cropping or
  stretching it, and it clears once the page finishes loading.

## [1.2.1] - 2026-07-05

### Fixed

- Dragging a space to reorder it drops it exactly where you release it.
- The spaces rail scrolls, so every space and the add button stay reachable when
  you have more than fit the window.
- You can no longer delete your last space. With no spaces left, the window went
  blank and there was nowhere to add a service.
- After a service you had open is removed, the app opens on a valid service
  instead of a blank pane.
- Sign-in works when a service sends you to its login page. Google, Microsoft,
  Apple, and Yahoo sign-in pages stay in the app instead of opening your browser.
- A sign-in window no longer gets replaced by an error page, or reloaded to the
  wrong address, when a network request fails briefly.
- Web notifications come only from the service that owns the page. Embedded
  third-party frames can no longer post them in its name.
- A service that reports a bad unread count can no longer hide the badges of your
  other services.
- A service running a call inside an embedded frame is no longer suspended
  mid-call.
- The quick switcher updates its list when you rename a service while it is open.
- Muting a space clears every member service's badge right away.
- Fixed a rare launch crash that could happen after a previous session was
  interrupted while deleting.

### Changed

- Chorus stops retrying a service's icon on every launch when it can't be found,
  and keeps working if one catalog entry is malformed.

## [1.2.0] - 2026-07-03

### Added

- Layout options for the rails. Settings > General lets you keep the spaces and
  services rails on the left, stack them on top, or use a hybrid with spaces on
  the left and service tabs across the top.
- Bundled brand icons for catalog services, so each service shows its real logo
  instead of a scraped favicon.
- An appearance setting: Follow System, Always Light, or Always Dark for the
  whole app.

### Changed

- Links that leave a service now open in your default browser. A link to another
  service you already keep in Chorus opens there instead, and same-service
  navigation stays in the app.
- Opening a Slack workspace now loads in the app instead of a separate window.
- Per-service dark mode is now a single "Force dark mode" checkbox, for services
  that have no dark theme of their own. Services with their own dark theme follow
  your appearance setting, with nothing injected.
- The navigation buttons (back, forward, reload, home) moved to the top-right of
  the window, and the address bar is gone.

### Fixed

- A Google Docs link opened from Gmail no longer loads inside Gmail. It opens in
  your browser.
- LinkedIn's icons stay visible in forced dark mode, and the empty strip at the
  bottom-right of its messaging view is gone.
- Gmail no longer gets stuck with its top bar scrolled out of reach after you
  switch to it.
- Workspace chips again show the combined unread count of the services inside
  them.
- Accessibility gaps: missing VoiceOver labels on the find bar and other
  icon-only controls, low-contrast badges and the offline banner, and
  quick-switcher text that ignored the system text size.

### Removed

- The custom-CSS preset menu. The Custom CSS field and the built-in LinkedIn
  layout stay.

## [1.1.0] - 2026-07-02

### Added

- Per-service custom CSS, with a preset library and a built-in LinkedIn recipe
  that trims the page to just its messaging pane.
- Per-service dark mode for services that lack their own. Set it to Off, On, or
  Auto, which follows the system appearance.
- App lock with Touch ID and a password fallback. Choose in Settings whether it
  locks on launch and when the Mac sleeps, or lock on demand from the menu.
- Scheduled Do Not Disturb, so badges and banners go quiet during the hours you
  set.
- A Chorus-wide default zoom in Settings, still overridable per service with the
  zoom shortcuts.
- A mobile-view toggle that loads a service as if on a phone.
- An About tab showing the version, a link to the source, and a way to check for
  updates.

### Changed

- Rebuilt the Settings window. Notifications now gives each service a single row
  with its mute, macOS-notification, and badge controls together, in place of
  three separate lists.

### Fixed

- Menu-bar-only mode no longer traps you. The menu-bar dropdown now includes a
  Settings item, so you can always get back to change the setting.

## [1.0.2] - 2026-07-02

### Fixed

- A service that opens sign-in in a separate window (for example, Gmail) now
  reloads and shows the signed-in page after that window closes.

### Changed

- Chorus now checks for updates automatically on a daily schedule, without
  asking on first launch.

## [1.0.1] - 2026-07-02

### Fixed

- Closing a service's sign-in window (for example, Gmail opening its login in a
  separate window) no longer crashes the app.
- A space icon no longer stays dimmed after you drag it and let go, including
  when you drop it back onto itself.
- An emoji chosen from "More Emoji…" now becomes the space's emoji instead of
  landing in the search field.
- "Check for Updates…" now appears in the Chorus app menu.

## [1.0.0] - 2026-07-02

### Fixed

- **Crash cleaning up orphaned data stores.** Launch-time (and post-delete)
  removal of a deleted service's `WKWebsiteDataStore` ran on a background thread,
  but WebKit's data-store registry is main-thread-only; removing a
  still-registered store trapped inside WebKit and crashed the app. Cleanup now
  runs on the main actor.
- **Badge counts no longer lost when muting/un-muting a service.** `BadgeManager`
  stored `0` for muted or badge-disabled services, destroying the real unread
  count. Un-muting left the badge at `0` until the next poll tick (up to 30s, or
  never for a fully hibernated service), and the adaptive title-poll backoff
  could never reset to fast polling for a muted service. The true count is now
  stored unconditionally and mute/show-badge is applied as a display mask.
- **Deleting a space no longer orphans services or leaks their data.** Services
  that lived only in the deleted space were left behind as invisible records
  whose per-service `WKWebsiteDataStore` leaked on disk forever. Space deletion
  now reclaims orphaned services (web view torn down, record deleted, data store
  scheduled for removal), and a launch-time reaper sweeps any pre-existing
  orphans. Fixed a related lost-update race in the orphaned-data-store cleanup.
- **Duplicate `Cmd-F` binding removed.** A legacy `window.find()` search bar in
  the toolbar bound the same shortcut as the native find bar; the two resolved
  nondeterministically. The native find bar (with match navigation) is now the
  single `Cmd-F` target.
- **Stale active-service pointer after deletion.** Permanently removing a web
  view left `activeServiceID`, pin/never-hibernate sets, and the notification
  script handler dangling, breaking the next keyboard shortcut and leaking
  handlers across create/delete cycles.
- **Eviction could tear down the service you just switched to** if the switch
  happened during the pool's async WebRTC-call check. Eviction now re-validates
  active/pinned/never-hibernate state after that suspension point.
- **`.gitignore` now excludes `xcuserdata` at any depth** (the previous pattern
  was anchored to the repo root, so nested workspace user-state stayed tracked).
- **WebContent crash loop broken.** A page that crashed deterministically was
  reloaded forever; Chorus now backs off after 3 crashes in 30s and shows a
  recovery page. The connection-error page's "Try Again" reloaded `about:blank`
  (it ran `location.reload()` against a `baseURL:nil` document); it now
  loads the actual failing URL, captured from the error.
- **Notification taps are no longer dropped** when they arrive before the
  handler is wired (e.g. a notification launching the app). They're buffered and
  drained, and tapping one now switches to a space that contains the service so
  the selection is visible.
- **Hibernated-poller cookie matching follows RFC 6265** path rules (it no
  longer matches request `/foobar` against cookie `/foo`).
- **Badge counts now surface for services that gate their title on Page
  Visibility** (WhatsApp, Messenger, Discord, …). Preloaded/off-screen web views
  report as visible so their unread count still reaches the badge poller; focus
  is left untouched, so focus-gated desktop notifications keep firing.

### Added

- **Per-service macOS notification control.** A new "macOS Notifications" toggle
  (Settings) lets each service forward its web notifications to macOS Notification
  Center independently of its unread badge. Previously muting was the only way to
  silence a service's banners, which also hid the badge. Mute now stays the master
  override (it silences both and still cascades from spaces), while badge and
  banner are separate standing choices. Stored as an optional flag (defaults to
  enabled) for safe SwiftData lightweight migration.
- **Badges populate immediately on startup and after login.** Unread counts now
  appear the moment a service's page finishes loading (including the post-login
  redirect) instead of waiting up to a poll interval, and a one-shot launch sweep
  fetches counts for services outside the active space so per-space aggregate
  badges are correct right away.
- **Edit a service.** A new Edit Service sheet (service context menu) renames a
  service or changes its URL, and the live web view follows along. It also
  toggles "Keep loaded in the background" (surfacing the previously-unreachable
  never-hibernate flag) and offers "Clear session (log out)", which wipes the
  service's cookies and storage without deleting it or its place in any space.
- **Clearer empty states.** The content area now distinguishes "no spaces", "a
  space with services but none selected", and "an empty space"; the last offers
  an Add Service button.
- **Reveal in Finder** on the store-error banner, so users can back up or remove
  a corrupt data file themselves (Chorus never deletes it for them).
- **Passkey-unavailable notice** in the Add Service sheet. WKWebView can't do
  WebAuthn without the Apple-managed web-browser public-key-credential
  entitlement, so a calm inline note steers users to password + 2FA. Gated by a
  single `AppCapabilities.passkeysSupported` flag to flip once the entitlement
  is granted.
- **Polling pauses while offline and resumes on reconnect.** `NetworkMonitor`
  connectivity changes now suspend all polling (active, background, hibernated)
  instead of firing doomed requests, and resume promptly when the network
  returns. The same suspend/resume path also covers system sleep/wake, which
  previously left the hibernated-service poller running through sleep.

### Performance

- **Per-identifier `WKWebsiteDataStore` caching.** The hibernated poller built a
  fresh store every 60s per service and DataStoreManager rebuilt one per web
  view; both now reuse a cached instance, avoiding churn and macOS-26 WebKit
  fragility.
- **No more whole-table fetches on hot paths.** The mute/show-badge/catalog
  lookups (run per poll tick, and per sidebar row per render) fetched every
  service and scanned by id; they now use a single predicate + `fetchLimit: 1`
  lookup, and the sidebar computes mute state from the in-hand model object.

### Earlier polish (same review pass)

- Custom-service input validation extracted into a tested pure function
  (rejects empty labels, non-`http(s)` schemes, and hostless URLs).
- Drag-to-reorder services now drops before/after the target based on cursor
  position rather than always-before.
- Favicon `<link>` parser hardened: attribute-order independent, resolves
  relative URLs via `URLComponents`, and picks the largest declared icon size.
- Toolbar progress bar slot is height-reserved so the toolbar no longer shifts
  when loading starts/stops; web view state is seeded/reset on attach/detach.
- Dock and per-space chip badges refresh immediately on mute / show-badge
  toggles instead of waiting for the next poll tick.

### Tests

- Added unit coverage for badge mute/un-mute count preservation, masked
  aggregation, and Do-Not-Disturb; orphaned-service detection; custom-service
  validation; favicon parsing; service reorder placement; WebContent crash
  backoff; error-page retry-URL escaping; and RFC 6265 cookie matching.
- Verified via `xcodebuild test -scheme Chorus -destination 'platform=macOS'`
  (21 tests passing), plus a launch smoke test (no startup crash, clean quit).
