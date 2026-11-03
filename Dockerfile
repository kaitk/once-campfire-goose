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
    libimagequant0 libhwy1t64 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=vips /opt/vips/lib/ /usr/local/lib/
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
    libimagequant0 libhwy1t64 \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /rails/storage/db /rails/storage/files /rails/storage/logs \
    && chown -R 1000:1000 /rails
COPY --from=vips /opt/vips-runtime/libvips.so.42 /usr/local/lib/
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
