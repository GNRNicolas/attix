# Chrome Web Store listing

Copy-paste material for the dashboard. Keep it in sync with `chrome-extension/manifest.json`.

## Name
Attix for Chrome

## Summary (132 chars max)
See how many tabs Chrome is holding and put the idle ones to sleep, without losing them.

## Category
Workflow & Planning

## Description
Chrome keeps a renderer process alive for tabs you have not looked at in hours.
Attix for Chrome shows you how many tabs you are holding, which ones have been
idle the longest, and puts them to sleep in one click.

A sleeping tab stays in the tab bar, with its title and its position. Only its
renderer process is handed back to the system. Clicking it reloads the page.
Nothing is closed, nothing is lost.

It never touches a tab that is active, pinned, playing audio, or already asleep.

What it does not do, and it is better said than faked: Chrome exposes per-tab
memory to no Web Store extension at all. The chrome.processes API exists but is
reserved for internal builds. Showing "312 MB" next to a tab would mean inventing
the number, so this extension sorts on the one thing it actually knows: how long
ago you last looked at the tab.

No account, no network request, no data stored. Open source: https://github.com/GNRNicolas/attix

## Single purpose
Show the user how many tabs are open in Chrome and let them discard the ones that
have been idle the longest, to give memory back to the system.

## Permission justification — tabs
The extension lists the user's open tabs in its popup in order to sort them by how
long they have been idle, and calls chrome.tabs.discard() on the ones the user
picks. Both listing tabs with their title and lastAccessed time, and discarding
them, require the "tabs" permission; Chrome offers no narrower permission for
either. The extension requests no host permission and injects no content script,
so it cannot read page content.

## Data usage (certification)
- Does not collect or use personally identifiable information: **yes, none collected**
- Health information: no. Financial information: no. Authentication information: no.
- Personal communications: no. Location: no. Web history: **no** — tab URLs are read
  in the popup to display a site name and are never stored or transmitted.
- User activity: no. Website content: no.
- Not sold to third parties, not used for unrelated purposes, not used for
  creditworthiness: **certify all three**.

## Privacy policy URL
https://github.com/GNRNicolas/attix/blob/main/docs/privacy.md

## Assets
- Store icon 128x128: `chrome-extension/icons/128.png`
- Screenshot 1280x800 (at least one required): `docs/chrome-store-screenshot.png`
