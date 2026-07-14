# BeanBeaver privacy policy

_Last updated: 2026-07-13_

BeanBeaver turns a photo of a receipt into a [Beancount](https://beancount.github.io)
transaction. It works with no account and no network connection.

## What BeanBeaver collects

**Nothing.** There is no BeanBeaver account, no analytics, no crash reporting, no
advertising, and no server behind the app. BeanBeaver cannot see your receipts,
your ledger, or how you use it.

## What stays on your device

**Scanning happens entirely on your device.** The text-recognition models are
bundled inside the app and run locally. A receipt photo is never sent anywhere
as part of scanning — turn on airplane mode and BeanBeaver still works.

**Photos you scan** are stored on your device, in the app's private storage, so
you can review the original behind a scan later. They are never uploaded as part
of scanning. You can remove them at any time with Settings → Clear Old Receipts,
and they are deleted along with the app if you delete it. iOS may also clear them
on its own when the device is short of storage. If you turn on "Save a copy to
Photos", a copy is additionally written to your own photo library.

## What leaves your device — only when you ask

**GitHub sync is the only feature that sends anything off your device, and only
if you set it up.** If you connect a GitHub account, then each time you tap Sync,
BeanBeaver opens a pull request against the repository *you* chose, containing
the transaction, the receipt image, and (if enabled) a JSON details file. That
data goes to your own repository on GitHub — not to the developer of this app.
GitHub's handling of it is covered by
[GitHub's privacy statement](https://docs.github.com/site-policy/privacy-policies/github-privacy-statement).

Connecting GitHub uses the OAuth device flow. BeanBeaver is a GitHub App you
install on a single repository, so its access token cannot touch your other
repositories. The token is stored in the iOS Keychain, on-device only, and is
never synced to iCloud or sent anywhere except to GitHub. Settings → Disconnect
deletes it.

If you never connect GitHub, nothing ever leaves your device.

## Permissions BeanBeaver asks for

- **Camera** — to photograph a receipt. Used only while the scanner is open.
- **Add to Photos** — only if you turn on "Save a copy to Photos".
- **Photo library selection** — handled by the system picker; BeanBeaver only
  receives the specific image you choose, and has no access to the rest of your
  library.

## Children

BeanBeaver is not directed at children, and collects no data from anyone.

## Changes

Any change to this policy will be published in this file, in the app's public
repository: <https://github.com/Endle/beanbeaver-ios>

## Contact

Questions or concerns: open an issue at
<https://github.com/Endle/beanbeaver-ios/issues>
