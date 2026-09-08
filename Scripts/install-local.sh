#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
cd "$project_dir"
identity=${AETHER_SIGNING_IDENTITY:-Ice Local Code Signing}
installed=/Applications/Aether.app
built="$project_dir/.build/Xcode/Build/Products/Release/Aether.app"
mkdir -p .build/logs
swift test --package-path Packages/AetherKit > .build/logs/tests.log 2>&1 || { tail -60 .build/logs/tests.log; exit 1; }
xcodebuild -project Aether.xcodeproj -scheme Aether -configuration Release -derivedDataPath .build/Xcode -clonedSourcePackagesDirPath Packages/AetherKit/.build -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO build > .build/logs/build.log 2>&1 || { tail -70 .build/logs/build.log; exit 1; }
[[ -d "$built" ]]
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$built/Contents/Info.plist") == com.liyuan.aether ]]
codesign --force --deep --options runtime --sign "$identity" "$built"
codesign --verify --deep --strict "$built"
if [[ -e "$installed" ]]; then
    [[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$installed/Contents/Info.plist") == com.liyuan.aether ]] || { print -u2 'Refusing to replace unrelated application.'; exit 1; }
fi
staging_dir=$(mktemp -d "$project_dir/.build/install.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT
ditto "$built" "$staging_dir/Aether.app"
codesign --verify --deep --strict "$staging_dir/Aether.app"
if [[ -d "$installed" ]]; then ditto "$installed" "$staging_dir/previous.app"; fi
xcrun swift Scripts/stop-app.swift com.liyuan.aether
restore_previous() {
    xcrun swift Scripts/stop-app.swift com.liyuan.aether || return 1
    if [[ -d "$staging_dir/previous.app" ]]; then
        rm -rf /Applications/Aether.app
        ditto "$staging_dir/previous.app" /Applications/Aether.app
        open /Applications/Aether.app
    fi
}
rm -rf /Applications/Aether.app
if ! ditto "$staging_dir/Aether.app" "$installed"; then restore_previous; exit 1; fi
if ! open "$installed"; then restore_previous; exit 1; fi
for attempt in {1..40}; do
    running_pids=(${(f)$(pgrep -x Aether || true)})
    if [[ ${#running_pids} -eq 1 ]]; then
        executable=$(ps -p "$running_pids[1]" -o comm=)
        if [[ "$executable" == /Applications/Aether.app/Contents/MacOS/Aether ]]; then
            codesign --verify --deep --strict "$installed"
            source_hash=$(shasum -a 256 "$built/Contents/MacOS/Aether" | cut -d ' ' -f 1)
            installed_hash=$(shasum -a 256 "$installed/Contents/MacOS/Aether" | cut -d ' ' -f 1)
            [[ "$source_hash" == "$installed_hash" ]] || { restore_previous; exit 1; }
            print 'TESTS_OK BUILD_OK SIGNATURE_OK SINGLE_INSTALLED_INSTANCE_OK'
            print "Installed and launched $installed"
            exit 0
        fi
    fi
    sleep 0.25
done
restore_previous
print -u2 'Single installed instance verification failed.'
exit 1
