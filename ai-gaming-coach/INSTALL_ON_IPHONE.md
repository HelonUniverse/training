# Install AI Gaming Coach on your iPhone

No Terminal, Homebrew or XcodeGen needed: the Xcode project is ready to open.

## 0. Before you start (5 minutes)

**Check the iPhone's iOS version:** iPhone → **Settings → General → About → iOS Version**. Write it down.

| iPhone iOS | What you can test | Xcode you need on the Mac |
|---|---|---|
| iOS 27 or later | ReplayKit **and** ScreenCaptureKit | Xcode 27 |
| iOS 17 – 26 | ReplayKit only (ScreenCaptureKit is hidden, not broken) | Xcode 26 or 27 (Xcode 16 for iOS 17–18) |

**Check Xcode on the Mac:** open **Xcode → Xcode menu (top-left) → About Xcode**. If it's missing or older than the table says, install/update it from the Mac App Store (search "Xcode"). The first launch downloads extra components: accept them.

**Sign in to your Apple account in Xcode:** **Xcode → Settings… → Accounts** → if your Apple ID isn't listed, click **+** (bottom-left) → **Apple ID** → sign in. A free Apple ID works; a paid Developer Program account works too.

## 1. Get the project onto the Mac

1. In Safari, sign in to GitHub and open
   `https://github.com/HelonUniverse/training/archive/refs/heads/claude/ai-gaming-coach-ios-rhjf0d.zip`
   (it downloads a ZIP).
2. Open **Downloads** in Finder and double-click the ZIP. You get a folder named **`training-claude-ai-gaming-coach-ios-rhjf0d`**.
3. Open that folder → **`ai-gaming-coach`** → double-click **`AIGamingCoach.xcodeproj`** (blue icon). If macOS asks whether to open a project downloaded from the internet, click **Open**.

## 2. Choose your team (signing) — twice, once per target

The project has two parts ("targets") that iOS installs together: the app, **AIGamingCoach**, and its screen-broadcast plug-in, **BroadcastExtension**. Each needs your team.

1. In Xcode's left sidebar, click the top blue item **AIGamingCoach**.
2. In the middle panel, under **TARGETS**, click **AIGamingCoach**.
3. Click the **Signing & Capabilities** tab.
4. Make sure **Automatically manage signing** is checked.
5. **Team** → choose your name/team (a free account shows "*Your Name* (Personal Team)").
6. Under **TARGETS**, now click **BroadcastExtension** and repeat steps 3–5 with the **same** team.

In both targets you should see:
- **Bundle Identifier**: `com.heloniuminnovation.aigamingcoach` (app) and `com.heloniuminnovation.aigamingcoach.broadcast` (extension).
- **App Groups** with `group.com.heloniuminnovation.aigamingcoach` **checked**. If the box is unchecked or red, check it; if a red message says the group couldn't be registered, click **Try Again**.
- No red error text under Signing. (Yellow text that goes away after a few seconds is Xcode creating your profiles.)

## 3. Prepare the iPhone (first time only)

1. Connect the iPhone to the Mac with a USB cable and unlock it.
2. iPhone asks **"Trust This Computer?"** → **Trust** → enter the iPhone passcode.
3. In Xcode's top bar, click the device menu (to the right of **AIGamingCoach**, it says something like "Any iOS Device") and pick **your iPhone** from the list.
4. **Developer Mode** (required to run apps from Xcode): on the iPhone open **Settings → Privacy & Security → Developer Mode** (near the bottom) → turn it **on** → **Restart**. After the restart, unlock the phone and tap **Turn On** → enter passcode. If you don't see Developer Mode yet, do step 5 first, then come back — it appears once Xcode has talked to the phone.
5. Xcode may show "Preparing iPhone…" / "Copying shared cache symbols" for several minutes the first time. Wait until it finishes.

No other permissions are needed: the app doesn't use the camera, microphone, location, local network, photos or notifications.

## 4. Run

1. Top bar should read **AIGamingCoach › *your iPhone*** (if it says BroadcastExtension, click it and choose **AIGamingCoach**).
2. Press **▶︎ Run** (or ⌘R).
3. If the Mac asks for your **login password for "codesign"** → type your Mac password → **Always Allow** (it may ask 2–3 times).
4. **Free Apple ID only:** the first run may say the developer isn't trusted. On the iPhone: **Settings → General → VPN & Device Management** → tap your Apple ID under Developer App → **Trust**. Then press **▶︎ Run** again. (Free-account installs expire after 7 days; just press Run again.)

