#!/bin/zsh
# Builds Jack, zips it and publishes it as a GitHub release, which is what Jack's update check reads.
# Without --publish it only builds the zip: nothing leaves this Mac.
#
#   scripts/release.sh [--publish] [--notes "text"] [--allow-dirty]
#
# Bump CFBundleShortVersionString and CFBundleVersion in Resources/Info.plist and commit and push before publishing:
# the tag vX.Y.Z is created on the pushed commit.
set -euo pipefail
cd "${0:A:h:h}"

repo="brianmojena/Jack"
publish=0
dirty_ok=0
notes=""
while (( $# )); do
  case $1 in
    --publish) publish=1 ;;
    --allow-dirty) dirty_ok=1 ;;
    --notes) shift; notes=${1:?--notes necesita un texto} ;;
    *) print -u2 "Uso: scripts/release.sh [--publish] [--notes \"texto\"] [--allow-dirty]"; exit 2 ;;
  esac
  shift
done

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
tag="v$version"
commit=$(git rev-parse HEAD)

if [[ -n $(git status --porcelain --untracked-files=no) ]] && (( ! dirty_ok )); then
  print -u2 "Hay cambios sin commitear: el zip no correspondería al commit $tag. Haz commit o usa --allow-dirty."
  exit 1
fi

previous=""
if (( publish )); then
  command -v gh >/dev/null || { print -u2 "Falta gh (GitHub CLI)."; exit 1 }
  if gh release view $tag --repo $repo >/dev/null 2>&1; then
    print -u2 "La versión $tag ya está publicada: sube la versión en Resources/Info.plist."; exit 1
  fi
  git fetch --quiet origin
  if ! git branch -r --contains $commit | grep -q .; then
    print -u2 "El commit ${commit[1,7]} no está en GitHub: haz push antes de publicar."; exit 1
  fi
  previous=$(gh release view --repo $repo --json tagName --jq .tagName 2>/dev/null || true)
fi

if [[ -z $notes ]]; then
  if [[ -n $previous ]] && git rev-parse -q --verify "refs/tags/$previous" >/dev/null; then
    notes=$(git log --format='- %s' "$previous..HEAD")
  else
    notes="- $(git log -1 --format=%s)"
  fi
fi

scripts/build-app.sh
app=build/Build/Products/Release/Jack.app
[[ -d $app ]] || { print -u2 "No existe $app"; exit 1 }

built=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $app/Contents/Info.plist)
[[ $built == $version ]] || { print -u2 "La app compilada es la $built, no la $version."; exit 1 }

out=build/release
rm -rf $out && mkdir -p $out
zip=$out/Jack-$version.zip
ditto -c -k --sequesterRsrc --keepParent $app $zip
print "Zip: $zip ($(du -h $zip | cut -f1))"

if (( publish )); then
  gh release create $tag $zip --repo $repo --target $commit --title "Jack $version" --notes "$notes"
  print "Publicado: https://github.com/$repo/releases/tag/$tag"
else
  print "Sin --publish: no se ha subido nada. Notas que llevaría:"
  print -r -- "$notes"
fi
