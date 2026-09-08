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
  s.source_files     = "#{src}/**/*.{h,m,mm,swift}"
  # The compiled material is an implementation detail and defines a symbol, so
  # it stays out of the umbrella header the module exposes.
  s.public_header_files = "#{src}/orbis_filament_native/include/*.h"
  s.dependency 'FlutterMacOS'

  s.platform = :osx, '10.15'
  s.swift_version = '5.0'
  s.static_framework = true

  # Fetches the Filament SDK and compiles materials. Idempotent, so it is free
  # after the first install.
  #
  # Under Swift Package Manager there is no equivalent hook — a package plugin
  # runs sandboxed with no network — so that path asks for the script to be run
  # once by hand. Package.swift says so if it has not been.
  s.prepare_command = 'bash setup.sh'

  # Listed rather than globbed: the SDK ships thirty archives and this is the
  # dozen the renderer actually needs. Vendored rather than passed as linker
  # flags, because a static pod archives instead of linking and flags set on
  # the pod target never reach the application that consumes it.
  lib = 'third_party/filament-mac/filament/lib/arm64'
  #
  # The second row is what gltfio pulls in: the loader itself, the pre-built
  # ubershaders it makes materials from, and the decoders for the formats a
  # glTF file can carry its geometry and textures in.
  s.vendored_libraries = %w[
    filament backend bluegl bluevk filabridge filaflat
    utils geometry smol-v ibl abseil zstd

    gltfio_core uberarchive uberzlib dracodec meshoptimizer ktxreader
    stb basis_transcoder mikktspace
  ].map { |name| "#{lib}/lib#{name}.a" }

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'HEADER_SEARCH_PATHS' => [
      '"$(PODS_TARGET_SRCROOT)/third_party/filament-mac/filament/include"',
      # Where the renderer's own headers moved to. A quoted include searches
      # the including file's directory, and that is no longer where they are.
      '"$(PODS_TARGET_SRCROOT)/orbis_filament/Sources/orbis_filament_native/include"',
    ].join(' '),
    # Filament ships arm64 only in the mac release.
    'EXCLUDED_ARCHS' => 'x86_64',
  }
  s.user_target_xcconfig = { 'EXCLUDED_ARCHS' => 'x86_64' }
  s.frameworks = 'Metal', 'MetalKit', 'CoreVideo', 'QuartzCore', 'IOSurface', 'OpenGL',
                 'AVFoundation', 'CoreMedia', 'AudioToolbox'
end
