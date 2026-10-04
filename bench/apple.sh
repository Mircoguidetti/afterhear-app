#!/bin/sh
# Apple's recognisers on the bench's clips, on a real Mac (docs/BRAIN.md § 19.21).
# Run inside the unzipped bench-clips folder:  sh apple.sh
# Speech recognition asked from Terminal gets killed (zsh: abort): macOS wants an app that
# says why it asks. So the program goes inside a small app, opened with `open`.
set -e
cd "$(dirname "$0")"
swiftc -O -parse-as-library apple.swift -o apple
rm -rf Bench.app && mkdir -p Bench.app/Contents/MacOS
cp apple Bench.app/Contents/MacOS/apple
cp Info.plist Bench.app/Contents/Info.plist
# The app's own program is a two-line script: it runs the bench here and keeps what it says.
printf '#!/bin/sh\ncd "%s"\nexec ./Bench.app/Contents/MacOS/apple . > apple.jsonl 2> apple.log\n' "$PWD" > Bench.app/Contents/MacOS/run
chmod +x Bench.app/Contents/MacOS/run
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string run" -c "Add :CFBundlePackageType string APPL" Bench.app/Contents/Info.plist
codesign -s - --force --deep Bench.app
echo "Running (a few minutes). Allow speech recognition if asked."
open -W Bench.app
cat apple.log
open .
