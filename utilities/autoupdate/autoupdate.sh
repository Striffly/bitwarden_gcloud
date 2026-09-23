#!/bin/bash
# shellcheck disable=SC2317 # the modes are called through "( ${mode} )"
# autoupdate.sh: keeps the stack's images current, installing each new version only once THIS HOST has
# seen it for MIN_AGE_SECONDS (3 days). Run daily by bwgc-autoupdate.timer; see
# utilities/README-cos-updates.md, "Image updates".
#
# Why not watchtower's cooldown: it measures an image's age from its "Created" field, which whoever
# publishes the image writes, so a compromised release can be backdated and installed on the next run.
# It also never installs an image whose tag is republished more often than the delay, and says nothing.
#
# How it works. A version is the image's digest for this host's platform (amd64), not the digest of
# the multi-platform index, which changes whenever any other platform is rebuilt. Each version keeps
# the date this host first saw it (utilities/autoupdate/quarantine), and on every run a tracked version
# is only kept while upstream still vouches for it: the followed tag, or one of its witnesses, the
# precise tags that pointed to it when it was first seen ("1.37.3-alpine" for "latest-alpine",
# "master-20260923-153117" for "master"). The newest version past its delay is installed. So a tag
# that moves every day still advances, since the version from three days ago keeps its precise tag,
# while a version whose tags are withdrawn or republished during the delay (compromised, then fixed)
# is dropped, and the next one only waits its own delay.
#
# Also dropped: everything published after a version the followed tag goes back to (an upstream
# rollback). A tag meant never to move (a commit, "-ls233", a build date) that suddenly points to
# another image raises an alert. So does a tag with nothing installable for 7 days.
#
# Known limit: a compromised version whose publisher leaves its precise tag in place is installed once
# its delay is over. The delay relies on the publisher cleaning up; it does not replace that.
#
# Installing: the chosen version is pulled by digest, the local tag the compose file uses is moved to
# it, and its services are recreated. A container that is not healthy (or, without a healthcheck, not
# still running) afterwards gets the previous image back. The installed versions are recorded, and
# --restore, run by bwgc.service before the stack starts, puts them back if the boot disk was
# recreated: otherwise "compose up" would pull whatever the tags point to at that moment.
#
# Problems are mailed to AUTOUPDATE_EMAIL_TO or BACKUP_EMAIL_TO through the stack's msmtpd relay.
#
#   autoupdate.sh                 one run: check every image, install what is ready
#   autoupdate.sh --restore       put the recorded versions back under their tags
#   autoupdate.sh --test-mail     send a test message
#   DRY_RUN=1 autoupdate.sh       decide and report on a copy of the state; install nothing, mail nothing
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# Overridable, mainly by tests/autoupdate-docker.sh. The systemd unit sets none of them.
BWGC_DIR="${BWGC_DIR:-$(cd "${HERE}/../.." && pwd)}"
STATE_DIR="${AUTOUPDATE_STATE_DIR:-$(dirname "${BWGC_DIR}")/autoupdate}"
QUARANTINE="${QUARANTINE:-${HERE}/quarantine}"
COMPOSE="${COMPOSE:-sh /var/lib/bwgc/compose.sh}"
EXTRA_IMAGES="${EXTRA_IMAGES-docker:cli}"      # used outside the stack: compose.sh runs from docker:cli
MIN_AGE_SECONDS="${MIN_AGE_SECONDS:-259200}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-300}"
STEADY_SECONDS="${STEADY_SECONDS:-30}"         # without a healthcheck: still running after this long
LOCK="${AUTOUPDATE_LOCK:-/run/bwgc-stack.lock}" # shared with supervise-stack.sh
DRY_RUN="${DRY_RUN:-}"
MAIL_RELAY="${AUTOUPDATE_MAIL_RELAY:-msmtpd}"

