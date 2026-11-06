#!/bin/zsh
# Builds Mac Pro Monitor.app with the settings in .env and installs it into ~/Applications.
set -eu
cd ${0:A:h}
[[ -f .env ]] || { echo "build.sh: no .env; copy .env.example to .env and fill it in" >&2; exit 1; }
set -a
source ./.env
set +a
: ${REMOTE_HOST:?set REMOTE_HOST in .env}

APP="build/Mac Pro Monitor.app"
PLIST="$APP/Contents/Info.plist"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/AppIcon.iconset
xcrun swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14 \
  -o "$APP/Contents/MacOS/MacProMonitor" Sources/*.swift
cp Info.plist "$PLIST"
plutil -replace CFBundleIdentifier -string "${BUNDLE_ID:-com.example.MacProMonitor}" "$PLIST"
plutil -replace MPMRemoteHost -string "$REMOTE_HOST" "$PLIST"
plutil -replace MPMIdentityFile -string "${SSH_IDENTITY_FILE:-}" "$PLIST"
plutil -replace MPMUnityEnvKeys -string "${UNITY_ENV_KEYS:-}" "$PLIST"

"$APP/Contents/MacOS/MacProMonitor" --render-icon build/icon.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s * 2)) $((s * 2)) build/icon.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# A real identity keeps the Local Network permission across rebuilds; an ad-hoc one asks again every build.
IDENTITY=${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -o '"Apple Development[^"]*"' | head -1 | tr -d '"')}
codesign --force --sign "${IDENTITY:--}" "$APP"

mkdir -p ~/Applications
rm -rf ~/Applications/"Mac Pro Monitor.app"
cp -R "$APP" ~/Applications/
echo "installed ~/Applications/Mac Pro Monitor.app"
