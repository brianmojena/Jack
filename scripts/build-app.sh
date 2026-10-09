#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# VoiceKey.swift holds the Groq key and is git-ignored; a fresh clone gets an empty one so it still builds.
key=Sources/JackCore/VoiceKey.swift
[[ -f $key ]] || print '// Local only: this file is ignored by git so the key is never published.\nenum VoiceKey {\n    static let value = ""\n}' > $key
xcodegen generate
xcodebuild -project Jack.xcodeproj -scheme Jack -configuration Release -derivedDataPath build -skipPackagePluginValidation build
print "App: $PWD/build/Build/Products/Release/Jack.app"
