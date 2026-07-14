# BeanBeaver privacy policy

_Last updated: 2026-07-13_

BeanBeaver turns a photo of a receipt into a Beancount transaction. This policy
explains what happens to that photo.

## What happens when you scan a receipt

1. **The photo.** You take it with the camera or pick it from your photo library.
   It is written to the app's private storage on your phone.
2. **Text recognition, on your phone.** The receipt is read by PP-OCRv5, an
   open-source text-recognition model. The model files ship inside the app and
   run on your phone's own processor — the photo is not sent anywhere to be read.
3. **Parsing and categorising, on your phone.** The model returns each piece of
   text with its bounding box ("bbox") — where it sits on the receipt — and the
   parser uses that geometry to group words into lines and match descriptions to
   prices. The result is a merchant, a date, line items and a total, with each
   item sorted into an expense category. Those rules also ship inside the app.
4. **The transaction is shown to you**, ready to copy, share, or sync.

The parser, the categorisation rules and the model loading are open source and
auditable: <https://github.com/Endle/beanbeaver-core>. The app itself is at
<https://github.com/Endle/beanbeaver-ios>.

**Every step above works with no internet connection.** Put the phone in airplane
mode and BeanBeaver scans, parses and categorises exactly as it does online.

**The one and only time BeanBeaver uses the network is when you sync a result to
GitHub** — a feature you have to set up, and then ask for, each time. It is
described below.

**Beyond that, BeanBeaver collects nothing.** There is no BeanBeaver account, no
analytics, no crash reporting, no advertising, and no server behind the app.
BeanBeaver cannot see your receipts, your ledger, or how you use it.

## What stays on your device

**Photos you scan** are stored on your device, in the app's private storage, so
you can review the original behind a scan later. They are never uploaded as part
of scanning. You can remove them at any time with Settings → Clear Old Receipts,
and they are deleted along with the app if you delete it. iOS may also clear them
on its own when the device is short of storage. If you turn on "Save a copy to
Photos", a copy is additionally written to your own photo library.

**No history is kept.** BeanBeaver has no ledger, no database, and no list of
past receipts. A parsed transaction lives on the result screen until you copy,
share or sync it, and is not saved anywhere afterwards.

**The only other things stored** are your settings, the GitHub repository you
picked, and — if you connect GitHub — its access token, which is held in the iOS
Keychain (see below).

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
