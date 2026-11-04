#!/bin/sh
# Built-in HTTPS end to end, in Docker, against Pebble (Let's Encrypt's test CA) as Thruster would
# meet Let's Encrypt: the production image with TLS_DOMAIN gets a certificate through TLS-ALPN-01
# on port 443 with EAB, serves h2 and HTTP/1.1 by ALPN, redirects port 80, sends HSTS and secure
# cookies, renews while it runs, and keeps the certificate in /rails/storage/thruster across a
# restart with Pebble gone; DISABLE_SSL without TLS_DOMAIN stays plain HTTP. The Rails reference
# image (Thruster) runs against the same Pebble: its port-80 answers and HTTPS headers are compared
# with these, and the certificate Thruster cached is then served by this image from its volume.
# Pebble and the app
# share a Docker network, where Docker's DNS gives Pebble chat.test, since Docker Desktop's host
# network doesn't reach macOS. The host's curl and openssl make the requests through published
# ports.
#
#   sh compare_ui_tls.sh [image]     default once-campfire-goose:tls-app, built if missing
set -eu
cd "$(dirname "$0")"
image=${1:-once-campfire-goose:tls-app}
rails=${RAILS_IMAGE:-once-campfire-verification:reference-a05ee90}
railsvolume=campfire-tls-rails-$$
pebble_image=ghcr.io/letsencrypt/pebble:2.8.0
net=campfire-tls-$$
work=$(mktemp -d)
volume=campfire-tls-storage-$$
http=18080
https=18443
plainport=18081
eab_kid=kid-1
eab_key=zWNDZM6eQGHWpSRTPal5eIUYFTu7EajVIoguysqZ9wG44nMEtx3MUAsUDkMTQ12W
secret=$(openssl rand -hex 64)

cleanup() {
    docker rm -f "$net-app" "$net-pebble" "$net-plain" "$net-rails" "$net-moved" >/dev/null 2>&1 || :
    docker volume rm "$volume" "$railsvolume" >/dev/null 2>&1 || :
    docker network rm "$net" >/dev/null 2>&1 || :
    rm -rf "$work"
}
trap cleanup EXIT INT TERM
fail() { echo "FAIL: $*"; docker logs "$net-app" 2>&1 | tail -30; exit 1; }
pass() { echo "PASS: $*"; }

docker image inspect "$image" >/dev/null 2>&1 || docker build -q -t "$image" . >/dev/null
docker network create "$net" >/dev/null
docker volume create "$volume" >/dev/null
docker volume create "$railsvolume" >/dev/null

# Pebble: EAB required, certificates lasting 60 seconds, validating TLS-ALPN-01 on port 443 of the
# address Docker's DNS gives the name.
cat >"$work/pebble.json" <<EOF
{ "pebble": { "listenAddress": "0.0.0.0:14000", "managementListenAddress": "0.0.0.0:15000",
  "certificate": "test/certs/localhost/cert.pem", "privateKey": "test/certs/localhost/key.pem",
  "httpPort": 80, "tlsPort": 443, "ocspResponderURL": "",
  "externalAccountBindingRequired": true, "externalAccountMACKeys": { "$eab_kid": "$eab_key" },
  "retryAfter": { "authz": 1, "order": 1 },
  "profiles": { "default": { "description": "60 seconds", "validityPeriod": 60 } } } }
EOF
docker run -d --name "$net-pebble" --network "$net" --network-alias pebble -p 127.0.0.1:15000:15000 \
    -e PEBBLE_VA_NOSLEEP=1 -e PEBBLE_WFE_NONCEREJECT=0 -v "$work/pebble.json:/pebble.json:ro" \
    "$pebble_image" -config /pebble.json -dnsserver 127.0.0.11:53 >/dev/null
docker cp "$net-pebble:/test/certs/pebble.minica.pem" "$work/minica.pem"

