#!/bin/bash
# Restores a node's secrets from your own backup, for when a Mac had to be rebuilt.
#
#   scripts/restore-secrets.sh backup.env [-- tender secret set options...]
#   scripts/restore-secrets.sh backup-dir/ -- --node mac-1
#
# A file holds one `scope/NAME=value` line per secret (`api/MONGO_PASSWORD=...`,
# `shared/JWT_KEY=...`); blank lines and `#` comments are skipped, and the value is
# everything after the first `=`. A directory holds one file per secret, named
# `scope/NAME` (backup-dir/api/MONGO_PASSWORD), whose bytes are the value, for keys
# with newlines such as service-account JSON.
#
# A value never goes on the command line, where `ps` and shell history would show it:
# lines are piped to `tender secret set` on stdin, and files are passed by path. Options after `--` are passed to every call; shared
# secrets need `--node <n>` or `--all-nodes` there.
set -euo pipefail

if [[ $# -lt 1 ]]; then
    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 64
fi
source=$1
shift
if [[ $# -gt 0 && $1 == "--" ]]; then shift; fi
tender=${TENDER:-tender}

restore() {
    local name=$1
    shift
    echo "restoring $name" >&2
    "$tender" secret set "$name" "$@" >/dev/null
}

count=0
if [[ -d $source ]]; then
    while IFS= read -r -d '' file; do
        name=${file#"$source"}
        name=${name#/}
        # The file's path goes on the command line, its bytes never do.
        restore "$name" --from-file "$file" "$@" </dev/null
        count=$((count + 1))
    done < <(find "$source" -mindepth 2 -maxdepth 2 -type f ! -name '.*' -print0 | sort -z)
else
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -z ${line//[[:space:]]/} || $line =~ ^[[:space:]]*# ]] && continue
        if [[ $line != *=* ]]; then
            echo "skipping a line without '=' (not shown)" >&2
            continue
        fi
        # printf, not echo: a value may start with '-'. No trailing newline, so the
        # value is exactly what's after the '='.
        printf '%s' "${line#*=}" | restore "${line%%=*}" "$@"
        count=$((count + 1))
    done <"$source"
fi
echo "restored $count secrets" >&2
