# Ski Find

Two-way live location sharing between an iPhone and a Samsung (Android) phone, the way Find My works between iPhones.

- Live map with both of you, an accuracy ring, and a pin that greys out if sharing is paused or the location is over an hour old
- Street address, "updated 2 min ago", distance from you, driving speed, and battery level (with ⚡ while charging)
- Tap a person to zoom to them; tap the car button for driving directions (Google Maps on Android, Apple Maps on iPhone)
- Keeps sharing while the app is closed and after a restart
- Pause sharing anytime, rename yourself, add more phones (up to 6) with the pair code, remove someone, or leave

| Phone | Folder | Map | How it's built |
|---|---|---|---|
| Samsung / Android | `android/` | OpenStreetMap (no key needed) | GitHub Actions → APK on the Releases page |
| iPhone | `ios/` | Apple Maps | GitHub Actions → TestFlight |

**Cost: $0.** Locations are stored in Ski Find's own Firebase project (free Spark plan, anonymous sign-in), separate from Ski Grocery. The database rules are in `firebase/firestore.rules` and deploy automatically. Each phone can only write its own location, and only people in your circle can read them.

---

## One-time setup

### 1. Firebase (free, about 10 minutes, easiest on a computer)
1. <https://console.firebase.google.com> → **Create a project** → name it `ski-find`. Google Analytics isn't needed.
2. **Build → Authentication → Get started → Sign-in method → Anonymous → Enable → Save.**
3. **Build → Firestore Database → Create database** → production mode → location `nam5 (United States)`.
4. ⚙️ **Project settings → General**: copy the **Project ID** and the **Web API key**.
   - If the Web API key is blank, scroll to **Your apps**, click the web icon `</>`, register it as "Ski Find" and copy the `apiKey` value.
5. ⚙️ **Project settings → Service accounts → Generate new private key.** This downloads a JSON file. Keep it private and don't commit it.

### 2. GitHub secrets
This repo › **Settings › Secrets and variables › Actions** › add:

| Secret | Value |
|---|---|
| `FIREBASE_API_KEY` | Web API key from step 1.4 |
| `FIREBASE_PROJECT_ID` | Project ID from step 1.4, e.g. `ski-find-1a2b3` |
| `FIREBASE_SERVICE_ACCOUNT` | the whole contents of the JSON file from step 1.5 |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_CONTENT`, `APPLE_TEAM_ID` | same as your other iPhone apps |

Then **Actions → Database rules → Run workflow** once. After that, the rules re-deploy whenever `firebase/` changes.

## Install

### iPhone (TestFlight)
Every push to `main` that changes `ios/` builds the app and uploads it to TestFlight.

First time:
1. **Actions › TestFlight › Run workflow.** The first run registers the bundle ID and may stop at the upload step.
2. App Store Connect › Apps › **+ › New App** › bundle ID **`com.skistudio.find`**, name "Ski Find" (any unused name works).
3. Run the TestFlight workflow again. Install from the TestFlight app once Apple finishes processing (10–30 min).

The signing certificate is created once, saved encrypted in `signing/`, and reused on every build (the same one your other apps use), so the account never hits Apple's certificate limit.

### Samsung
Keep this repo **public** so her phone can download the app without a GitHub login. No passwords are in it: the Firebase key only identifies the project, and the signing certificate is encrypted.

1. On her phone, open this repo's **Releases** page and download **SkiFind.apk** from the newest release.
2. Open it and allow "Install unknown apps" for the browser if asked.

---

## Pairing (once)
1. On one phone: enter your name → **Start sharing**. You'll get a 6-letter **pair code**.
2. On the other phone: enter a name and the code → **Join**.

## Permissions (so it works while the app is closed)

**iPhone**
- Location: **Always**, with **Precise Location** on (the app shows a card until this is set).

**Samsung** – follow the cards at the bottom of the map:
1. Location → **Allow all the time**.
2. Notifications → Allow. Android shows a small "Sharing your location" notification while sharing; you can minimize it in notification settings.
3. Battery → **Allow** (unrestricted). Also, in Settings › Battery › Background usage limits, make sure Ski Find is **not** in "Sleeping apps".

## How updates work
- **Samsung:** checks GPS every minute. It sends a new spot after moving about 25 m, and at least every 10 minutes while sitting still.
- **iPhone:** iOS sends updates while you're moving. When you stop, GPS pauses, and moving about 120 m away (or iOS noticing a new place) wakes it again. It also relaunches the app in the background if it was closed.
- **On screen:** the map refreshes every 10 seconds, and opening the app sends a fresh position right away.

## Notes
- Removing someone (or leaving) deletes that phone's last location from the database.
- On iPhone, don't swipe Ski Find away in the app switcher: iOS may stop its updates until you open it again. Leaving it in the background is fine.
- Data stays well within Firebase's free daily limits.
