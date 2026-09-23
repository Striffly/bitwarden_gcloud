#!/bin/bash
# End-to-end test of utilities/autoupdate/autoupdate.sh against a real Docker daemon: sliding on precise
# tags, a withdrawn or republished version never installed, an upstream rollback, an image changed by
# hand, a tag meant never to move that moves, the 7-day alert, an unhealthy or crashing image rolled
# back, an image used outside the stack, --restore after the images are lost, and the alert mail.
#
# It runs a local registry, a fake SMTP server (mailpit) and a small compose project, and it removes
# containers and images, so it refuses to run outside a throwaway machine (THROWAWAY=1). Needs Docker
# (compose runs from the docker:cli image, as on the instance), podman (to publish multi-platform images), curl, jq, flock, and access to
# Docker Hub for registry:2, busybox and mailpit, and ghcr.io for the msmtpd relay.
#   THROWAWAY=1 bash tests/autoupdate-docker.sh
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 2; }
[ "${THROWAWAY:-}" = 1 ] || { echo "removes containers and images: run on a throwaway machine (THROWAWAY=1)"; exit 2; }

REG=127.0.0.1:5000; IMG="${REG}/test/app"; PLAIN="${REG}/test/plain"; TOOL="${REG}/test/tool"
D=$(mktemp -d); STACK="$D/stack"; ST="$D/state"; S="$ST/quarantine"; fail=0
ok() { # ok <title> <expected> <got>
    if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
    else printf '  FAIL %s\n       expected: "%s"\n       got:      "%s"\n' "$1" "$2" "$3"; fail=1; fi
}
said() { grep -qF -- "$1" <<< "${out}" && echo yes || echo no; }      # did the last run say it?
cleanup() {
    docker rm -f test-app test-plain > /dev/null 2>&1
    docker rm -f test-registry test-smtp test-relay > /dev/null 2>&1
    docker images --format '{{.Repository}}:{{.Tag}}' | grep "^${REG}/" | xargs -r docker rmi -f > /dev/null 2>&1
}
cleanup

# --- Registry, SMTP ---------------------------------------------------------------------------------
docker run -d --name test-registry -p "${REG}:5000" registry:2 > /dev/null || exit 2
until curl -fs "http://${REG}/v2/" > /dev/null; do sleep 1; done
docker run -d --name test-smtp -p 127.0.0.1:1025:1025 -p 127.0.0.1:8025:8025 \
    -e MP_SMTP_AUTH='bwgc:pa"ss\word' -e MP_SMTP_TLS_CERT=sans:localhost -e MP_SMTP_TLS_KEY=sans:localhost \
    -e MP_SMTP_REQUIRE_STARTTLS=true axllent/mailpit > /dev/null || exit 2
until curl -fs http://127.0.0.1:8025/api/v1/messages > /dev/null; do sleep 1; done
# The script mails through the stack's relay, which alone holds the login (the msmtpd service). msmtp
# never sends a password without TLS, so the server offers STARTTLS, with a self-signed certificate.
docker run -d --name test-relay --network host -e LISTEN_PORT=2500 -e SMTP_HOST=127.0.0.1 -e SMTP_PORT=1025 \
    -e SMTP_SECURITY=starttls -e SMTP_TLS_CHECKCERT=off -e SMTP_USER=bwgc -e SMTP_PASSWORD='pa"ss\word' ghcr.io/striffly/docker-msmtpd:master > /dev/null || exit 2
