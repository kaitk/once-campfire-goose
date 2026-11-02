# syntax=docker/dockerfile:1
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

FROM toolchain AS build
COPY . .
RUN sh build_linux.sh --build-only

FROM build AS test
RUN sh build_linux.sh

FROM ubuntu:24.04 AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates liburing2 libcrypt1 libstdc++6 libqrencode4 \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /rails/storage/db /rails/storage/files /rails/storage/logs \
    && chown -R 1000:1000 /rails
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
LABEL org.opencontainers.image.source="https://github.com/kaitk/once-campfire-goose" \
      org.opencontainers.image.revision="${GIT_REVISION}" \
      org.opencontainers.image.licenses="Apache-2.0 AND MIT"
CMD ["/usr/local/bin/campfire"]