FORGET_SECONDS=7776000      # 90 days without news of a tag: it is no longer deployed
ALERT_SECONDS=604800        # 7 days with nothing installable: the tag moves faster than the quarantine
MANIFEST_TYPES="application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"

case "$(uname -m)" in
    x86_64) ARCH=amd64 ;;
    aarch64) ARCH=arm64 ;;
    *) ARCH=$(uname -m) ;;
esac

q() { bash "${QUARANTINE}" "$@"; }

# --- Image references ---------------------------------------------------------------------------------

# local_ref <image>: the name as Docker stores it locally, tag included ("linuxserver/ddclient:latest").
local_ref() {
    case "${1##*/}" in *:*) printf '%s\n' "$1" ;; *) printf '%s:latest\n' "$1" ;; esac
}

# parse_image <local ref>: sets REPO, with its registry ("docker.io/library/caddy"), and TAG.
parse_image() {
    local name="${1%:*}" first
    TAG="${1##*:}"
    first="${name%%/*}"
    if [ "${first}" = "${name}" ]; then REPO="docker.io/library/${name}"
    elif [[ "${first}" == *.* || "${first}" == *:* || "${first}" == localhost ]]; then REPO="${name}"
    else REPO="docker.io/${name}"
    fi
}

# --- Registries -----------------------------------------------------------------------------------------
# Docker Hub is read through its API (hub.docker.com), which does not count against the anonymous pull
# limit. Other registries through the registry API, anonymously (public images only).

hub_path() { case "$1" in docker.io/*) printf '%s' "${1#docker.io/}" ;; *) return 1 ;; esac; }

hub_get() { curl -fsS --max-time 30 "https://hub.docker.com/v2/repositories/$1" 2> /dev/null; }

# reg_get <repo> <path> [accept]: GET /v2/<name>/<path>. A registry that wants a token answers the first
#   request with 401 and a challenge, 'Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="…"':
#   the anonymous token comes from <realm>, with the service and scope it names. A localhost registry is
#   plain HTTP.
reg_get() {
    local host="${1%%/*}" name="${1#*/}" accept="${3:-application/json}" scheme=https url challenge
    local part key value token
    local -A param=()
    case "${host}" in localhost|localhost:*|127.0.0.1|127.0.0.1:*) scheme=http ;; esac
    url="${scheme}://${host}/v2/${name}/$2"
    challenge=$(curl -sS --max-time 30 -o /dev/null -w '%header{www-authenticate}' -H "Accept: ${accept}" "${url}" 2> /dev/null)
    if [ -z "${challenge}" ]; then
        curl -fsS --max-time 30 -H "Accept: ${accept}" "${url}" 2> /dev/null
        return
    fi
    IFS=, read -ra part <<< "${challenge#Bearer }"
    for part in "${part[@]}"; do
        key="${part%%=*}"; value="${part#*=}"; value="${value#\"}"
        param[${key}]="${value%\"}"
    done
    [ -n "${param[realm]:-}" ] || return 1
    token=$(curl -fsS --max-time 30 -G "${param[realm]}" --data-urlencode "service=${param[service]:-}" \
                --data-urlencode "scope=${param[scope]:-repository:${name}:pull}" 2> /dev/null \
                | jq -er '.token // .access_token') || return 1
    curl -fsS --max-time 30 -H "Accept: ${accept}" -H "Authorization: Bearer ${token}" "${url}" 2> /dev/null
}

