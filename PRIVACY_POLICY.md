# LoadOut Privacy Policy

**Effective date:** 2026-05-07

## What this app is

LoadOut is a reloading reference and tracking app. It helps you record your
recipes, firearms, and components. Reference catalogs (cartridges, powders,
bullets, primers, brass, firearms, parts) ship with the app for browsing.

## The short version

- We don't track you. No analytics. No advertising. No third-party data
  sharing.
- We don't run a backend that stores your reloading data. Your recipes,
  firearms, custom components, and inventory live on your device.
- The only thing we send to a server is what's needed for sign-in (your
  email, an OAuth token, etc.) — and that goes to Firebase Authentication,
  not to us.
- If you opt in to cloud backup (a Pro feature), your data is encrypted on
  your device with a passphrase only you know, and uploaded to *your own*
  iCloud Drive or Google Drive. LoadOut never receives the encrypted blob.

## Data we store on your device

- Recipes, custom components you add, firearms you've added, and
  shots-fired counts.
- This data lives in an on-device SQLite database (in your app's private
  storage).
- The only ways this data is removed are if you delete the app, reset your
  device, clear app storage, or use the in-app delete actions.

## Data we send to a server

We use Firebase Authentication (Google Cloud) for sign-in. The following
data is processed by Firebase Authentication on Google's servers:

- Your email address.
- A password hash (if you use email/password sign-in) — stored by Firebase,
  not by us; we never see the plaintext.
- OAuth tokens for any third-party providers you use (Google, Apple,
  Microsoft, Yahoo).
- Firebase's own technical metadata (anonymous user IDs, timestamps of
  sign-ins).

We do not see, store, or transmit any of your reloading data — recipes,
firearms, components, or inventory. LoadOut does not operate any backend
that receives or stores reloading data.

## Backups & exports

You have two ways to get your data off your device. Both are designed so
that LoadOut never sees the contents of your reloading data.

### Local export (free)

You can export your full reloading database to a JSON file using the
in-app export action. The file is written to your device's Files /
Downloads area. From there you control where it goes — you can keep it
locally, AirDrop it, email it, or copy it to any storage you choose.

- The export is a plain JSON file. You are responsible for protecting it
  if you store it somewhere unencrypted.
- LoadOut servers are not involved. The file never touches our
  infrastructure.

### Cloud backup (Pro, opt-in)

If you have LoadOut Pro and choose to enable cloud backup, the app will:

1. Ask you to set a passphrase. This passphrase is used to encrypt your
   backup on your device, before any upload happens.
2. Upload the encrypted backup to *your own* cloud account — iCloud Drive
   on iOS, Google Drive on Android (or iOS, if you prefer). You sign in to
   your cloud provider directly; LoadOut does not handle your cloud
   credentials.
3. Store nothing on LoadOut servers. There is no LoadOut backend involved
   in cloud backup. The encrypted blob is between your device and your
   cloud provider.

What this means in practice:

- **Your passphrase never leaves your device.** We can't read your backup,
  and neither can your cloud provider.
- **We can't recover a lost passphrase.** If you forget it, the backup is
  unrecoverable. Write it down somewhere safe.
- **Your cloud provider's privacy policy applies** to the encrypted blob
  while it's stored in your iCloud Drive or Google Drive. Apple and Google
  see an opaque encrypted file; they do not see your reloading data.
- **Cloud backup is opt-in.** If you don't enable it, nothing about your
  reloading data leaves your device.

## What we don't do

- No analytics. We don't track your in-app behavior.
- No advertising. The app shows no ads.
- No third-party data sharing or selling.
- No location collection.
- No microphone or camera access (the app doesn't request these).
- No contacts, photos, or other personal device data is collected.
- No LoadOut-operated cloud storage of your reloading data — ever.

## Sign-in providers

If you sign in with a third-party provider (Google, Apple, Microsoft, Yahoo),
that provider's privacy policy also applies to your relationship with them.
We only request the minimum scope needed to identify you (typically email
and name).

- Google: https://policies.google.com/privacy
- Apple: https://www.apple.com/legal/privacy/
- Microsoft: https://privacy.microsoft.com/privacystatement
- Yahoo: https://legal.yahoo.com/us/en/yahoo/privacy/

## Children

LoadOut is not directed at children under 13 (or 17, given the subject
matter). We do not knowingly collect data from minors. Reloading is for
adults — see the app's disclaimer.

## Your rights

- **Delete your account:** sign out and delete the app. To remove your
  auth record from Firebase, request account deletion via the contact
  below.
- **Export your data:** use the in-app local export to get a JSON copy
  of your reloading database. This is free for all users.
- **EU/UK/CA residents (GDPR / UK GDPR / CCPA):** you have rights to
  access, correct, delete, and port your data. Contact us using the
  address below.

## Changes to this policy

We will update the effective date and notify you in-app (via a re-prompt
of the disclaimer / privacy dialog) if we make material changes.

## Contact

Johnson Digital Systems
info@johnsondigitalsystems.com
