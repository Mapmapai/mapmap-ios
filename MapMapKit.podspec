# Template for the MapMapKit CocoaPods podspec (PLATFORM-GOTCHAS.md 1.3).
#
# Rendered by .github/workflows/release-ios.yml (0.3.0 substituted per
# release) and committed to the ROOT of the public distribution repo
# (Mapmapai/mapmap-ios) so CocoaPods / Expo integrators link the prebuilt
# binary instead of vendoring the SDK + Valhalla + boost:
#
#   pod 'MapMapKit', podspec: 'https://raw.githubusercontent.com/Mapmapai/mapmap-ios/main/MapMapKit.podspec'
#
# (or `pod trunk push MapMapKit.podspec` once the pod is registered on the
# CocoaPods CDN, after which a plain `pod 'MapMapKit'` works.)
#
# The vendored MapMapKit.xcframework is the FULL Swift SDK (Rust core
# linked in, resources bundled) built by ios/build-mapmapkit-xcframework.sh
# and attached to the versioned GitHub release on Mapmapai/mapmap-ios.
Pod::Spec.new do |s|
  s.name         = 'MapMapKit'
  s.version      = '0.3.0'
  s.summary      = 'MapMap iOS SDK — fully offline turn-by-turn navigation'
  s.description  = <<-DESC
    Signed offline territory packages, on-device routing, Ferrostar-based
    guidance, voice guidance and drive-corpus replay. This pod ships the
    SDK as a prebuilt binary XCFramework (device + simulator), so apps and
    React Native/Expo modules link it without compiling the native core.
    On-device Valhalla routing (the MapMapValhalla product) remains a
    SwiftPM-only add-on for now.
  DESC
  s.homepage     = 'https://mapmap.ai'
  s.authors      = 'Mapmap AI Ltd'
  s.license      = {
    type: 'Commercial',
    text: 'Copyright (c) 2026 Mapmap AI Ltd. All rights reserved. Use requires a written commercial agreement with Mapmap AI Ltd and a valid MapMap gateway API key. See https://github.com/Mapmapai/mapmap-ios/blob/main/LICENSE',
  }
  s.platforms    = { :ios => '16.4' }
  s.swift_version = '5.9'

  s.source = {
    http: "https://github.com/Mapmapai/mapmap-ios/releases/download/#{s.version}/MapMapKit.xcframework.zip",
  }

  s.vendored_frameworks = 'MapMapKit.xcframework'

  s.frameworks = 'CoreLocation', 'AVFoundation'
  s.libraries  = 'z', 'c++'
end