# remote_digests <repo> <tag>: "<${ARCH} digest> <digest of what the tag points to>". They differ for a
#   multi-platform image, and "docker pull <tag>" records the second one. Fails if the tag is gone.
remote_digests() {
    local repo="$1" tag="$2" hub raw top p rc=1
    if hub=$(hub_path "${repo}"); then
        hub_get "${hub}/tags/${tag}" | jq -er --arg a "${ARCH}" \
            '(first(.images[] | select(.os == "linux" and .architecture == $a) | .digest) // empty) as $p
             | "\($p) \(.digest)"'
        return
    fi
    raw=$(mktemp) || return 1
    if reg_get "${repo}" "manifests/${tag}" "${MANIFEST_TYPES}" > "${raw}"; then
        top="sha256:$(sha256sum < "${raw}" | cut -d' ' -f1)"
        if ! jq -e '.manifests' "${raw}" > /dev/null 2>&1; then
            echo "${top} ${top}"; rc=0
        elif p=$(jq -er --arg a "${ARCH}" \
                     'first(.manifests[] | select(.platform.os == "linux" and .platform.architecture == $a) | .digest)' "${raw}"); then
            echo "${p} ${top}"; rc=0
        fi
    fi
    rm -f "${raw}"
    return "${rc}"
}

platform_digest() { local d; d=$(remote_digests "$1" "$2") || return 1; echo "${d%% *}"; }

# immutable_tag <tag>: a tag a publisher never moves (a commit, a linuxserver build, a build date). The
#   one heuristic here: no registry says which tags are meant to stay, only their names do.
immutable_tag() { [[ "$1" =~ ^[0-9a-f]{7,40}$ || "$1" =~ -ls[0-9]+$ || "$1" =~ -[0-9]{8}-[0-9]{6}$ ]]; }

# floating_tag <tag>: no digit once architecture names are removed ("latest", "amd64-latest"): it moves
#   like the followed tag and pins nothing.
floating_tag() {
    local t="$1" a
    for a in amd64 arm64 arm32 armhf armv5 armv6 armv7 armv8 i386 ppc64le s390x; do t="${t//"${a}"/}"; done
    case "${t}" in *[0-9]*) return 1 ;; *) return 0 ;; esac
}

# tags_at <repo> <digest>: among the tags read on stdin, those that point to this digest.
tags_at() {
    local t
    while read -r t; do
        [ "$(platform_digest "$1" "${t}")" = "$2" ] && echo "${t}"
    done
}

# precise_tags <repo> <tag> <digest>: the other tags pointing to this digest, floating ones excluded.
#   They are the version's witnesses: read once, when it is first seen, never added to afterwards,
#   since a tag added later could be a decoy. Docker Hub lists the most recently pushed tags first, and
#   gives each one's digests: the 300 latest are enough to hold those of a version just seen. Other
#   registries list tags without dates: the 30 highest in version order ("master-20260923-153117" sorts
#   by its date), cosign signatures and attestations ("sha256-…") left out.
precise_tags() {
    local repo="$1" tag="$2" digest="$3" hub page t
    {
        if hub=$(hub_path "${repo}"); then
            for page in 1 2 3; do
                hub_get "${hub}/tags?page_size=100&page=${page}&ordering=last_updated" \
                    | jq -r --arg a "${ARCH}" --arg d "${digest}" \
                        '.results[] | select(any(.images[]; .os == "linux" and .architecture == $a and .digest == $d)) | .name'
            done
        else
            reg_get "${repo}" "tags/list?n=1000" | jq -r '.tags[]? | select(startswith("sha256-") | not)' \
                | sort -rV | head -30 | tags_at "${repo}" "${digest}"
        fi
    } | sort -u | while read -r t; do
        [ "${t}" = "${tag}" ] || floating_tag "${t}" || echo "${t}"
    done
}

