#!/usr/bin/env bash
# EyalSec es-python GitHub Action: install es-python on the runner, run the
# command under it, then summarise what that run reported.
#
# The install and the findings check are done by lib/es-python-ci.sh, the same
# CI driver EyalSec serves at /ci.sh, so the action and a hand-written pipeline
# behave the same way. This file adds what is specific to GitHub: reading the
# target from the runner, the job summary and the step outputs.
#
# The API key reaches curl only through the driver, which passes it in a 0600
# header file, never on a command line. Nothing here prints it.
# The single-quoted backticks below are Markdown for the job summary.
# shellcheck disable=SC2016
set -uo pipefail

driver="$GITHUB_ACTION_PATH/lib/es-python-ci.sh"
out="${GITHUB_OUTPUT:-/dev/null}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"

note()  { printf 'es-python: %s\n' "$*"; }
fatal() {
    printf '::error title=es-python::%s\n' "$*"
    printf 'result=error\n' >> "$out"
    {
        printf '### es-python\n\n'
        printf 'The action stopped before it could check this run: %s\n' "$*"
    } >> "$summary"
    exit 4
}

# ── Inputs ──────────────────────────────────────────────────────────────────
if [ -z "${EYALSEC_API_KEY:-}" ]; then
    fatal "api-key is empty. Add your EyalSec API key as a repository secret and pass it as api-key. GitHub does not give secrets to workflows started by pull requests from forks."
fi
printf '::add-mask::%s\n' "$EYALSEC_API_KEY"
[ -n "${INPUT_RUN//[[:space:]]/}" ] || fatal "run is empty: give the command to run under es-python, for example es-python -m pytest"

url="${INPUT_URL:-https://eyalsec.com}"
url="${url%/}"
case "$url" in
    https://*) ;;
    *) fatal "url must start with https:// (got: $url)" ;;
esac

machine="${INPUT_MACHINE:-}"
if [ -z "$machine" ]; then
    machine="ci-${REPO_NAME:-${GITHUB_REPOSITORY##*/}}"
fi

case "${INPUT_NEW_ONLY:-false}" in
    true|1|yes) new_only=1 ;;
    false|0|no|'') new_only=0 ;;
    *) fatal "new-only must be true or false" ;;
esac

# ── The runner's target, as EyalSec names it ────────────────────────────────
distro="${INPUT_DISTRO:-}"
if [ -z "$distro" ] && [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    os_id="$(. /etc/os-release && printf '%s' "${ID:-}")"
    # shellcheck disable=SC1091
    os_ver="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"
    case "$os_id" in
        ubuntu) distro="ubuntu_${os_ver//./_}" ;;
        debian) distro="debian_${os_ver%%.*}" ;;
        rhel|rocky|almalinux|centos) distro="rhel_${os_ver%%.*}" ;;
        amzn) distro="amazonlinux_${os_ver%%.*}" ;;
        fedora) distro="fedora_latest" ;;
        arch) distro="arch_latest" ;;
    esac
fi
[ -n "$distro" ] || fatal "could not tell this runner's operating system. Set the distro input, for example ubuntu_24_04."

arch="${INPUT_ARCH:-}"
if [ -z "$arch" ]; then
    case "$(uname -m)" in
        x86_64|amd64) arch=x86_64 ;;
        aarch64|arm64) arch=aarch64 ;;
        *) fatal "es-python runs on x86_64 and aarch64; this runner is $(uname -m)" ;;
    esac
fi

pyver="${INPUT_PYTHON_VERSION:-}"
if [ -z "$pyver" ] && command -v python3 >/dev/null 2>&1; then
    pyver="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)"
fi

export EYALSEC_URL="$url" EYALSEC_MACHINE="$machine" EYALSEC_DISTRO="$distro" EYALSEC_ARCH="$arch"
export EYALSEC_FAIL_ON="${INPUT_FAIL_ON:-high}" EYALSEC_SOURCES="${INPUT_SOURCES:-socket,file}"
export EYALSEC_WAIT="${INPUT_WAIT:-10}" EYALSEC_NEW_ONLY="$new_only"
[ -n "$pyver" ] && export EYALSEC_PYTHON_VERSION="$pyver"

# ── Install ─────────────────────────────────────────────────────────────────
note "machine $machine, target ${distro}/${arch}${pyver:+, Python $pyver}"
echo "::group::Install es-python"
sh "$driver" install
install_rc=$?
echo "::endgroup::"
[ "$install_rc" = 0 ] || fatal "the es-python install did not complete (status $install_rc). The lines in the Install es-python group above say why."
export PATH="$HOME/.local/bin:$PATH"

