#!/bin/zsh
# Zips the office's models, light probes and textures: the files the Mac app does not bundle (see project.yml).
# Prints the SHA-256 that OfficeAssets.swift pins. Publish the zip as a pre-release (it must never become the "latest" release,
# which is what Jack's update check reads):
#
#   gh release create office-assets-<N> build/office-assets/Jack-Office-Assets-<N>.zip --prerelease --title "Office assets <N>"
#
# Bump OfficeAssets.version when the files change.
set -euo pipefail
cd "${0:A:h:h}"
version=$(sed -n 's/.*static let version = \([0-9]*\).*/\1/p' Sources/Jack/Office/OfficeAssets.swift)
out=build/office-assets
rm -rf $out; mkdir -p $out/stage
cp Resources/Office/Runtime/*.usdz Resources/Office/Runtime/*.exr Resources/Office/Runtime/OfficeBake_*.jpg Resources/Office/Runtime/OfficeDetail_*.jpg $out/stage/
zip=$out/Jack-Office-Assets-$version.zip
(cd $out/stage && ditto -c -k --sequesterRsrc . ../${zip:t})
rm -rf $out/stage
print "Zip: $zip ($(du -h $zip | cut -f1))"
print "Bytes: $(stat -f %z $zip)"
print "SHA-256: $(shasum -a 256 $zip | cut -d' ' -f1)"
