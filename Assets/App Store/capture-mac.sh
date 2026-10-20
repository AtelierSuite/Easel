#!/bin/zsh
# Captures raw Mac App Store screenshots into Raw/Mac/<language>/.
# Usage: ./capture-mac.sh [languages...]   (defaults to en ja)
#
# The AppStoreSamples unit test paints the same documents the iOS screenshots
# open, on an iPhone simulator. Each shot then launches the Mac app's debug
# build on one of them; its ScreenshotStaging hook sets the editor up in a
# 1440 × 900 window on the Retina screen and says which window to capture.
# The Mac has to be awake and unlocked. Run compose-mac.swift afterwards to
# frame them.
set -e

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h:h}
BUNDLE_ID=com.tsubuzaki.Easel
DERIVED_DATA=/tmp/easel-screenshots-dd
MAC_DERIVED_DATA=/tmp/easel-screenshots-mac-dd
LANGUAGES=($@)
(( $# )) || LANGUAGES=(en ja)
# The app is sandboxed, so what it opens and writes lives in its container.
CONTAINER=~/Library/Containers/$BUNDLE_ID/Data
STAGE=$CONTAINER/Documents/Screenshots
WINDOW_FILE=$CONTAINER/tmp/screenshot-window

# name|document (en)|document (ja)|tool|panel|layer (en)|layer (ja)|swatch
SHOTS=(
  "01-paint|Poppy Study|ポピーの習作|brush|layers|||0"
  "02-filters|Lakeside Evening|湖畔の夕暮れ|brush|filters|Sky|空|"
  "03-design|Summer Festival|夏まつり|text|text|Summer Festival|夏まつり|"
)

# MARK: - Samples

# Painted by the iOS unit test on the screenshot harness's own iPhone
# simulator, as capture.sh does.
simulator() {
  local name="Easel Screenshots iPhone" udid
  udid=$(xcrun simctl list devices available | grep "$name (" | head -1 | grep -oE '[0-9A-F-]{36}' || true)
  if [[ -z $udid ]]; then
    udid=$(xcrun simctl create "$name" com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro-Max com.apple.CoreSimulator.SimRuntime.iOS-27-0)
  fi
  echo $udid
}

xcodebuild build-for-testing -project "$PROJECT_DIR/Easel.xcodeproj" -scheme Easel \
  -destination "generic/platform=iOS Simulator" -derivedDataPath $DERIVED_DATA -quiet
XCTESTRUN=$(ls $DERIVED_DATA/Build/Products/*.xctestrun | head -1)

SAMPLES=$(mktemp -d -t easel-samples)
trap 'rm -rf "$SAMPLES" "$STAGE"; rm -f "$WINDOW_FILE"' EXIT
udid=$(simulator)
xcrun simctl boot $udid 2>/dev/null || true
xcrun simctl bootstatus $udid -b >/dev/null
log=$(mktemp)
if ! TEST_RUNNER_SAMPLES_DIR=$SAMPLES xcodebuild test-without-building -xctestrun $XCTESTRUN \
    -destination "id=$udid" -only-testing:EaselTests/AppStoreSamples/testWriteSamples >$log 2>&1; then
  grep -E "error: -\[" $log || tail -20 $log
  rm -f $log
  exit 1
fi
rm -f $log
echo "painted samples"

# MARK: - Build

xcodebuild build -project "$PROJECT_DIR/Easel.xcodeproj" -scheme "Easel for Mac" \
  -destination "platform=macOS" -configuration Debug -derivedDataPath $MAC_DERIVED_DATA -quiet
APP=$MAC_DERIVED_DATA/Build/Products/Debug/Easel.app/Contents/MacOS/Easel

# MARK: - Capture

capture() {
  local language=$1 name=$2 document=$3 tool=$4 panel=$5 layer=$6 swatch=$7
  local raw_dir="$SCRIPT_DIR/Raw/Mac/$language" app_pid
  # A fresh copy each time: autosave would keep whatever a shot changed.
  rm -rf "$STAGE/$language"
  mkdir -p "$raw_dir" "$STAGE/$language" "${WINDOW_FILE:h}"
  cp -R "$SAMPLES/$language/$document.easel" "$STAGE/$language/"
  rm -f $WINDOW_FILE

  local arguments=(
    -ApplePersistenceIgnoreState YES
    -AppleLanguages "($language)" -AppleLocale $([[ $language == ja ]] && echo ja_JP || echo en_US)
    -ScreenshotDocument "$STAGE/$language/$document.easel"
    -ScreenshotWindowFile "$WINDOW_FILE"
    -ScreenshotTool $tool -ScreenshotPanel $panel
  )
  [[ -n $layer ]] && arguments+=(-ScreenshotLayer "$layer")
  [[ -n $swatch ]] && arguments+=(-ScreenshotSwatch $swatch)
  "$APP" $arguments >/dev/null 2>&1 &
  app_pid=$!

  local waited=0
  while [[ ! -s $WINDOW_FILE ]] && kill -0 $app_pid 2>/dev/null && (( waited < 60 )); do
    sleep 0.5
    (( waited += 1 ))
  done
  if [[ -s $WINDOW_FILE ]] && screencapture -x -o -l$(cat $WINDOW_FILE) "$raw_dir/$name.png"; then
    echo "captured Mac/$language/$name"
  else
    echo "failed to capture Mac/$language/$name"
  fi
  kill $app_pid 2>/dev/null || true
  wait $app_pid 2>/dev/null || true
}

# The debug build any other run left open would take the documents itself.
pkill -f "$APP" 2>/dev/null || true
for language in $LANGUAGES; do
  for shot in $SHOTS; do
    IFS='|' read -r name en ja tool panel layer_en layer_ja swatch <<< "$shot"
    if [[ $language == ja ]]; then
      capture $language $name "$ja" $tool $panel "$layer_ja" "$swatch"
    else
      capture $language $name "$en" $tool $panel "$layer_en" "$swatch"
    fi
  done
done