# The window opens just before the command, on EyalSec's clock, so a runner
# whose clock is off cannot move it. The driver does the same when left alone;
# taking it here lets the summary below ask about the same window.
since="$(curl -sS -o /dev/null -D - "$url/healthz" 2>/dev/null |
    sed -n 's/^[Dd][Aa][Tt][Ee]: *//p' | tr -d '\r' | head -n 1)"
[ -n "$since" ] || since="$(( $(date -u +%s) - 60 ))"

# ── Run and check ───────────────────────────────────────────────────────────
script="$(mktemp)"
printf '%s\n' "$INPUT_RUN" > "$script"
rc=0
sh "$driver" run --skip-install --since "$since" -- bash -e "$script" || rc=$?
rm -f "$script"

case "$rc" in
    0) result=pass ;;
    3) result=fail ;;
    4) result=error ;;
    *) result=command-failed ;;
esac

# ── Summary ─────────────────────────────────────────────────────────────────
# One more read of the same window, for the job summary and the outputs. The
# value that reached the operation is never in this answer, by design: CI logs
# and summaries are often public.
min="$EYALSEC_FAIL_ON"
[ "$min" = never ] && min=info
body="$(mktemp)"
hdr="$(mktemp)"
(umask 077 && printf 'X-API-Key: %s\n' "$EYALSEC_API_KEY" > "$hdr")
code="$(curl -sS -G -H "@$hdr" -o "$body" -w '%{http_code}' \
    -d format=text -d limit=20 \
    --data-urlencode "machine=$machine" --data-urlencode "since=$since" \
    --data-urlencode "min_severity=$min" \
    "$url/api/ci/findings/" 2>/dev/null || true)"
rm -f "$hdr"
kv() { sed -n "s/^$1=//p" "$body" | head -n 1; }

{
    printf 'result=%s\n' "$result"
    if [ "$code" = 200 ]; then
        printf 'total=%s\nfindings=%s\nnew-findings=%s\nevents-url=%s\n' \
            "$(kv total)" "$(kv findings)" "$(kv new_findings)" "$(kv url)"
    fi
} >> "$out"

{
    case "$result" in
        pass) verdict="Passed" ;;
        fail) verdict="Failed: findings at or above **$EYALSEC_FAIL_ON**" ;;
        error) verdict="Stopped: the check could not complete (see the step log)" ;;
        *) verdict="Your command exited with status $rc" ;;
    esac
    printf '### es-python: %s\n\n' "$verdict"
    if [ "$code" = 200 ]; then
        printf 'Machine `%s`, events reported since %s.\n\n' "$machine" "$(kv since)"
        printf '| Reported by this run | Critical | High | Medium | Low | Info |\n'
        printf '|---:|---:|---:|---:|---:|---:|\n'
        printf '| %s | %s | %s | %s | %s | %s |\n\n' "$(kv total)" "$(kv critical)" \
            "$(kv high)" "$(kv medium)" "$(kv low)" "$(kv info)"
        if [ -n "$(kv event)" ]; then
            printf '| Severity | | Operation | Event | Occurrences, all runs |\n'
            printf '|---|---|---|---:|---:|\n'
            # Line shape: id severity new|seen count last_seen label...
            sed -n 's/^event=//p' "$body" | while IFS=' ' read -r id sev state count _last where; do
                printf '| %s | %s | `%s` | %s | %s |\n' "$sev" "$state" "${where//|/\\|}" "$id" "$count"
            done
            printf '\n'
        fi
        [ -n "$(kv hidden_by)" ] && printf 'Your Hide rule "%s" hides every es-python event, so nothing could be counted.\n\n' "$(kv hidden_by)"
        [ "$(kv truncated)" = true ] && printf 'This run reached more distinct events than one check reads; the counts are a lower bound.\n\n'
        if [ "$(kv total)" = 0 ]; then
            printf 'es-python reported nothing. If you expected findings, check that the command ran under `es-python` and that the sources you need are on.\n\n'
        fi
        printf '**new** means no earlier run had reached that finding. The value that reached each operation is kept off this page; open the event on the dashboard to see the whole flow.\n\n'
        printf '[Open these events on your dashboard](%s)\n' "$(kv url)"
    else
        printf 'The findings could not be read for the summary (HTTP %s). The step log has the check.\n' "${code:-none}"
    fi
} >> "$summary"
rm -f "$body"

exit "$rc"
