# BeanBeaver iOS - Scan Receipts, Track Spending

BeanBeaver turns a photo of a receipt into an itemized Beancount transaction — entirely on
your phone.

<a href="https://apps.apple.com/ca/app/beanbeaver/id6790981690"><img
  src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg"
  alt="Download BeanBeaver on the App Store" height="52"></a>


## Parsing Grocery Receipts
Snap a receipt with the camera (or pick one from your photo library). BeanBeaver reads it with on-device text recognition, then extracts the merchant, date, line items, and total cost. The result is a plain-text transaction, ready to copy, share, or export to Beancount.


## Spending Tracking
Your spending breaks down to actual categories (Dairy $30, Meat $50, Drink $40, Fruit $30), instead of one lump sum record (Costco $100, T&T $50). BeanBeaver also provides monthly summary and weekly trends for each category, helps you plan your grocery trips.


## Privacy is Top Priority
BeanBeaver uses an on-device OCR model. Scanning, parsing, and categorizing all happen on your device. There is no account registration, no analytics, no user profiling or fingerprinting, and no cloud server. Everything stays on your phone unless you explicitly export it somewhere.

## Open Source Project
The app and its parsing engine are MIT-licensed:

https://github.com/Endle/beanbeaver-ios
https://github.com/Endle/beanbeaver-core

Third-party open source dependencies are credited in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
