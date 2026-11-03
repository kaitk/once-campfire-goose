#!/bin/sh
set -eu
cd "$(dirname "$0")"
export GOOSE_HOME="${GOOSE_HOME:-$PWD/build/home}"
python3 scripts/bootstrap.py
python3 prepare.py
python3 compile_views.py
python3 compile_assets.py
compiler="$PWD/build/toolchain/build/goose"
"$compiler" check --offline -O2 repro/http_compatibility.goose
"$compiler" build --offline --cc clang -o build/campfire campfire.goose
if [ "${1:-}" != "--build-only" ]; then
    # The tests serve plain HTTP, as production does only with DISABLE_SSL (test_ui_auth.py also runs without it).
    export DISABLE_SSL=true
    clang -O2 -ffunction-sections -fdata-sections -I build/toolchain/src/runtime \
        platform_time_test.c -Wl,--gc-sections -pthread -o build/platform_time_test
    build/platform_time_test
    clang -O2 -I build/toolchain/src/runtime push_crypto_test.c -lcrypto -o build/push_crypto_test
    build/push_crypto_test
    python3 test_setup.py build/campfire
    python3 test_routes.py build/campfire
    CAMPFIRE_CACHE=0 python3 test_routes.py build/campfire
    python3 test_admin.py build/campfire
    python3 test_webhooks.py build/campfire
    python3 test_uploads.py build/campfire
    CAMPFIRE_HTTP_BACKEND=emulated python3 test_uploads.py build/campfire
    python3 test_push.py build/campfire
    python3 test_backends.py build/campfire
    python3 test_ui_search.py build/campfire
    python3 test_ui_messages.py build/campfire
    python3 test_ui_rooms.py build/campfire
    python3 test_ui_account.py build/campfire
    python3 test_ui_auth.py build/campfire
    for backend in auto epoll emulated; do
        CAMPFIRE_HTTP_BACKEND="$backend" python3 test_cable.py build/campfire
        CAMPFIRE_HTTP_BACKEND="$backend" python3 test_cable.py build/campfire --batch-pressure
        CAMPFIRE_PUBLICATION_ACK=drained CAMPFIRE_HTTP_BACKEND="$backend" python3 test_cable.py build/campfire
        CAMPFIRE_PUBLICATION_ACK=drained CAMPFIRE_HTTP_BACKEND="$backend" python3 test_cable.py build/campfire --batch-pressure
        CAMPFIRE_HTTP_BACKEND="$backend" python3 test_server.py build/campfire
        CAMPFIRE_HTTP_BACKEND="$backend" python3 test_server.py build/campfire --no-cache
    done
    for window in 32 128 512; do
        CAMPFIRE_PUBLICATION_ACK=queued CAMPFIRE_PUBLICATION_WINDOW="$window" CAMPFIRE_HTTP_BACKEND=epoll python3 test_cable.py build/campfire
        CAMPFIRE_PUBLICATION_ACK=queued CAMPFIRE_PUBLICATION_WINDOW="$window" CAMPFIRE_HTTP_BACKEND=epoll python3 test_cable.py build/campfire --batch-pressure
    done
    CAMPFIRE_PUBLICATION_ACK=queued CAMPFIRE_PUBLICATION_WINDOW=512 CAMPFIRE_HTTP_BACKEND=emulated python3 test_cable.py build/campfire --batch-pressure
    CAMPFIRE_PUBLICATION_ACK=queued CAMPFIRE_PUBLICATION_WINDOW=128 CAMPFIRE_CABLE_PACE_MS=20 CAMPFIRE_HTTP_BACKEND=epoll python3 test_cable.py build/campfire
    CAMPFIRE_PUBLICATION_ACK=queued CAMPFIRE_PUBLICATION_WINDOW=128 CAMPFIRE_CABLE_PACE_MS=20 CAMPFIRE_HTTP_BACKEND=epoll python3 test_cable.py build/campfire --batch-pressure
    for batch in 16384 32768 1048576; do
        CAMPFIRE_CABLE_BATCH="$batch" CAMPFIRE_HTTP_BACKEND=epoll python3 test_cable.py build/campfire
        CAMPFIRE_PUBLICATION_ACK=queued CAMPFIRE_CABLE_BATCH="$batch" CAMPFIRE_HTTP_BACKEND=epoll python3 test_cable.py build/campfire --batch-pressure
    done
    for readers in 0 1 4; do
        CAMPFIRE_CABLE_PASS_READERS="$readers" CAMPFIRE_HTTP_BACKEND=epoll python3 test_cable.py build/campfire
        CAMPFIRE_PUBLICATION_ACK=queued CAMPFIRE_CABLE_PASS_READERS="$readers" CAMPFIRE_HTTP_BACKEND=epoll python3 test_cable.py build/campfire --batch-pressure
    done
    CAMPFIRE_PUBLICATION_ACK=queued CAMPFIRE_CABLE_PASS_READERS=1 CAMPFIRE_HTTP_BACKEND=emulated python3 test_cable.py build/campfire
    for test in cache auth render; do
        "$compiler" build --offline --cc clang -o "build/${test}_test" "${test}_test.goose"
        "build/${test}_test"
    done
    python3 repro/check.py "$compiler"
fi
