#!/bin/bash
# End-to-end test of the stack's mail: the real docker-compose.yml brings up the msmtpd relay,
# vaultwarden and backup against a fake SMTP server (mailpit) that requires STARTTLS and a login.
# vaultwarden (its admin "test SMTP" button), backup (a failure notice) and autoupdate (--test-mail)
# must each get a mail through, and only the relay may hold the SMTP credentials.
#
# It creates containers, a network and images, so it refuses to run outside a throwaway machine
# (THROWAWAY=1). Needs Docker, curl, jq, flock, and access to Docker Hub and ghcr.io.
#   THROWAWAY=1 bash tests/mail-relay-docker.sh
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 2; }
[ "${THROWAWAY:-}" = 1 ] || { echo "creates containers and images: run on a throwaway machine (THROWAWAY=1)"; exit 2; }

D=$(mktemp -d); W="$D/bwgc"; fail=0
# Quotes, a backslash, $ and a backquote: whatever compose, a shell or msmtp would interpret.
# shellcheck disable=SC2016 # literal on purpose
PASSWORD='p"a\s$s`wo\"rd'
ok() { # ok <title> <expected> <got>
    if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
    else printf '  FAIL %s\n       expected: "%s"\n       got:      "%s"\n' "$1" "$2" "$3"; fail=1; fi
}

# A copy of the deployment, so the test leaves the checkout alone.
mkdir -p "$W" && tar -C "$ROOT" --exclude=.git -cf - . | tar -C "$W" -xf -
cat > "$W/.env" <<EOF
DOMAIN=vault.test
ADMIN_TOKEN=test-admin-token
SMTP_HOST=mailpit
SMTP_PORT=1025
SMTP_SECURITY=starttls
SMTP_USERNAME=relay
SMTP_PASSWORD='${PASSWORD}'
SMTP_FROM=vault@example.com
BACKUP_EMAIL_TO=admin@example.com
BACKUP=local
BACKUP_SCHEDULE=0 5 * * *
BACKUP_EMAIL_NOTIFY=true
TZ=UTC
EOF
# mailpit's certificate is self-signed: the one setting the real deployment does not have.
cat > "$W/docker-compose.test.yml" <<'EOF'
services:
  msmtpd:
    environment:
    - SMTP_TLS_CHECKCERT=off
EOF
# Compose runs from docker:cli, as on the instance (the cloud-config's compose.sh).
COMPOSE="docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v $W:$W -w $W --entrypoint docker docker:cli compose -f docker-compose.yml -f docker-compose.test.yml"
# shellcheck disable=SC2317 # called by the trap
cleanup() {
    # shellcheck disable=SC2086 # COMPOSE is a command line
    ${COMPOSE} down -t 1 > /dev/null 2>&1
    docker rm -f mailpit > /dev/null 2>&1
}
trap 'cleanup; rm -rf "$D"' EXIT

# --- The stack, and the SMTP server on its network -------------------------------------------------
# shellcheck disable=SC2086
${COMPOSE} up -d --no-deps msmtpd > /dev/null 2>&1 || { echo "the relay does not start"; exit 2; }
NET=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' msmtpd)
printf 'relay:%s\n' "${PASSWORD}" > "$D/auth"; chmod 644 "$D/auth"
docker run -d --name mailpit --network "${NET}" -v "$D/auth:/auth:ro" \
    -e MP_SMTP_TLS_CERT=sans:mailpit -e MP_SMTP_TLS_KEY=sans:mailpit -e MP_SMTP_REQUIRE_STARTTLS=true \
    -e MP_SMTP_AUTH_FILE=/auth axllent/mailpit > /dev/null || exit 2
subjects() { docker exec mailpit wget -qO- http://127.0.0.1:8025/api/v1/messages 2> /dev/null | jq -r '.messages[].Subject'; }
until docker exec mailpit wget -qO- http://127.0.0.1:8025/api/v1/messages > /dev/null 2>&1; do sleep 1; done
# shellcheck disable=SC2086
${COMPOSE} up -d --no-deps bitwarden backup > /dev/null 2>&1 || { echo "vaultwarden or backup does not start"; exit 2; }
for _ in $(seq 1 60); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' bitwarden 2> /dev/null)" = healthy ] \
        && [ "$(docker inspect -f '{{.State.Status}}' backup 2> /dev/null)" = running ] && break
    sleep 3
done
ok "vaultwarden healthy" healthy "$(docker inspect -f '{{.State.Health.Status}}' bitwarden 2> /dev/null)"
ok "backup running" running "$(docker inspect -f '{{.State.Status}}' backup 2> /dev/null)"

echo "== Credentials only in the relay =="
has_secret() { docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" | grep -c '^SMTP_PASSWORD=.'; }
ok "the relay has the password" 1 "$(has_secret msmtpd)"
ok "vaultwarden does not" 0 "$(has_secret bitwarden)"
ok "backup does not" 0 "$(has_secret backup)"
ok "no port published for the relay" "" "$(docker port msmtpd)"

echo "== vaultwarden: the admin page's SMTP test =="
code=$(docker exec bitwarden sh -c 'curl -s -o /dev/null -c /tmp/admin -d token=test-admin-token http://127.0.0.1:80/admin
    curl -s -o /dev/null -w "%{http_code}" -b /tmp/admin -H "Content-Type: application/json" \
         -d "{\"email\":\"admin@example.com\"}" http://127.0.0.1:80/admin/test/smtp')
ok "vaultwarden accepts the test" 200 "${code}"
sleep 3
ok "its mail went through the relay" yes "$(subjects | grep -q 'Vaultwarden SMTP Test' && echo yes || echo no)"

echo "== backup: a failure notice =="
docker exec backup sh /backup.sh bogus > /dev/null 2>&1
sleep 3
ok "the Backup Failed mail went through the relay" yes "$(subjects | grep -q 'Backup Failed' && echo yes || echo no)"

echo "== autoupdate: --test-mail =="
out=$(BWGC_DIR="$W" COMPOSE="${COMPOSE}" bash "$W/utilities/autoupdate/autoupdate.sh" --test-mail 2>&1)
ok "autoupdate reports it sent" yes "$(grep -q 'test mail sent' <<< "${out}" && echo yes || echo no)"
sleep 2
ok "its mail went through the relay" yes "$(subjects | grep -q 'autoupdate test' && echo yes || echo no)"

echo "== The relay refuses to deliver with a wrong password =="
sed -i "s|^SMTP_PASSWORD=.*|SMTP_PASSWORD=wrong|" "$W/.env"
# shellcheck disable=SC2086
${COMPOSE} up -d --no-deps msmtpd > /dev/null 2>&1; sleep 3
out=$(BWGC_DIR="$W" COMPOSE="${COMPOSE}" bash "$W/utilities/autoupdate/autoupdate.sh" --test-mail 2>&1); rc=$?
ok "autoupdate reports the failure" 1 "$(( rc != 0 ))"

[ "${fail}" = 0 ] && echo "ALL CASES PASS" || echo "SOME CASES FAIL"
exit "${fail}"