mails() { curl -fs http://127.0.0.1:8025/api/v1/messages | jq -r '.total'; }
last_subject() { curl -fs http://127.0.0.1:8025/api/v1/messages | jq -r '.messages[0].Subject'; }

# image <name> <content>: a busybox image, healthy (/version present), "unhealthy" or "crashing".
image() {
    local c="$D/ctx-$1"; mkdir -p "$c"
    case "$2" in
        unhealthy) printf 'FROM docker.io/library/busybox\nCMD ["sleep", "infinity"]\n' ;;
        crashing)  printf 'FROM docker.io/library/busybox\nCMD ["sh", "-c", "sleep 2; exit 1"]\n' ;;
        *)         printf 'FROM docker.io/library/busybox\nRUN echo %s > /version\nCMD ["sleep", "infinity"]\n' "$2" ;;
    esac > "$c/Containerfile"
    podman build -q -t "localhost/test-$1" "$c" > /dev/null
}
# publish <repo> <amd64> <other> <tag…>: a two-platform index (the second one announced as arm64).
publish() {
    local r="$1" a="$2" o="$3" t; shift 3
    podman manifest rm localhost/test-index > /dev/null 2>&1
    podman manifest create localhost/test-index > /dev/null
    podman manifest add localhost/test-index "containers-storage:localhost/test-${a}" > /dev/null
    podman manifest add --arch arm64 localhost/test-index "containers-storage:localhost/test-${o}" > /dev/null
    for t in "$@"; do podman manifest push -q --all --tls-verify=false localhost/test-index "docker://${r}:${t}" > /dev/null; done
}
# amd64 <repo> <tag>: the amd64 digest the registry serves under that tag.
amd64() {
    curl -fs -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json' \
        "http://${REG}/v2/${1#"${REG}/"}/manifests/$2" | jq -r '.manifests[] | select(.platform.architecture == "amd64") | .digest'
}
for v in v1 v1-arm v1-arm2 v2 v2-arm v3 v3-arm v4 v4b v4c v5 v6 v7 v8 v9 v9x v10 v11 v12 p1 p2 t1 t2; do image "$v" "$v"; done
image sick unhealthy; image crash crashing
publish "$IMG" v1 v1-arm latest 1.0
publish "$PLAIN" p1 v1-arm latest
publish "$TOOL" t1 v1-arm 1 1.0.0

# --- The stack ----------------------------------------------------------------------------------------
mkdir -p "$STACK"
cat > "$STACK/docker-compose.yml" <<EOF
services:
  app:
    image: ${IMG}:latest
    container_name: test-app
    healthcheck:
      test: ["CMD", "test", "-f", "/version"]
      interval: 2s
      retries: 2
  plain:
    image: ${PLAIN}
    container_name: test-plain
EOF
cat > "$STACK/.env" <<'EOF'
# The script only needs the sender and the recipient: the relay holds the login.
SMTP_FROM='vault@example.com'   # quoted, with a comment
BACKUP_EMAIL_TO="admin@example.com"
EOF
# Compose runs from docker:cli, as on the instance (the cloud-config's compose.sh).
COMPOSE="docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v ${STACK}:${STACK} -w ${STACK} --entrypoint docker docker:cli compose"
${COMPOSE} up -d --wait > /dev/null 2>&1 || { echo "the starting stack does not come up"; exit 2; }
docker pull -q "${TOOL}:1" > /dev/null

run() {
    out=$(BWGC_DIR="$STACK" AUTOUPDATE_STATE_DIR="$ST" COMPOSE="$COMPOSE" EXTRA_IMAGES="${TOOL}:1" \
          AUTOUPDATE_MAIL_RELAY=test-relay MIN_AGE_SECONDS=3600 HEALTH_TIMEOUT=60 STEADY_SECONDS=8 AUTOUPDATE_LOCK="$D/lock" \
          bash "$ROOT/utilities/autoupdate/autoupdate.sh" "$@" 2>&1); rc=$?
}
running() { docker exec "${1:-test-app}" cat /version 2> /dev/null; }
tracked() { [ -f "$S" ] && awk -v k="${IMG}:latest" '$1 == k && $2 != "@" { split($2, v, "#"); print v[1] }' "$S" | tr '\n' ' ' | sed 's/ $//'; }
# age <digest> <seconds>: moves back the date this version was first seen.
age() { awk -v d="$1" -v s="$2" 'index($2, d) == 1 { $3 = $3 - s } { print }' "$S" > "$S.x" && mv "$S.x" "$S"; }