# vouched <repo> <version>: 0 if one of its witnesses still points to it, 1 if none does (tags deleted
#   or republished), 2 if a witness meant never to move now points elsewhere. One witness leaving is
#   normal ("1.37-alpine" moves on to 1.37.4); none left means the version was withdrawn.
vouched() {
    local repo="$1" digest="${2%%#*}" tags="${2#*#}" t now found=1
    for t in ${tags//,/ }; do
        now=$(platform_digest "${repo}" "${t}") || continue      # tag deleted
        if [ "${now}" = "${digest}" ]; then found=0
        elif immutable_tag "${t}"; then return 2
        fi
    done
    return "${found}"
}

# --- Installed versions -------------------------------------------------------------------------------
# One line per image: <local ref> <digest> <image ID>. Read by --restore.

INSTALLED="${STATE_DIR}/installed"

record_installed() {
    local tmp; tmp=$(mktemp "${INSTALLED}.XXXXXX") || return 1
    { [ -f "${INSTALLED}" ] && awk -v k="$1" '$1 != k' "${INSTALLED}"
      [ -n "${2:-}" ] && printf '%s %s %s\n' "$1" "$2" "$3"; } > "${tmp}"
    mv -f "${tmp}" "${INSTALLED}"
}

# installed_get <image>: "<digest> <image ID>", or nothing.
installed_get() { [ -f "${INSTALLED}" ] && awk -v k="$1" '$1 == k { print $2, $3 }' "${INSTALLED}"; }

# pulled_as <image ID> <digest…>: 0 if Docker recorded one of these digests for the image.
pulled_as() {
    local id="$1" d r; shift
    while read -r r; do
        for d in "$@"; do [ "${r#*@}" = "${d}" ] && return 0; done
    done < <(docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "${id}" 2> /dev/null)
    return 1
}

# --- Decision: one per image --------------------------------------------------------------------------

# decide <image> <reference>: sets DECISION to "skip", "wait", or the version to install. Sets rc to 1
#   for anything that must be mailed. The reference is the image ID in use.
decide() {
    local img="$1" ref="$2" head top rec v digest back="" found="" out qrc cand age waiting tags
    local tracked=() live=()
    DECISION="skip"
    parse_image "${img}"

    if ! top=$(remote_digests "${REPO}" "${TAG}"); then
        printf '%s: cannot read its digest from the registry, skipped\n' "${img}" >&2; rc=1; return
    fi
    head="${top%% *}"; top="${top#* }"

    # Changed outside this script (a manual pull): what it recorded no longer runs.
    rec=$(installed_get "${img}")
    if [ -n "${rec}" ] && [ "${rec#* }" != "${ref}" ]; then
        printf '%s: changed outside autoupdate, its recorded version is dropped\n' "${img}"
        [ -n "${DRY_RUN}" ] || record_installed "${img}"
        rec=""
    fi
    # Already running: only another platform moved, or the image is current again. Docker keeps the
    # digest an image was pulled by: the index's for a tag, the platform's for a digest.
    if [ "${rec%% *}" = "${head}" ] || pulled_as "${ref}" "${head}" "${top}"; then
        [ -n "${DRY_RUN}" ] || record_installed "${img}" "${head}" "${ref}"
        q --clear "${STATE}" "${img}" || rc=1
        printf '%s: up to date (%s)\n' "${img}" "${head:7:12}"
        return
    fi

    mapfile -t tracked < <(q --list "${STATE}" "${img}" "${ref}")
    for v in "${tracked[@]}"; do
        digest="${v%%#*}"
        if [ -n "${back}" ]; then
            printf '%s: %s dropped, published after %s which %s went back to\n' \
                "${img}" "${digest:7:12}" "${back:7:12}" "${TAG}"
            continue
        fi
        if [ "${digest}" = "${head}" ]; then
            live+=("${v}"); found=1; back="${digest}"
            continue
        fi
        vouched "${REPO}" "${v}"
        case "$?" in
            0) live+=("${v}") ;;
            1) printf '%s: %s dropped, none of its tags points to it any more (%s)\n' \
                   "${img}" "${digest:7:12}" "${v#*#}" ;;
            *) printf '%s: a tag of %s that should never move (%s) now points to another image: dropped, CHECK THIS\n' \
                   "${img}" "${digest:7:12}" "${v#*#}" >&2
               rc=1 ;;
        esac
    done
    if [ -z "${found}" ]; then
        tags=$(precise_tags "${REPO}" "${TAG}" "${head}" | paste -sd, -)
        live+=("${head}#${tags}")
        printf '%s: new version %s seen (precise tags: %s)\n' "${img}" "${head:7:12}" "${tags:-none}"
    fi

    out=$(q --pick "${STATE}" "${img}" "${ref}" "${MIN_AGE_SECONDS}" "${live[@]}" 2>&1); qrc=$?
    read -r _ cand age waiting <<< "${out}"
    case "${qrc}" in
        0) DECISION="${cand}" ;;
        1) DECISION="wait"
           printf '%s: in quarantine, %s seen %s h ago out of %s h\n' \
               "${img}" "${cand:7:12}" "$(( age / 3600 ))" "$(( MIN_AGE_SECONDS / 3600 ))"
           if [ "${waiting}" -ge "${ALERT_SECONDS}" ]; then
               printf '%s: nothing installable for %s days, its tags move faster than the quarantine\n' \
                   "${img}" "$(( waiting / 86400 ))" >&2
               rc=1
           fi ;;
        *) printf '%s: %s\n' "${img}" "${out}" >&2; rc=1 ;;
    esac
}

