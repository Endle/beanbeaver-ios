# BeanBeaver privacy policy

_Last updated: 2026-07-13_

BeanBeaver turns a photo of a receipt into a [Beancount](https://beancount.github.io)
transaction. It is built so that your receipts stay yours.

## What BeanBeaver collects

**Nothing.** There is no BeanBeaver account, no analytics, no crash reporting, no
advertising, and no server operated by us. We cannot see your receipts, your
ledger, or how you use the app.

## Where your data goes

**Scanning happens entirely on your device.** The OCR models are bundled inside
the app and run locally. A receipt photo is never sent anywhere as part of
scanning.

**Photos you scan** are kept in the app's private storage so you can review the
original behind a scan later. You can delete them at any time with
Settings → Clear Old Receipts, and they are removed with the app if you delete
it. If you turn on "Save a copy to Photos", a copy is also written to your own
photo library.

**GitHub sync is the only thing that leaves your device, and only if you set it
up.** If you connect a GitHub account, then each time you tap Sync, BeanBeaver
opens a pull request against the repository *you* chose, containing the
transaction, the receipt image, and (if enabled) a JSON details file. That data
goes to your own repository on GitHub — not to us. GitHub's handling of it is
covered by [GitHub's privacy statement](https://docs.github.com/site-policy/privacy-policies/github-privacy-statement).

Connecting GitHub uses the OAuth device flow. BeanBeaver is a GitHub App you
install on a single repository, so the access token cannot touch your other
repositories. The token is stored in the iOS Keychain, on-device only, and is
never synced to iCloud or transmitted anywhere except to GitHub. Settings →
Disconnect deletes it.

## Permissions BeanBeaver asks for

- **Camera** — to photograph a receipt. Used only while the scanner is open.
- **Add to Photos** — only if you turn on "Save a copy to Photos".
- **Photo library selection** — handled by the system picker; BeanBeaver only
  receives the specific image you choose, and has no access to the rest of your
  library.

## Children

BeanBeaver is not directed at children and collects no data from anyone.

## Changes

Any change to this policy will be published in this file in the app's public
repository: <https://github.com/Endle/beanbeaver-ios>

## Contact

Questions or concerns: open an issue at
<https://github.com/Endle/beanbeaver-ios/issues>