echo "== Up to date =="
run
ok "rc 0" 0 "$rc"
ok "v1 running" v1 "$(running)"
ok "nothing tracked" "" "$(tracked)"
ok "versions recorded for --restore" 3 "$(wc -l < "$ST/installed")"

echo "== Another platform rebuilt: the index changes, not amd64 =="
publish "$IMG" v1 v1-arm2 latest 1.0
run
ok "rc 0" 0 "$rc"
ok "nothing tracked" "" "$(tracked)"

echo "== Sliding: v2 then v3, v2 installed while latest is on v3 =="
publish "$IMG" v2 v2-arm latest 2.0.1 2.0 2 stable; V2=$(amd64 "$IMG" 2.0); run
ok "v2 seen with all its witnesses, not the floating tag" yes "$(said "(precise tags: 2,2.0,2.0.1)")"
publish "$IMG" v3 v3-arm latest 3.0; V3=$(amd64 "$IMG" 3.0); run
ok "v2 and v3 tracked" "$V2 $V3" "$(tracked)"
age "$V2" 7200; run
ok "rc 0" 0 "$rc"
ok "v2 installed" v2 "$(running)"
ok "v3 keeps its date, under the new reference" "$V3" "$(tracked)"
ok "v2 recorded" "$V2" "$(awk -v k="${IMG}:latest" '$1 == k { print $2 }' "$ST/installed")"

echo "== v4 withdrawn: its tags republished on the fix v4b =="
publish "$IMG" v4 v1-arm latest 4.0; V4=$(amd64 "$IMG" 4.0); run
publish "$IMG" v4b v1-arm latest 4.0; V4B=$(amd64 "$IMG" 4.0); run
ok "v4 dropped, and said so" yes "$(said "${V4:7:12} dropped, none of its tags")"
ok "v3 and v4b tracked" "$V3 $V4B" "$(tracked)"
age "$V3" 7200; age "$V4" 7200; run
ok "v3 installed (on its own date)" v3 "$(running)"
age "$V4B" 7200; run
ok "v4b installed, v4 never" v4b "$(running)"

echo "== The tag goes back to the running version: nothing left to track =="
publish "$IMG" v4c v1-arm latest 4.1; run
ok "v4c tracked" yes "$(said "new version")"
publish "$IMG" v4b v1-arm latest; run
ok "nothing tracked, no wait line" 0 "$(grep -c "^${IMG}:latest " "$S")"

echo "== Upstream rollback: latest goes from v6 back to v5 =="
publish "$IMG" v5 v1-arm latest 5.0; V5=$(amd64 "$IMG" 5.0); run
publish "$IMG" v6 v1-arm latest 6.0; V6=$(amd64 "$IMG" 6.0); run
publish "$IMG" v5 v1-arm latest; run
ok "v6 dropped, and said so" yes "$(said "${V6:7:12} dropped, published after ${V5:7:12}")"
ok "only v5 tracked" "$V5" "$(tracked)"
age "$V5" 7200; run
ok "v5 installed" v5 "$(running)"

echo "== Image changed by hand: everything starts over =="
publish "$IMG" v7 v1-arm latest 7.0; run
publish "$IMG" v8 v1-arm latest 8.0; V8=$(amd64 "$IMG" 8.0); run
docker pull -q "${IMG}:7.0" > /dev/null; docker tag "${IMG}:7.0" "${IMG}:latest"
${COMPOSE} up -d --wait app > /dev/null 2>&1
ok "v7 put in place by hand" v7 "$(running)"
age "$V8" 7200; run
ok "said the recorded version is dropped" yes "$(said "changed outside autoupdate")"
ok "v8 not installed on a date from before the change" v7 "$(running)"
ok "v8 waiting from 0 h" yes "$(said "${V8:7:12} seen 0 h ago")"