start_app() {
    docker run -d --name "$net-app" --network "$net" --network-alias chat.test \
        -p 127.0.0.1:$http:80 -p 127.0.0.1:$https:443 -v "$volume:/rails/storage" -v "$work/minica.pem:/etc/pebble-minica.pem:ro" \
        -e SECRET_KEY_BASE="$secret" -e TLS_DOMAIN=chat.test -e ACME_DIRECTORY=https://pebble:14000/dir \
        -e EAB_KID="$eab_kid" -e EAB_HMAC_KEY="$eab_key" -e SSL_CERT_FILE=/etc/pebble-minica.pem "$image" >/dev/null
}
start_rails() {
    docker run -d --name "$net-rails" --network "$net" --network-alias rails.test \
        -p 127.0.0.1:18090:80 -p 127.0.0.1:18453:443 -v "$railsvolume:/rails/storage" -v "$work/minica.pem:/etc/pebble-minica.pem:ro" \
        -e SECRET_KEY_BASE="$secret" -e RAILS_ENV=production -e SKIP_TELEMETRY=true -e WEB_CONCURRENCY=1 -e JOB_CONCURRENCY=1 \
        -e TLS_DOMAIN=rails.test -e ACME_DIRECTORY=https://pebble:14000/dir -e EAB_KID="$eab_kid" -e EAB_HMAC_KEY="$eab_key" \
        -e SSL_CERT_FILE=/etc/pebble-minica.pem "$rails" >/dev/null
}
curl_tls() { curl -s --resolve "chat.test:$https:127.0.0.1" --cacert "$work/root.pem" "$@"; }
curl_rails() { curl -s --resolve "rails.test:18453:127.0.0.1" --cacert "$work/root.pem" "$@"; }
serial() {
    openssl s_client -connect 127.0.0.1:${1:-$https} -servername ${2:-chat.test} -alpn http/1.1 </dev/null 2>/dev/null |
        openssl x509 -noout -serial 2>/dev/null | cut -d= -f2
}
# A response with what the front decides, with the host and HTTPS port named alike: on port 80
# the status, the fields Thruster sets and the body; for the app over HTTPS (a third argument) the
# status, Location, HSTS and each cookie's attributes, as the rest is the app's and compared
# elsewhere.
normal() {
    python3 -c '
import sys, re
host, port, app, raw = sys.argv[1], sys.argv[2], len(sys.argv) > 3, sys.stdin.read()
raw = raw.replace(host, "HOST").replace(":" + port, ":PORT")
head, _, body = raw.partition("\r\n\r\n")
lines = head.split("\r\n")
keep = ("location", "strict-transport-security") if app else ("location", "content-type", "connection", "x-content-type-options")
fields = sorted(l.lower().split(":", 1)[0] + ":" + l.split(":", 1)[1] for l in lines[1:] if l.lower().split(":", 1)[0] in keep)
cookies = sorted("; ".join([c.split(";")[0].split("=")[0] + "=…"] + sorted(re.sub(r"expires=.*", "expires=…", a.strip(), flags=re.I) for a in c.split(";")[1:]))
                 for c in (l.split(":", 1)[1].strip() for l in lines[1:] if l.lower().startswith("set-cookie:")))
print("\n".join([lines[0].split(" ", 2)[1]] + fields + ["set-cookie: " + c for c in cookies] + ([] if app else [repr(body)])))
' "$@"
}
same() {
    label=$1; shift
    if [ "$1" = "$2" ]; then pass "as Rails: $label"; else
        echo "DIFFERS from Rails: $label"; echo "--- Rails"; echo "$1"; echo "--- Goose"; echo "$2"; differences=$((differences + 1)); fi
}
differences=0

start_rails
start_app
for i in $(seq 100); do
    curl -sk https://127.0.0.1:15000/roots/0 >"$work/root.pem" 2>/dev/null && [ -s "$work/root.pem" ] && break
    sleep 0.2
