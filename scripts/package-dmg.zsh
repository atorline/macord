#!/bin/zsh
set -euo pipefail

root_dir="${0:A:h:h}"
cd "$root_dir"

version="${MACORD_VERSION:-0.1.0}"
configuration="${MACORD_CONFIGURATION:-release}"
app_name="Macord"
app_dir="$root_dir/dist/$app_name.app"
dmg_path="$root_dir/dist/$app_name-$version-intel.dmg"

rm -rf "$root_dir/dist"
mkdir -p "$root_dir/dist"

print "[package] building Rust FFI ($configuration)..."
cargo build -p macord-ffi --profile "$configuration"

print "[package] building Swift executable ($configuration)..."
swift build -c "$configuration"

swift_dir="$root_dir/.build/$configuration"
rust_dir="$root_dir/target/$configuration"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Frameworks" "$app_dir/Contents/Resources"

cp "$swift_dir/$app_name" "$app_dir/Contents/MacOS/$app_name"
cp "$rust_dir/libmacord_ffi.dylib" "$app_dir/Contents/Frameworks/libmacord_ffi.dylib"
cp "$root_dir/macos/Info.plist" "$app_dir/Contents/Info.plist"

if [[ -f "$root_dir/assets/AppIcon.icns" ]]; then
  cp "$root_dir/assets/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
  print "[package] included assets/AppIcon.icns"
else
  print "[package] no icon found; continuing without custom icon"
fi

install_name_tool -id "@rpath/libmacord_ffi.dylib" "$app_dir/Contents/Frameworks/libmacord_ffi.dylib"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$app_dir/Contents/MacOS/$app_name" 2>/dev/null || true

print "[package] ad-hoc signing app bundle..."
codesign --force --deep --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"

print "[package] creating DMG..."
hdiutil create \
  -volname "$app_name" \
  -srcfolder "$app_dir" \
  -ov \
  -format UDZO \
  "$dmg_path" >/dev/null

print "[package] ready: $dmg_path"
print "[package] app:   $app_dir"