# --- Installing -----------------------------------------------------------------------------------------

# healthy <container…>: 0 once each is healthy, or, without a healthcheck, still running after
#   STEADY_SECONDS. 1 if one stops, turns unhealthy, or is not there after HEALTH_TIMEOUT.
healthy() {
    local c t0 status health
    t0=$(date +%s)
    for c in "$@"; do
        while :; do
            read -r status health < <(docker inspect -f \
                '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${c}" 2> /dev/null)
            case "${status}" in
                running) ;;
                created|restarting) health=starting ;;
                *) return 1 ;;
            esac
            case "${health}" in
                healthy) break ;;
                unhealthy) return 1 ;;
                none) [ $(( $(date +%s) - t0 )) -ge "${STEADY_SECONDS}" ] && break ;;
            esac
            [ $(( $(date +%s) - t0 )) -lt "${HEALTH_TIMEOUT}" ] || return 1
            sleep 5
        done
    done
}

# recreate <services> <containers>
recreate() {
    # shellcheck disable=SC2086 # COMPOSE is a command line, and the service list is split on purpose
    ${COMPOSE} up -d --no-deps --force-recreate $1 && healthy $2
}

# adopt <image> <digest> <previous ID> <services> <containers>: installs the digest under the image's
#   tag, or goes back. Sets ADOPTED_ID. 0 = installed · 1 = failed to start, previous image back
#   2 = not found in the registry · 3 = failed to start AND could not go back
adopt() {
    local img="$1" digest="$2" prev="$3" svcs="$4" ctrs="$5"
    parse_image "${img}"
    docker pull -q "${REPO}@${digest}" > /dev/null || return 2
    ADOPTED_ID=$(docker image inspect -f '{{.Id}}' "${REPO}@${digest}") || return 2
    docker tag "${ADOPTED_ID}" "${img}" || return 2
    [ "${ADOPTED_ID}" != "${prev}" ] || return 0      # same image, pulled again under its digest
    [ -n "${svcs}" ] || return 0                      # no container: its next use picks it up
    recreate "${svcs}" "${ctrs}" && return 0
    [ -n "${prev}" ] && docker tag "${prev}" "${img}" || return 3
    recreate "${svcs}" "${ctrs}" || return 3
    return 1
}

# --- Modes ----------------------------------------------------------------------------------------------

