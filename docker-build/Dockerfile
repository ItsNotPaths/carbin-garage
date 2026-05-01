FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive

# ── Toolchain + SDL3 backend headers ─────────────────────────────────────────
# Floor: Ubuntu 20.04 = glibc 2.31. Covers Ubuntu 20.04+, Debian 11+, Steam
# Deck (glibc 2.33), and any rolling distro. SDL3 dlopen()s display/audio
# backends at runtime; the dev headers are only needed so SDL3's cmake enables
# those backends. SDL3_image / SDL3_ttf use VENDORED=ON (build-deps.sh) which
# pulls libpng / libjpeg / libwebp / libtiff / libfreetype etc. as static libs
# inline, so we don't need any of those system-side.
RUN apt-get update && apt-get install -y \
    build-essential cmake ninja-build curl git pkg-config ca-certificates \
    xz-utils \
    # X11 / Wayland display backends
    libx11-dev libxext-dev libxrandr-dev libxinerama-dev \
    libxi-dev libxfixes-dev libxcursor-dev libxss-dev libxtst-dev \
    libwayland-dev libxkbcommon-dev wayland-protocols libdecor-0-dev \
    # Audio backends (dlopen()d at runtime)
    libasound2-dev libpulse-dev libpipewire-0.3-dev \
    # DBus / IME / input
    libdbus-1-dev libibus-1.0-dev libudev-dev \
    # OpenGL / EGL / Vulkan headers (loader is dynamic at runtime)
    libgl1-mesa-dev libegl1-mesa-dev libglvnd-dev \
    libvulkan-dev \
    # Shader compiler (glslc) for the sdl_gpu pipeline
    glslang-tools \
    && rm -rf /var/lib/apt/lists/*

# ── Install Nim ──────────────────────────────────────────────────────────────
# Direct from official release tarball — no choosenim dependency.
ARG NIM_VERSION=2.2.8
RUN curl -L "https://nim-lang.org/download/nim-${NIM_VERSION}-linux_x64.tar.xz" \
    | tar xJ -C /opt \
    && ln -sf "/opt/nim-${NIM_VERSION}/bin/nim"    /usr/local/bin/nim \
    && ln -sf "/opt/nim-${NIM_VERSION}/bin/nimble" /usr/local/bin/nimble \
    && (ln -sf "/opt/nim-${NIM_VERSION}/bin/nim-gdb" /usr/local/bin/nim-gdb || true)

# ── Cross-compile toolchain for Windows (mingw-w64) ──────────────────────────
# Single container builds both linux and windows binaries. SDL3 cmake supports
# mingw cross-compile out of the box.
RUN apt-get update && apt-get install -y \
    mingw-w64 mingw-w64-tools \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