echo "== A tag meant never to move is moved =="
publish "$IMG" v9 v1-arm latest abc1234; V9=$(amd64 "$IMG" abc1234); run
ok "v9 tracked with its commit tag" yes "$(said "(precise tags: abc1234")"
before=$(mails)
publish "$IMG" v9x v1-arm abc1234; publish "$IMG" v10 v1-arm latest; run
ok "rc 1" 1 "$rc"
ok "said CHECK THIS" yes "$(said "CHECK THIS")"
ok "v9 no longer tracked" no "$(tracked | grep -qF "$V9" && echo yes || echo no)"
ok "alert mailed through the relay, its login with a quote and a backslash accepted" "$(( before + 1 ))" "$(mails)"
ok "mail subject" yes "$(last_subject | grep -q "image updates need attention" && echo yes || echo no)"

echo "== Alert: nothing installable for 8 days =="
awk -v k="${IMG}:latest" '$1 == k && $2 == "@" { $3 = $3 - 8 * 86400 } { print }' "$S" > "$S.x" && mv "$S.x" "$S"
run
ok "rc 1" 1 "$rc"
ok "said so" yes "$(said "nothing installable for 8 days")"

echo "== Unhealthy image: the previous one goes back =="
publish "$IMG" sick v1-arm latest 11.0; VS=$(amd64 "$IMG" 11.0); run
prev=$(running)
age "$VS" 7200; run
ok "rc 1" 1 "$rc"
ok "said so" yes "$(said "previous image put back")"
ok "the previous image runs" "$prev" "$(running)"
ok "quarantine started over" "" "$(tracked)"

echo "== No healthcheck: a crashing image goes back, a sound one is kept =="
publish "$PLAIN" crash v1-arm latest 2.0; VC=$(amd64 "$PLAIN" 2.0); run
age "$VC" 7200; run
ok "crash rolled back" p1 "$(running test-plain)"
publish "$PLAIN" p2 v1-arm latest 3.0; VP=$(amd64 "$PLAIN" 3.0); run
age "$VP" 7200; run
ok "p2 installed" p2 "$(running test-plain)"

echo "== Image outside the stack: re-tagged, no container =="
publish "$TOOL" t2 v1-arm 1 1.0.1; VT=$(amd64 "$TOOL" 1.0.1); run
age "$VT" 7200; run
ok "the local tag moved to t2" t2 "$(docker run --rm "${TOOL}:1" cat /version)"

echo "== --restore: images lost, tags moved upstream since =="
publish "$IMG" v11 v1-arm latest 12.0; V11=$(amd64 "$IMG" 12.0); run
age "$V11" 7200; run
ok "v11 installed" v11 "$(running)"
want=$(awk -v k="${IMG}:latest" '$1 == k { print $3 }' "$ST/installed")
publish "$IMG" v12 v1-arm latest 13.0
${COMPOSE} down -t 1 > /dev/null 2>&1
docker images --format '{{.Repository}}:{{.Tag}}' | grep "^${REG}/" | xargs -r docker rmi -f > /dev/null 2>&1
docker image prune -af > /dev/null 2>&1
run --restore
ok "rc 0" 0 "$rc"
ok "app back on its recorded version, not on latest" "$want" "$(docker image inspect -f '{{.Id}}' "${IMG}:latest")"
${COMPOSE} up -d --wait > /dev/null 2>&1
ok "the stack starts on it, without pulling v12" v11 "$(running)"
ok "the tool image restored too" t2 "$(docker run --rm "${TOOL}:1" cat /version)"

echo "== --test-mail, DRY_RUN =="
before=$(mails); run --test-mail
ok "test mail sent" "$(( before + 1 ))" "$(mails)"
cp "$S" "$D/before"; DRY_RUN=1 run
ok "DRY_RUN leaves the state alone" same "$(cmp -s "$S" "$D/before" && echo same || echo changed)"
ok "DRY_RUN installs nothing" v11 "$(running)"

cleanup; rm -rf "$D"
[ "$fail" = 0 ] && echo "ALL CASES PASS" || echo "SOME CASES FAIL"
exit "$fail"