update() {
    local containers name svc img ref digest new
    local -A svcs=() ctrs=() refs=() verdict=() failed=()
    rc=0
    exec 9> "${LOCK}" || return 1
    flock -w 900 9 || { echo "another stack operation holds ${LOCK}" >&2; return 1; }

    # The stack's running containers, grouped by image: one decision per image.
    containers=$(docker ps -q --filter "label=com.docker.compose.project.working_dir=${BWGC_DIR}" \
        | xargs -r docker inspect -f \
            '{{.Name}} {{index .Config.Labels "com.docker.compose.service"}} {{.Config.Image}} {{.Image}}') \
        || { echo "cannot list the stack's containers" >&2; return 1; }
    while read -r name svc img ref; do
        [ -n "${name}" ] || continue
        case "${img}" in *@*|sha256:*) continue ;; esac   # pinned by digest: nothing to follow
        img=$(local_ref "${img}")
        svcs[${img}]+="${svc} "; ctrs[${img}]+="${name#/} "; refs[${img}]="${refs[${img}]:-${ref}}"
    done <<< "${containers}"
    for img in ${EXTRA_IMAGES}; do
        img=$(local_ref "${img}")
        [ -n "${refs[${img}]+x}" ] && continue
        ref=$(docker image inspect -f '{{.Id}}' "${img}" 2> /dev/null) || continue
        svcs[${img}]=""; ctrs[${img}]=""; refs[${img}]="${ref}"
    done
    [ "${#refs[@]}" -gt 0 ] || { echo "no running container in ${BWGC_DIR}" >&2; return 1; }

    for img in $(printf '%s\n' "${!refs[@]}" | sort); do
        decide "${img}" "${refs[${img}]}"
        verdict[${img}]="${DECISION}"
    done
    [ -z "${DRY_RUN}" ] || return "${rc}"

    for img in $(printf '%s\n' "${!verdict[@]}" | sort); do
        case "${verdict[${img}]}" in skip|wait) continue ;; esac
        digest="${verdict[${img}]%%#*}"
        adopt "${img}" "${digest}" "${refs[${img}]}" "${svcs[${img}]}" "${ctrs[${img}]}"
        case "$?" in
            0) printf '%s: %s installed (quarantine over)\n' "${img}" "${digest:7:12}"
               new="${ADOPTED_ID}"
               record_installed "${img}" "${digest}" "${new}" || rc=1
               q --adopted "${STATE}" "${img}" "${verdict[${img}]}" "${new}" || rc=1
               if [ "${new}" != "${refs[${img}]}" ]; then
                   docker image rm "${refs[${img}]}" > /dev/null 2>&1 || true   # still used elsewhere: kept
               fi ;;
            1) printf '%s: %s did not start, previous image put back. Version abandoned.\n' "${img}" "${digest:7:12}" >&2
               failed[${img}]=1; rc=1 ;;
            3) printf '%s: %s did not start, and putting the previous image back failed too: CHECK THE STACK\n' \
                   "${img}" "${digest:7:12}" >&2
               failed[${img}]=1; rc=1 ;;
            2) printf '%s: %s not found in the registry (withdrawn?), quarantine restarted\n' "${img}" "${digest:7:12}" >&2
               failed[${img}]=1 ;;
        esac
        # A failure starts over rather than retrying the same version every night.
        [ -z "${failed[${img}]+x}" ] || q --clear "${STATE}" "${img}" || rc=1
    done

    # Tags nothing has used for FORGET_SECONDS, and records of images the stack no longer uses.
    q --forget "${STATE}" "${FORGET_SECONDS}" || rc=1
    if [ -f "${INSTALLED}" ]; then
        while read -r img _; do
            [ -n "${refs[${img}]+x}" ] || record_installed "${img}" || rc=1
        done < "${INSTALLED}"
    fi
    return "${rc}"
}

# restore: every recorded version back under its tag, pulled by digest if it is missing. Run before the
#   stack starts, so a recreated boot disk does not come back with whatever the tags point to today.
restore() {
    local img digest id r=0
    [ -s "${INSTALLED}" ] || return 0
    while read -r img digest id; do
        [ "$(docker image inspect -f '{{.Id}}' "${img}" 2> /dev/null)" = "${id}" ] && continue
        if ! docker image inspect "${id}" > /dev/null 2>&1; then
            parse_image "${img}"
            if ! docker pull -q "${REPO}@${digest}" > /dev/null; then
                printf 'restore: cannot pull %s@%s, %s left as it is\n' "${REPO}" "${digest}" "${img}" >&2
                r=1; continue
            fi
        fi
        if docker tag "${id}" "${img}"; then printf 'restore: %s back on %s\n' "${img}" "${digest:7:12}"
        else r=1
        fi
    done < "${INSTALLED}"
    return "${r}"
}