done
for i in $(seq 150); do
    [ "$(curl_tls -o /dev/null -w '%{http_code}' "https://chat.test:$https/up")" = 200 ] && break
    sleep 0.2
done
[ "$(curl_tls -o /dev/null -w '%{http_code}' "https://chat.test:$https/up")" = 200 ] || fail "no certificate from Pebble"
first=$(serial)
docker logs "$net-app" 2>&1 | grep -q "ACME: chat.test: certificate issued" || fail "the issue isn't logged"
pass "a certificate from Pebble through TLS-ALPN-01 on 443, the account bound with EAB (serial $first)"

[ "$(curl_tls --http2 -o /dev/null -w '%{http_version}' "https://chat.test:$https/up")" = 2 ] || fail "h2"
[ "$(curl_tls --http1.1 -o /dev/null -w '%{http_version}' "https://chat.test:$https/up")" = 1.1 ] || fail "HTTP/1.1"
openssl s_client -connect 127.0.0.1:$https -servername chat.test -alpn h2,http/1.1 </dev/null 2>/dev/null | grep -q "ALPN protocol: h2" || fail "ALPN h2"
openssl s_client -connect 127.0.0.1:$https -servername other.test -alpn h2,http/1.1 </dev/null 2>&1 | grep -q "no application protocol" || fail "other names refused"
pass "h2 and HTTP/1.1 by ALPN; another name refused"

headers=$(curl -si -H "Host: chat.test" "http://127.0.0.1:$http/rooms/1?x=1")
echo "$headers" | grep -q "^HTTP/1.1 301" && echo "$headers" | grep -qi "^location: https://chat.test/rooms/1?x=1" || fail "the redirect: $headers"
[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Host: evil.test" "http://127.0.0.1:$http/")" = 421 ] || fail "421"
pass "port 80 redirects to https://chat.test/ permanently, and misdirects other hosts"

# The Rails image, with Thruster, against the same Pebble: its first handshake gets the certificate.
for i in $(seq 300); do
    [ "$(curl_rails -o /dev/null -w '%{http_code}' "https://rails.test:18453/up")" = 200 ] && break
    sleep 0.5
done
[ "$(curl_rails -o /dev/null -w '%{http_code}' "https://rails.test:18453/up")" = 200 ] || fail "Thruster got no certificate"
thruster=$(serial 18453 rails.test)
for request in "GET /rooms/1?x=1&y=%3C" "POST /session" "HEAD /" "GET /.well-known/acme-challenge/token"; do
    set -- $request
    r=$(curl -si -X "$1" -H "Host: rails.test" "http://127.0.0.1:18090$2" | normal rails.test 18453)
    g=$(curl -si -X "$1" -H "Host: chat.test" "http://127.0.0.1:$http$2" | normal chat.test "$https")
    same "port 80, $request" "$r" "$g"
done
same "port 80, another host" "$(curl -si -H "Host: evil.test" http://127.0.0.1:18090/ | normal x 1)" "$(curl -si -H "Host: evil.test" "http://127.0.0.1:$http/" | normal x 1)"
same "port 80, the challenge path with the port in Host" "$(curl -si -H "Host: rails.test:80" http://127.0.0.1:18090/.well-known/acme-challenge/t | normal rails.test 18453)" \
    "$(curl -si -H "Host: chat.test:80" "http://127.0.0.1:$http/.well-known/acme-challenge/t" | normal chat.test "$https")"
for path in /up / /session/new; do
    same "HTTPS over h2, GET $path" "$(curl_rails --http2 -si "https://rails.test:18453$path" | normal rails.test 18453 app)" \
        "$(curl_tls --http2 -si "https://chat.test:$https$path" | normal chat.test "$https" app)"
done
same "ALPN offering h2 and http/1.1" \
    "$(openssl s_client -connect 127.0.0.1:18453 -servername rails.test -alpn h2,http/1.1 </dev/null 2>/dev/null | grep "ALPN protocol")" \
    "$(openssl s_client -connect 127.0.0.1:$https -servername chat.test -alpn h2,http/1.1 </dev/null 2>/dev/null | grep "ALPN protocol")"
refused() { openssl s_client -connect 127.0.0.1:$1 -servername other.test -alpn h2,http/1.1 </dev/null >/dev/null 2>&1 && echo served || echo refused; }
same "another name over TLS" "$(refused 18453)" "$(refused "$https")"


# An install that ran Thruster: this image on its volume serves the certificate Thruster cached.
docker rm -f "$net-rails" >/dev/null
docker run -d --name "$net-moved" --network "$net" --network-alias rails.test -p 127.0.0.1:18090:80 -p 127.0.0.1:18453:443 \
    -v "$railsvolume:/rails/storage" -v "$work/minica.pem:/etc/pebble-minica.pem:ro" -e SECRET_KEY_BASE="$secret" \
    -e TLS_DOMAIN=rails.test -e ACME_DIRECTORY=https://pebble:14000/dir -e EAB_KID="$eab_kid" -e EAB_HMAC_KEY="$eab_key" \
    -e SSL_CERT_FILE=/etc/pebble-minica.pem "$image" >/dev/null
for i in $(seq 100); do
    [ -n "$(serial 18453 rails.test)" ] && break
    sleep 0.2
done
moved=$(serial 18453 rails.test)
docker logs "$net-moved" 2>&1 | grep "ACME" | head -3
[ "$moved" = "$thruster" ] || echo "NOTE: Thruster's certificate $thruster, served $moved (Pebble's 60-second certificate may have been renewed first)"
docker logs "$net-moved" 2>&1 | grep -q "ACME: rails.test: certificate cached" || fail "Thruster's cache not read"
pass "Thruster's cache in /rails/storage/thruster, read and served by this image (serial $moved)"
docker rm -f "$net-moved" >/dev/null

page=$(curl_tls --http2 -si "https://chat.test:$https/session/new")
echo "$page" | grep -qi "^strict-transport-security: max-age=63072000; includeSubDomains" || fail "HSTS over h2"
first_run=$(curl_tls --http2 -si -H "Origin: https://chat.test:$https" -H "Sec-Fetch-Site: same-origin" \
    --data-urlencode "user[name]=Ada" --data-urlencode "user[email_address]=ada@example.test" --data-urlencode "user[password]=secret password" \
    "https://chat.test:$https/first_run")
echo "$first_run" | grep -qi "^location: https://chat.test:$https/" || fail "first run over h2: $first_run"
echo "$first_run" | grep -i "^set-cookie:" | grep -qvi "; secure" && fail "a cookie without secure"
echo "$first_run" | grep -qi "^set-cookie: session_token=.*; secure" || fail "the session cookie"
cookie=$(echo "$first_run" | grep -i "^set-cookie: session_token=" | sed 's/^[^:]*: //; s/;.*//' | tr -d '\r')
room=$(curl_tls --http2 -s -b "$cookie" "https://chat.test:$https/rooms/1")
echo "$room" | grep -q "Ada" || fail "the room over h2"
pass "over h2: HSTS, secure cookies, https:// redirects from :authority, a signed-in room page"

renewed=
for i in $(seq 90); do
    s=$(serial)
    if [ -n "$s" ] && [ "$s" != "$first" ]; then renewed=$s; break; fi
    sleep 1
done
[ -n "$renewed" ] || fail "no renewal"
[ "$(docker inspect -f '{{.RestartCount}}' "$net-app")" = 0 ] || fail "restarted"
pass "renewed while running, without a restart (serial $renewed)"


files=$(docker exec "$net-app" ls -la /rails/storage/thruster)
echo "$files" | grep -q "acme_account+key" && echo "$files" | grep -q " chat.test$" || fail "the cache: $files"
docker exec "$net-app" sh -c 'head -1 /rails/storage/thruster/chat.test; stat -c %a /rails/storage/thruster /rails/storage/thruster/chat.test'
pass "kept in /rails/storage/thruster in autocert's layout"

docker rm -f "$net-pebble" >/dev/null
cached=$(serial)
docker rm -f "$net-app" >/dev/null
start_app
for i in $(seq 100); do
    [ "$(serial)" = "$cached" ] && break
    sleep 0.2
done
[ "$(serial)" = "$cached" ] || fail "after a restart without Pebble"
pass "after a restart with Pebble gone, the cached certificate (serial $cached)"

docker run -d --name "$net-plain" -p 127.0.0.1:$plainport:80 -e SECRET_KEY_BASE="$secret" -e DISABLE_SSL=true "$image" >/dev/null
for i in $(seq 100); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$plainport/up")" = 200 ] && break
    sleep 0.2
done
plainpage=$(curl -si "http://127.0.0.1:$plainport/")
echo "$plainpage" | grep -q "^HTTP/1.1 302" && echo "$plainpage" | grep -qi "^location: http://127.0.0.1:$plainport/session/new" || fail "plain HTTP: $plainpage"
echo "$plainpage" | grep -qi "strict-transport-security" && fail "HSTS with DISABLE_SSL"
pass "DISABLE_SSL without TLS_DOMAIN: plain HTTP on port 80, http:// URLs, no HSTS"
[ "$differences" = 0 ] || echo "$differences response(s) differ from Rails: see above"
