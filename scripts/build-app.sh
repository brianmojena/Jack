#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
xcodegen generate
xcodebuild -project Jack.xcodeproj -scheme Jack -configuration Release -derivedDataPath build build
print "App: $PWD/build/Build/Products/Release/Jack.app"
