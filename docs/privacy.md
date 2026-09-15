# Privacy policy

Applies to the **Attix** macOS app and to the **Attix for Chrome** extension.

## The extension

Attix for Chrome reads the list of open tabs in your browser, in the popup, when
you open the popup. For each tab it looks at three things: the title, whether the
tab is active, pinned, audible or already discarded, and when it was last looked
at. It uses them to sort tabs by how long they have been idle, and to call
`chrome.tabs.discard()` on the ones you choose.

- **Nothing is sent anywhere.** The extension makes no network request. It has no
  server, no analytics, no crash reporter, no remote configuration.
- **Nothing is stored.** No `chrome.storage`, no cookie, no local database. Close
  the popup and the list is gone; every opening recounts from scratch.
- **No page content is read.** The extension has no host permission and no content
  script, so it cannot see what is inside your tabs, only that they exist.
- **No URL is collected.** A tab's URL is used in the popup to show its site name
  and is never written down or transmitted.

The `tabs` permission is what Chrome requires to list tabs and to discard them.
There is no narrower permission that allows it.

## The macOS app

Attix reads memory counters from the local kernel (`host_statistics64`,
`vm.swapusage`, `kern.memorystatus_vm_pressure_level`) and the local process list.
It makes no network request of any kind, keeps no history, and writes nothing
outside its own preferences (the two settings: open at login, hide from the Dock).

## Contact

Open an issue: https://github.com/GNRNicolas/attix/issues
