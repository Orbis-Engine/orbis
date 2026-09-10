Pod::Spec.new do |s|
  s.name             = 'orbis_filament'
  s.version          = '0.1.0'
  s.summary          = 'Filament rendering, composited by Flutter.'
  s.description      = <<-DESC
Renders with Google's Filament into IOSurface-backed CVPixelBuffers and hands
them to Flutter's texture registry, so a 3D scene composites with widgets
without a trip through the CPU.
                       DESC
  s.homepage         = 'https://github.com/Orbis-Engine/orbis'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Chris Beckett' => '49186278+ChxisB@users.noreply.github.com' }
  s.source           = { :path => '.' }
  # The sources sit in the layout Swift Package Manager wants — one directory
  # per target under Sources — and CocoaPods is pointed at them rather than
  # keeping a second copy. Both build systems compile the same files.
  src = 'orbis_filament/Sources'
  # Plain .cpp as well: the parts of the renderer with nothing Apple in them
  # (splat loading and sorting, so far) are C++ so every port can take them.
  s.source_files     = "#{src}/**/*.{h,m,mm,cpp,swift}"
  # The compiled material is an implementation detail and defines a symbol, so
  # it stays out of the umbrella header the module exposes.
  s.public_header_files = "#{src}/orbis_filament_native/include/*.h"
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'

  # Both Apple platforms from one spec, which is what the darwin/ layout is
  # for. 13.0 on iOS because that is where Filament's own minimum sits.
  s.ios.deployment_target = '13.0'
  s.osx.deployment_target = '10.15'
  s.swift_version = '5.0'
  s.static_framework = true

  # Fetches the Filament SDK and compiles materials. Idempotent, so it is free
  # after the first install.
  #
  # Under Swift Package Manager there is no equivalent hook — a package plugin
  # runs sandboxed with no network — so that path asks for the script to be run
  # once by hand. Package.swift says so if it has not been.
  s.prepare_command = 'bash setup.sh'

  # The xcframework setup.sh builds, rather than a list of archives from one
  # platform's SDK. It carries a slice per platform — macOS, an iOS device and
  # the iOS simulator — so one line here serves all three, and the same
  # artifact serves Swift Package Manager, which can take nothing else.
  s.vendored_frameworks = 'orbis_filament/third_party/Filament.xcframework'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'HEADER_SEARCH_PATHS' => [
      # The headers are the same API on both platforms, and the mac SDK is
      # fetched either way because it carries matc.
      '"$(PODS_TARGET_SRCROOT)/third_party/filament-mac/filament/include"',
      # Where the renderer's own headers moved to. A quoted include searches
      # the including file's directory, and that is no longer where they are.
      '"$(PODS_TARGET_SRCROOT)/orbis_filament/Sources/orbis_filament_native/include"',
    ].join(' '),
  }

  # Filament ships arm64 only in the mac release, so an Intel slice cannot be
  # built there. On iOS this must not be set: the simulator slice is a fat
  # archive and excluding x86_64 would rule out running on an Intel Mac.
  s.osx.pod_target_xcconfig = { 'EXCLUDED_ARCHS' => 'x86_64' }
  s.osx.user_target_xcconfig = { 'EXCLUDED_ARCHS' => 'x86_64' }

  # Metal on both. OpenGL is macOS-only and is there for Filament's GL backend,
  # which iOS has no use for and no framework to link — asking for it is what
  # made the first iOS build fail, at link, after everything had compiled.
  shared = ['Metal', 'MetalKit', 'CoreVideo', 'QuartzCore', 'IOSurface',
            'AVFoundation', 'CoreMedia', 'AudioToolbox']
  s.ios.frameworks = shared
  s.osx.frameworks = shared + ['OpenGL']
end
