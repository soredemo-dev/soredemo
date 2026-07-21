# Encoder and codec notes

Soredemo is MIT-licensed application code. It does not bundle, redistribute, or download FFmpeg, FFprobe, `libx264`, or codec libraries. The encoder launches a separately installed system executable without a shell.

Day-9 discovery is deliberately limited to:

1. the literal path in `SOREDEMO_FFMPEG_PATH`;
2. an executable named `ffmpeg` found by inspecting `PATH`;
3. otherwise a clear capability failure.

FFprobe must be an executable beside the resolved FFmpeg binary or discoverable on `PATH`. Environment paths are not shell-expanded. Symlinks are resolved only for diagnostics.

## FFmpeg and libx264 licensing boundary

An FFmpeg executable's licensing depends on its exact configuration. Soredemo does not characterize an arbitrary FFmpeg binary as LGPL. The Day-9 Homebrew build reports both `--enable-gpl` and `--enable-libx264`; that executable is therefore GPL-conditioned. Soredemo records the executable path, real path, SHA-256, version, compiler, configure arguments, and encoder capabilities for each successful encode.

The Day-9 authority binary was:

```text
ffmpeg version 8.0
built with Apple clang version 17.0.0 (clang-1700.3.19.1)
```

Its complete configure argument line was:

```text
--prefix=/opt/homebrew/Cellar/ffmpeg/8.0_1 --enable-shared --enable-pthreads --enable-version3 --cc=clang --host-cflags= --host-ldflags= --enable-ffplay --enable-gnutls --enable-gpl --enable-libaom --enable-libaribb24 --enable-libbluray --enable-libdav1d --enable-libharfbuzz --enable-libjxl --enable-libmp3lame --enable-libopus --enable-librav1e --enable-librist --enable-librubberband --enable-libsnappy --enable-libsrt --enable-libssh --enable-libsvtav1 --enable-libtesseract --enable-libtheora --enable-libvidstab --enable-libvmaf --enable-libvorbis --enable-libvpx --enable-libwebp --enable-libx264 --enable-libx265 --enable-libxml2 --enable-libxvid --enable-lzma --enable-libfontconfig --enable-libfreetype --enable-frei0r --enable-libass --enable-libopencore-amrnb --enable-libopencore-amrwb --enable-libopenjpeg --enable-libspeex --enable-libsoxr --enable-libzmq --enable-libzimg --disable-libjack --disable-indev=jack --enable-videotoolbox --enable-audiotoolbox --enable-neon
```

Before a release, third-party notices must describe the selected executable boundary and users distributing video tooling must evaluate the terms of their own FFmpeg build. This documentation is technical compliance context, not legal advice.

## H.264 patent caveat

H.264/AVC may be subject to patent licensing requirements depending on jurisdiction, distribution model, use, and current patent status. The existence of an open-source encoder or this documentation does not resolve those questions. Users should obtain appropriate advice for their circumstances. This is not legal advice.

## Managed binaries

No managed FFmpeg download exists today. A future download path requires an approved source, exact build configuration, checksums, signature/update policy, cache behavior, notices, and licensing analysis. It must not silently replace system discovery.
