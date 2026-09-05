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
  s.author           = { 'Orbis Engine' => 'orbis@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.{h,m,mm,swift}'
  # The compiled material is an implementation detail and defines a symbol, so
  # it stays out of the umbrella header the module exposes.
  s.public_header_files = 'Classes/OrbisRenderer.h', 'Classes/OrbisTexture.h'
  s.dependency 'FlutterMacOS'

  s.platform = :osx, '10.15'
  s.swift_version = '5.0'
  s.static_framework = true

  # Fetches the Filament SDK and compiles materials. Idempotent, so it is free
  # after the first install.
  #
  # This is also why the plugin is CocoaPods rather than Swift Package Manager,
  # and why Flutter warns about it. A Swift package cannot do this: its plugins
  # run sandboxed with no network, so nothing in one can fetch a hundred
  # megabytes of renderer at build time. Adopting SPM means shipping Filament
  # as a binary target — an .xcframework with a URL and a checksum — which is a
  # release artefact to host and version rather than a file to write.
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
    'HEADER_SEARCH_PATHS' =>
      '"$(PODS_TARGET_SRCROOT)/third_party/filament-mac/filament/include"',
    # Filament ships arm64 only in the mac release.
    'EXCLUDED_ARCHS' => 'x86_64',
  }
  s.user_target_xcconfig = { 'EXCLUDED_ARCHS' => 'x86_64' }
  s.frameworks = 'Metal', 'MetalKit', 'CoreVideo', 'QuartzCore', 'IOSurface', 'OpenGL'
end
