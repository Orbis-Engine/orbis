# A Linux machine for Orbis, for a development host that is not one.
#
# There is no Linux box here, so the Linux plugin is built and run in this
# container: Flutter's Linux toolchain, a software GPU, and the three fixes
# Filament's Linux release needs. Each of those three cost a build to find,
# so they are written down here rather than rediscovered --
# packages/orbis_filament/native/headless/build_linux.sh found them first and
# its header comment is the longer account.
#
#   1. trixie, not bookworm. Filament 1.76's Linux release needs glibc 2.38
#      or newer; bookworm ships 2.36 and the link fails on the version node.
#   2. libc++, not libstdc++. That release is built against LLVM's standard
#      library, so its archives name symbols in namespace std::__1 that
#      libstdc++ has none of. The flag belongs on the compile line as well as
#      the link line, which is why linux/CMakeLists.txt carries both.
#   3. --start-group round the archive list, because Filament's static
#      libraries refer to each other both ways and ld reads an archive once.
#      That one lives in linux/CMakeLists.txt, not here.
#
# The software GPU is Mesa's: llvmpipe answers OpenGL and lavapipe answers
# Vulkan, so a container with no GPU at all still draws. Filament asks for
# Vulkan first off Apple and falls back to OpenGL, and both are present here
# so whichever it picks has something to run on.
#
# Build it:
#   docker build -t orbis-linux:trixie tool/linux_container
#
# Then, from the repository root, with <project> the directory the .cache of
# unpacked Filament releases sits in (ORBIS_FILAMENT_LINUX_DIR is optional --
# without it setup.sh fetches the release itself, which costs a 53 MB
# download per fresh container rather than reusing what is already unpacked):
#
#   docker run --rm -v "$PWD:/work" -v "<project>/.cache:/cache:ro" \
#     -v orbis-pub-cache:/root/.pub-cache \
#     -e ORBIS_FILAMENT_LINUX_DIR=/cache/filament-1.76.0/arm-linux/filament \
#     orbis-linux:trixie \
#     bash -c 'cd /work/examples/gallery && flutter pub get && flutter build linux --debug'
#
# and tool/ci_draw_frame_linux.sh to make it draw one.
#
# The pub cache has to be one of those two -- either a volume that outlives
# the container, or a `pub get` in the same `docker run` as the build -- and
# the failure when it is neither is worth knowing, because it names nothing
# to do with pub. `flutter pub get` writes .dart_tool/package_config.json
# into the checkout, where the bind mount keeps it, but the packages it
# points at live in /root/.pub-cache, which `--rm` throws away. The next
# container therefore starts with a package_config naming forty-odd
# directories that do not exist, and the first thing to miss one is Flutter
# itself: the build fails with "'Matrix4' isn't a type" inside
# flutter/lib/src/semantics/semantics.dart, because vector_math is gone.
#
# The same mount is also why a checkout used from both sides needs
# `flutter pub get` run again on the host after a container build, and the
# other way round: the one package_config.json they share can only hold one
# machine's paths at a time.
FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive

# clang and libc++ for the reasons above; the gtk/egl/gles development
# packages are what Flutter's own Linux build requires; xvfb and the mesa
# drivers are what let the built application open a window and draw without
# a display or a GPU.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git unzip xz-utils zip file \
      clang lld libc++-dev libc++abi-dev \
      cmake ninja-build pkg-config \
      libgtk-3-dev liblzma-dev libglu1-mesa-dev \
      libegl1-mesa-dev libgles2-mesa-dev libgl1-mesa-dev \
      mesa-utils libgl1-mesa-dri mesa-vulkan-drivers vulkan-tools \
      xvfb x11-utils xauth \
      python3 \
    && rm -rf /var/lib/apt/lists/*

# Pinned to the version this repository is developed against, so a Linux
# build here and a macOS build there are the same Flutter.
ARG FLUTTER_VERSION=3.47.0
RUN git clone --depth 1 --branch "$FLUTTER_VERSION" \
      https://github.com/flutter/flutter.git /opt/flutter
ENV PATH="/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:${PATH}"

# Everything here runs as root in a throwaway container, which git refuses to
# treat as a repository it owns without being told. Precaching in the image
# rather than on first use keeps a build from paying for a 225 MB download
# every time a container is started.
RUN git config --global --add safe.directory /opt/flutter \
    && flutter config --no-analytics --enable-linux-desktop \
    && flutter precache --linux --universal \
    && flutter doctor -v || true

WORKDIR /work
