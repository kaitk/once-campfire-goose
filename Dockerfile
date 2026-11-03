# syntax=docker/dockerfile:1
# libvips for Active Storage's analysis and variants, built with only the loaders and savers
# Campfire reaches (PNG, JPEG, GIF, WebP, TIFF, HEIC/AVIF, with EXIF orientation and ICC colour
# management): the distribution's libvips42t64 would bring ImageMagick, Poppler, OpenEXR and more
# into the runtime. 8.16.1 is the version the Rails image ships.
FROM ubuntu:24.04 AS vips
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl xz-utils build-essential meson ninja-build pkg-config \
    libglib2.0-dev libexpat1-dev zlib1g-dev libjpeg-turbo8-dev libspng-dev libpng-dev libwebp-dev \
    libtiff-dev libheif-dev libexif-dev liblcms2-dev libcgif-dev libimagequant-dev libhwy-dev \
    && rm -rf /var/lib/apt/lists/*
ARG VIPS_VERSION=8.16.1
ARG VIPS_SHA256=d114d7c132ec5b45f116d654e17bb4af84561e3041183cd4bfd79abfb85cf724
WORKDIR /usr/src
RUN curl -fsSL -o vips.tar.xz "https://github.com/libvips/libvips/releases/download/v${VIPS_VERSION}/vips-${VIPS_VERSION}.tar.xz" \
    && echo "${VIPS_SHA256}  vips.tar.xz" | sha256sum -c - \
    && tar -xJf vips.tar.xz && cd "vips-${VIPS_VERSION}" \
    && meson setup build --buildtype=release --prefix=/opt/vips --libdir=lib --wrap-mode=nodownload \
      --auto-features=disabled -Dmodules=disabled -Dintrospection=disabled -Dcplusplus=false \
      -Ddeprecated=false -Dexamples=false -Dvapi=false \
      -Djpeg=enabled -Dspng=enabled -Dpng=enabled -Dwebp=enabled -Dtiff=enabled -Dheif=enabled \
      -Dexif=enabled -Dlcms=enabled -Dcgif=enabled -Dimagequant=enabled -Dhighway=enabled -Dzlib=enabled \
    && meson install -C build --strip \
    && mkdir -p /opt/vips-runtime && cp -L /opt/vips/lib/libvips.so.42 /opt/vips-runtime/

# ffmpeg and ffprobe for Active Storage's video analyzer and previewer, from the Debian source
# package the Rails image ships (ffmpeg 7:7.1.5-0+deb13u1; the .dsc's checksum pins it, and
# dpkg-source checks the tarballs against the .dsc), built as the Rust and Jai ports build it:
# every built-in demuxer, decoder and parser plus dav1d for AV1, so ffprobe and the previewer see
# what the Rails image's ffmpeg sees; the one encoder and muxer ActiveStorage.video_preview_arguments
# needs (a JPEG frame on stdout), the filters that command line and autorotation insert, and the
# file and pipe protocols. No hardware, network, device or external codec libraries: Ubuntu's own
# ffmpeg package would add some 400 MB of them to the runtime.
FROM ubuntu:24.04 AS ffmpeg
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl xz-utils dpkg-dev build-essential nasm pkg-config \
    libdav1d-dev zlib1g-dev libbz2-dev liblzma-dev \
    && rm -rf /var/lib/apt/lists/*
ARG FFMPEG_VERSION=7.1.5-0+deb13u1
ARG FFMPEG_DSC_SHA256=9ed2ed34cbe7f056eeebbe9045c5e2d15e41b5b053fe7c8ba6979a0b6fb081ce
WORKDIR /usr/src
RUN upstream="${FFMPEG_VERSION%-*}" && pool=https://deb.debian.org/debian/pool/main/f/ffmpeg \
    && curl -fsSLO "${pool}/ffmpeg_${FFMPEG_VERSION}.dsc" \
    && echo "${FFMPEG_DSC_SHA256}  ffmpeg_${FFMPEG_VERSION}.dsc" | sha256sum -c - \
    && curl -fsSLO "${pool}/ffmpeg_${upstream}.orig.tar.xz" -fsSLO "${pool}/ffmpeg_${upstream}.orig.tar.xz.asc" \
      -fsSLO "${pool}/ffmpeg_${FFMPEG_VERSION}.debian.tar.xz" \
    && dpkg-source -x "ffmpeg_${FFMPEG_VERSION}.dsc" ffmpeg && cd ffmpeg \
    && ./configure --prefix=/opt/ffmpeg --extra-version="${FFMPEG_VERSION#*-}" --toolchain=hardened \
      --enable-shared --disable-static --disable-doc --disable-ffplay --disable-avdevice \
      --disable-autodetect --disable-network --disable-hwaccels --disable-devices \
      --enable-libdav1d --enable-zlib --enable-bzlib --enable-lzma \
      --disable-encoders --enable-encoder=mjpeg \
      --disable-muxers --enable-muxer=image2 \
      --disable-protocols --enable-protocol=file,pipe \
      --disable-filters \
      --enable-filter=buffer,buffersink,abuffer,abuffersink,format,aformat,null,anull,scale,aresample \
      --enable-filter=select,loop,trim,transpose,hflip,vflip,rotate,crop \
    && make -j"$(nproc)" && make install \
    && strip --strip-unneeded /opt/ffmpeg/lib/*.so.* /opt/ffmpeg/bin/* \
    && mkdir -p /opt/ffmpeg-runtime/lib /opt/ffmpeg-runtime/bin /opt/ffmpeg-runtime/share/doc/ffmpeg \
    && cp LICENSE.md COPYING.LGPLv2.1 debian/copyright /opt/ffmpeg-runtime/share/doc/ffmpeg/ \
    && cp -L /opt/ffmpeg/lib/libavcodec.so.61 /opt/ffmpeg/lib/libavfilter.so.10 /opt/ffmpeg/lib/libavformat.so.61 \
      /opt/ffmpeg/lib/libavutil.so.59 /opt/ffmpeg/lib/libswresample.so.5 /opt/ffmpeg/lib/libswscale.so.8 /opt/ffmpeg-runtime/lib/ \
    && cp /opt/ffmpeg/bin/ffmpeg /opt/ffmpeg/bin/ffprobe /opt/ffmpeg-runtime/bin/

FROM ubuntu:24.04 AS toolchain
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates git clang cmake ninja-build python3 liburing-dev libssl-dev libcrypt-dev libqrencode-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
ENV GOOSE_HOME=/src/build/home
COPY dependencies.json ./
COPY scripts/bootstrap.py scripts/
COPY patches/ patches/
RUN python3 scripts/bootstrap.py
COPY prepare.py sqlite_wal.c ./
RUN python3 prepare.py
# libvips to link against, and the libraries it loads (the runtime stage installs the same ones).
RUN apt-get update && apt-get install -y --no-install-recommends \
    libglib2.0-dev libexpat1 libjpeg-turbo8 libspng0 libpng16-16t64 libwebp7 libwebpmux3 libwebpdemux2 \
    libtiff6 libheif1 libheif-plugin-libde265 libheif-plugin-aomdec libexif12 liblcms2-2 libcgif0 \
    libimagequant0 libhwy1t64 libdav1d7 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=vips /opt/vips/lib/ /usr/local/lib/
# ffmpeg and ffprobe, which the tests run as the server does.
COPY --from=ffmpeg /opt/ffmpeg-runtime/ /usr/local/
RUN ldconfig

FROM toolchain AS build
COPY . .
RUN sh build_linux.sh --build-only

FROM build AS test
RUN sh build_linux.sh

FROM ubuntu:24.04 AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates liburing2 libcrypt1 libssl3t64 libstdc++6 libqrencode4 \
    libglib2.0-0t64 libexpat1 libjpeg-turbo8 libspng0 libpng16-16t64 libwebp7 libwebpmux3 libwebpdemux2 \
    libtiff6 libheif1 libheif-plugin-libde265 libheif-plugin-aomdec libexif12 liblcms2-2 libcgif0 \
    libimagequant0 libhwy1t64 libdav1d7 \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /rails/storage/db /rails/storage/files /rails/storage/logs \
    && chown -R 1000:1000 /rails
COPY --from=vips /opt/vips-runtime/libvips.so.42 /usr/local/lib/
COPY --from=ffmpeg /opt/ffmpeg-runtime/ /usr/local/
RUN ldconfig
WORKDIR /rails
COPY --from=build /src/build/campfire /usr/local/bin/campfire
COPY assets/reference assets/reference
COPY data data
COPY LICENSE /usr/share/doc/once-campfire-goose/LICENSE
COPY views/MIT-LICENSE /usr/share/doc/once-campfire-goose/MIT-LICENSE
USER 1000:1000
ENV HTTP_PORT=3000 DATABASE_PATH=/rails/storage/db/production.sqlite3 STORAGE_PATH=/rails/storage/files
EXPOSE 3000
ARG GIT_REVISION=unknown
ARG APP_VERSION
# config/initializers/version.rb: X-Version and X-Rev, and the version badge.
ENV APP_VERSION=$APP_VERSION GIT_REVISION=$GIT_REVISION
LABEL org.opencontainers.image.source="https://github.com/kaitk/once-campfire-goose" \
      org.opencontainers.image.revision="${GIT_REVISION}" \
      org.opencontainers.image.licenses="Apache-2.0 AND MIT"
CMD ["/usr/local/bin/campfire"]
