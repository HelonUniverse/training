#!/usr/bin/env bash
set -euo pipefail
app=$(find build/Build/Products -maxdepth 3 -name "AIGamingCoach.app" | head -1)
ls "$app/PlugIns"
/usr/libexec/PlistBuddy -c "Print :NSExtension" "$app/PlugIns/BroadcastExtension.appex/Info.plist"
