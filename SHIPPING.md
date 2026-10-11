# Shipping Focus to friends

Both apps go through **TestFlight**. That's Apple's free beta-distribution
channel — works for Mac and iPad/iPhone, no extra cost beyond your
existing Developer Program. Friends download the **TestFlight app** and
get your build with one tap.

## Why TestFlight (vs alternatives)

- ✅ Free with your Developer Program membership
- ✅ Same flow for Mac AND iPad
- ✅ Friends get auto-updates when you push a new build
- ✅ Up to 10,000 testers per app
- ❌ Each build needs a quick Apple review (first build: ~24h, subsequent: minutes)

(Direct download outside the App Store is **not possible for iPad** at all.
You can notarize a Mac .app for direct download, but TestFlight is simpler
and uses the same flow as iPad.)

## One-time setup at App Store Connect

For each app (Mac + iPad — two separate "apps" in App Store Connect even
though they share data and code):

1. Sign in at https://appstoreconnect.apple.com
2. **My Apps** → blue **+** → **New App**
3. Pick the platform (iOS for iPad, macOS for Mac)
4. Fill in:
   - **Name**: "Focus" (must be unique on the App Store)
   - **Primary language**: English
   - **Bundle ID**: pick from dropdown
     - Mac: `com.magnus.focus`
     - iPad: `com.magnus.focus.iPad`
   - **SKU**: anything (e.g. `focus-mac`, `focus-ipad`) — internal id only
   - **User access**: Full Access
5. Click **Create**.

You don't need to fill out any App Store listing fields for TestFlight —
only for full App Store release.

## Building + uploading via Xcode

For **each** app (Mac and iPad):

1. Open the project in Xcode (Mac: `Focus.xcodeproj`; iPad: `FocusPad/FocusPad.xcodeproj`)
2. In the top bar, change **destination** to **Any Mac (Apple Silicon)** for Mac, or **Any iOS Device (arm64)** for iPad.
3. **Product → Archive** (`⌘B` first to make sure it compiles)
4. The Organizer window opens with your archive selected.
5. Click **Distribute App** → **App Store Connect** → **Upload** → **Next** → **Next** → **Next** → **Upload**.
6. Wait ~5 minutes for Apple to process. You'll get an email when processing finishes.

Common gotchas:
- **First archive needs explicit signing** — Xcode will offer to manage signing automatically; accept.
- **Version + Build numbers**: must increase each time. Bump `CFBundleVersion` (build number) in `project.yml` for each upload, regenerate with `xcodegen`. App Store rejects duplicate version+build pairs.

## Inviting friends as testers

After upload + processing:

1. https://appstoreconnect.apple.com → **My Apps** → your app → **TestFlight** tab
2. You'll see your build under "iOS" or "macOS"
3. First-time only: fill out **Test Information** (just an email and a one-sentence description — minimal)
4. Click **+** next to **Internal Testers** (no Apple review needed, up to 100 testers)
   - Add friends by their Apple ID email
   - They'll get an email + a TestFlight push notification
5. OR click **+** next to **External Testers** (up to 10,000, requires one-time **Beta App Review** by Apple, takes ~1-2 days)
   - Better if friend doesn't have an App Store Connect role
   - You get a public link to share

For just a few friends, **Internal Testers** is fastest — no Apple review.

## Friend's side

1. Friend installs the **TestFlight** app from the App Store:
   - iPad: https://apps.apple.com/app/testflight/id899247664
   - Mac: built into macOS already
2. They open the email invite → tap **View in TestFlight**
3. Tap **Install**
4. Open Focus. They sign into iCloud, get their own private database, start using it.

## Updates

After the first upload, future builds are basically free:

1. In Xcode: bump build number (e.g. `1` → `2`) in `project.yml`
2. `xcodegen generate`
3. Product → Archive → Distribute → Upload (just like first time)
4. Once processed, testers get an auto-update notification

**Internal testers get builds immediately. External testers may need a quick re-review** (usually under an hour for incremental builds).

## What friends DON'T need to set up

- They do **not** need an Apple Developer membership
- They do **not** need to be on your dev team
- They do **not** need to enable any developer mode
- Their data is **isolated** from yours — CloudKit private database per user

## Pricing strategy (if you ever go past TestFlight)

When you're ready to launch on the App Store proper:

- **Free + no IAP**: simplest, no review of monetization
- **Paid app**: one-time price (you set tier, Apple takes 30% / 15% if Small Business Program)
- **Subscription**: requires implementing StoreKit, more work
- **Free with optional tip jar**: lightweight monetization

For now, keep it free and on TestFlight while you iterate with your friend.

## Quick build-and-ship script

I'll write `ship.sh` for you that builds, archives, and uploads both apps
when you say "ship it". Until then, the Xcode UI flow above is the official
path.