# --- Mail -----------------------------------------------------------------------------------------------

# send_mail <subject> <body file>: handed to the stack's mail relay (MAIL_RELAY), which holds the SMTP
#   credentials, through the msmtp client in its own image. Only the sender and the recipient are
#   needed here, read from the compose environment ("config --environment" prints the variables as
#   compose resolved them from .env), not parsed from .env.
send_mail() {
    local line from="" to="" backup_to=""
    # shellcheck disable=SC2086 # COMPOSE is a command line
    while IFS= read -r line; do
        case "${line}" in
            SMTP_FROM=*)           from="${line#*=}" ;;
            AUTOUPDATE_EMAIL_TO=*) to="${line#*=}" ;;
            BACKUP_EMAIL_TO=*)     backup_to="${line#*=}" ;;
        esac
    done < <(${COMPOSE} config --environment 2> /dev/null)
    [ -n "${to}" ] || to="${backup_to}"
    if [ -z "${from}" ] || [ -z "${to}" ]; then
        echo "no SMTP_FROM or recipient in the compose environment: mail not sent" >&2; return 1
    fi
    { printf 'From: %s\nTo: %s\nSubject: %s\nDate: %s\nContent-Type: text/plain; charset=utf-8\n\n' \
          "${from}" "${to}" "$1" "$(date -R)"
      cat "$2"; } \
        | docker exec -i "${MAIL_RELAY}" msmtp -C /dev/null --host=127.0.0.1 --port=2500 --tls=off --auth=off \
              --from="${from}" -- "${to}"
}

# --- Main -----------------------------------------------------------------------------------------------

case "${1:-}" in
    "")          mode=update ;;
    --restore)   mode=restore ;;
    --test-mail)
        body=$(mktemp)
        printf 'Test message from %s on %s. Image update alerts will arrive this way.\n' "$0" "$(hostname)" > "${body}"
        send_mail "[bwgc] autoupdate test on $(hostname)" "${body}" && echo "test mail sent"
        r=$?; rm -f "${body}"; exit "${r}" ;;
    *) echo "usage: $0 [--restore | --test-mail]" >&2; exit 2 ;;
esac
for t in docker curl jq flock; do
    command -v "${t}" > /dev/null || { echo "autoupdate: ${t} not found" >&2; exit 1; }
done
[ -d "${BWGC_DIR}" ] || { echo "autoupdate: no deployment at ${BWGC_DIR}" >&2; exit 1; }
if [ -n "${DRY_RUN}" ]; then
    # Decide on a copy of the state: the real one is left as it is.
    copy=$(mktemp -d)
    [ -d "${STATE_DIR}" ] && cp -a "${STATE_DIR}/." "${copy}/"
    STATE_DIR="${copy}"; INSTALLED="${copy}/installed"
fi
install -d -m 0700 "${STATE_DIR}" || exit 1
STATE="${STATE_DIR}/quarantine"

log=$(mktemp) || exit 1
( "${mode}" ) > "${log}" 2>&1
rc=$?
cat "${log}"
if [ "${rc}" -ne 0 ] && [ -z "${DRY_RUN}" ]; then
    send_mail "[bwgc] image updates need attention on $(hostname)" "${log}" || echo "autoupdate: the alert mail could not be sent" >&2
fi
rm -f "${log}"
[ -z "${DRY_RUN}" ] || rm -rf "${STATE_DIR}"
exit "${rc}"
