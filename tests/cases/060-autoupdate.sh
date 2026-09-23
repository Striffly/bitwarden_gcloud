# utilities/autoupdate: both scripts parse, and the quarantine keeps one clock per value. The full
# behaviour against Docker and a registry is tests/autoupdate-docker.sh, run on a throwaway machine.
for f in "$ROOT"/utilities/autoupdate/autoupdate.sh "$ROOT"/utilities/autoupdate/quarantine; do
	rel=${f#"$ROOT"/}
	if bash -n "$f" 2>/dev/null; then pass "parses: $rel"; else fail "parses: $rel"; fi
	if command -v shellcheck >/dev/null 2>&1; then
		if out=$(shellcheck -S warning "$f" 2>&1); then pass "shellcheck: $rel"
		else fail "shellcheck: $rel" "$(printf '%s' "$out" | head -4)"; fi
	fi
done

if command -v bash >/dev/null 2>&1; then
	Q="$ROOT/utilities/autoupdate/quarantine"
	S="$WORK/autoupdate/quarantine"
	qrun() { out=$(bash "$Q" "$@" 2>&1); rc=$?; }
	values() { awk -v k="$1" '$1 == k && $2 != "@" { print $2 }' "$S" | tr '\n' ' ' | sed 's/ $//'; }
	age() { awk -v v="$1" -v s="$2" '$2 == v { $3 = $3 - s } { print }' "$S" > "$S.x" && mv "$S.x" "$S"; }

	qrun --pick "$S" img r1 3600 c1
	assert_status "$rc" 1                                  "a new value waits"
	assert_contains "$out" "wait c1 0 0"                   "  from zero seconds"
	assert_contains "$(stat -c %a "$S")" "600"             "state file is 600"
	qrun --pick "$S" img r1 3600 c1 c2
	assert_contains "$out" "wait c1"                       "the oldest value is the closest"
	qrun --list "$S" img r1
	assert_contains "$(echo "$out" | tr '\n' ' ')" "c1 c2" "--list gives both values, not the wait line"
	age c1 7300; age c2 7200
	qrun --pick "$S" img r1 3600 c1 c2 c3
	assert_status "$rc" 0                                  "a value past its delay is ready"
	assert_contains "$out" "ready c2"                      "  the most recent of the ready ones"
	qrun --pick "$S" img r1 3600 c3
	assert_contains "$(values img)" "c3"                   "values the caller drops are forgotten"
	assert_not_contains "$(values img)" "c1"               "  c1 gone"
	qrun --list "$S" img r2
	assert_contains "[$out]" "[]"                          "nothing tracked under another reference"
	qrun --pick "$S" img r2 3600 c3
	assert_contains "$out" "wait c3 0 0"                   "a new reference starts over"

	age c3 7200
	qrun --pick "$S" img r2 3600 c3 c4
	qrun --adopted "$S" img c3 r-c3
	assert_status "$rc" 0                                  "--adopted succeeds"
	assert_contains "$(values img)" "c4"                   "  what was seen after stays"
	assert_contains "$(awk '$2 == "c4" { print $4 }' "$S")" "r-c3" "  under the new reference"
	qrun --adopted "$S" img unknown r
	assert_status "$rc" 2                                  "--adopted refuses a value it does not track"
	qrun --pick "$S" img r1 1h c1
	assert_status "$rc" 2                                  "a non-numeric delay is refused"
	qrun --pick "$S" img r1 3600 "@"
	assert_status "$rc" 2                                  "the reserved value is refused"
	awk '$2 == "c4" { $3 = "garbage" } { print }' "$S" > "$S.x" && mv "$S.x" "$S"
	qrun --pick "$S" img r-c3 3600 c4
	assert_contains "$out" "wait c4 0"                     "an unreadable date makes the value new"
	qrun --pick "$S" img r-c3 0 c4
	assert_contains "$out" "ready c4"                      "delay 0 installs at once"

	printf 'old x %s r\n' "$(( $(date +%s) - 100000 ))" >> "$S"
	qrun --forget "$S" 90000
	assert_not_contains "$(cut -d' ' -f1 "$S")" "old"      "--forget drops silent keys"
	assert_contains "$(cut -d' ' -f1 "$S")" "img"          "  and keeps the others"
	qrun --clear "$S" img
	assert_contains "[$(cat "$S")]" "[]"                   "--clear removes the key"
	qrun --bogus
	assert_status "$rc" 2                                  "an unknown mode is refused"
fi

# The cloud-config: a daily run, the recorded versions put back before the
# stack starts, and the supervisor standing aside while an update runs.
. "$ROOT/utilities/lib-bwgc-cloudinit.sh"
cc=$(emit_cloud_config bwgc-data /mnt/disks/bwgc 06:00)
assert_contains "$cc" "/etc/systemd/system/bwgc-autoupdate.timer"   "declares the image update timer"
assert_contains "$cc" "systemctl enable --now bwgc-autoupdate.timer" "enables it"
assert_contains "$cc" "ExecStart=/bin/bash /mnt/disks/bwgc/bitwarden_gcloud/utilities/autoupdate/autoupdate.sh" \
	"runs the script from the data disk, through bash (noexec-safe)"
assert_before "$cc" '"$AUTOUPDATE" --restore' "compose.sh down --remove-orphans" \
	"restores the installed versions before the stack is recreated"
sup=$(printf '%s\n' "$cc" | sed -n '/path: \/var\/lib\/bwgc\/supervise-stack.sh/,/^- path:/p')
assert_before "$sup" "flock -n 9 || exit 0" "sh /var/lib/bwgc/compose.sh up -d" \
	"the supervisor skips a run while an update holds the lock"
assert_contains "$(cat "$ROOT/utilities/autoupdate/autoupdate.sh")" 'LOCK="${AUTOUPDATE_LOCK:-/run/bwgc-stack.lock}"' \
	"  the same lock as the script"