**Success looks like:** the app opens on the iPhone (home-screen label **AI Coach**, plain white icon) showing **AI GAMING COACH**, Game **Fortnite**, Platform **iPhone**, a big **START COACHING** button and a **Status** box with "Screen capture: Not connected". On iOS 27 you also see a **Capture provider** switch (ScreenCaptureKit | ReplayKit). An orange warning about an App Group means signing step 2 isn't finished for both targets.

You can unplug the iPhone after it launches. Leave Xcode alone; if you stop it with ■, just open the app from the home screen.

## 5. Test 1 — ReplayKit smoke test (2–3 minutes)

1. Open **AI Coach**. On iOS 27, tap **ReplayKit** in **Capture provider**.
2. Tap **START COACHING**. An Apple sheet titled **Screen Broadcast** appears, listing broadcast destinations. **AI Gaming Coach** must be the selected one (checkmark). Keep **Microphone** off.
3. Tap **Start Broadcast** → a 3-second countdown → close the sheet. The status bar / Dynamic Island turns **red** (that's iOS recording) and the app shows **Screen capture: Connected** and a red **Screen capture is active** box.
   - If tapping START COACHING does nothing, use Control Center instead: swipe down from the top-right → **long-press** the Screen Recording button (⏺) → pick **AI Gaming Coach** → **Start Broadcast**. (If the button isn't there: Settings → Control Center, add Screen Recording.)
4. Open **Fortnite**, enter a match (any mode), play ~2 minutes including at least one fight.
5. Switch back to **AI Coach** (swipe up from the bottom edge and pick it). Without stopping, tap the **🐞 (ladybug)** icon: **Frames received** should be increasing every second — capture survived the return.
6. Stop: tap the red status indicator / Dynamic Island → **Stop**, or Control Center → ⏺.
7. Back in AI Coach the **Session Summary** opens by itself (if not: Home → **Last session summary**).

**Did real Fortnite gameplay arrive? Check the Summary:**
- **Keyframes**: scroll the thumbnails. There's one every 5 s with its time. You must see **Fortnite gameplay** in the ones taken while you were playing — not only the Coach app or the home screen, and not black.
- **Frames received** in the thousands, **Duration** ≈ your test length, **Near-black frames** ≈ 0 %.
- **Play rolling buffer**: plays the last ~90 s of captured video.
- **Event timeline** should end with `captureFinished`.

Only "Screen capture: Connected" is **not** proof — the keyframe thumbnails of gameplay are.

8. In the Summary tap **Device test result** → fill in iPhone model, Fortnite version (in Fortnite: Settings, bottom of the menu), and the yes/no questions → **Copy DEVICE TEST RESULT**. Paste it somewhere (Notes).

## 6. Test 2 — ScreenCaptureKit smoke test (iOS 27 only, 2–3 minutes)

1. Open **AI Coach** → **Capture provider** → **ScreenCaptureKit**.
2. Tap **START COACHING**. Apple's **screen-sharing picker** appears: it asks what to share. Choose the option to share the **entire screen** (not "this app only") and confirm. If iOS asks for permission to record the screen, **Allow**. The button changes to **STOP COACHING** and the red capture box appears.
3. Open **Fortnite**, play ~2 minutes including one fight.
4. Return to **AI Coach** → 🐞 Debug: **Frames received** must keep increasing, and **Frames without image** should stay near 0.
5. Tap **STOP COACHING** (or stop from the red indicator / Control Center).
6. Check the Summary exactly as in Test 1 — **the keyframes taken while Fortnite was on screen must show gameplay**. If there are none from that period, or they're black, or the Summary says *failed* (e.g. `missingBackgroundMode`), ScreenCaptureKit did **not** keep capturing behind Fortnite: that is the result, write it down.
7. **Device test result** → fill in → **Copy DEVICE TEST RESULT**.

## 7. Comparison

After both tests: Home → top-right **▭▭ (split rectangle)** icon → **Copy CAPTURE PROVIDER COMPARISON**.

Once both short tests pass, repeat each with a full 10–15-minute match.

## If something goes wrong

| Message | Fix |
|---|---|
| "No account for team" / Team is empty | Step 0: sign in under Xcode → Settings → Accounts, then step 2. |
| "Failed to register bundle identifier … not available" | The ID is taken by another team. Tell me; I'll change it in the project. |
| "iOS 27.x is not supported by this version of Xcode" / "Device not available" | Update Xcode (step 0 table). |
| "Developer Mode disabled" | Step 3.4. |
| "Untrusted Developer" on the iPhone | Step 4.4. |
| App shows an orange App Group warning | Step 2 wasn't completed for **both** targets. |
| Broadcast sheet doesn't list AI Gaming Coach | Run once more from Xcode, then reboot the iPhone. |
| Screen Recording is blocked | Settings → Screen Time → Content & Privacy Restrictions → Content Restrictions → Screen Recording → Allow. |
