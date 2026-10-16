#!/bin/zsh
# Builds BuildCloud.app (with the `buildcloud` CLI inside) into BuildCloud/build/.
set -euo pipefail
cd "${0:A:h:h}"

# La web (Svelte) se incrusta en Sources/BuildCloudCore/WebApp.swift antes de compilar.
scripts/build-web.sh

swift build -c release --product BuildCloudApp
swift build -c release --product buildcloud
bin=$(swift build -c release --show-bin-path)

app=build/BuildCloud.app
rm -rf $app
mkdir -p $app/Contents/MacOS $app/Contents/Helpers $app/Contents/Resources
cp "$bin/BuildCloudApp" $app/Contents/MacOS/BuildCloud
cp "$bin/buildcloud" $app/Contents/Helpers/buildcloud
cp Resources/Info.plist $app/Contents/Info.plist
codesign --force --sign - $app/Contents/Helpers/buildcloud
codesign --force --sign - $app

print "App: $PWD/$app"
print "CLI: $PWD/$app/Contents/Helpers/buildcloud"
