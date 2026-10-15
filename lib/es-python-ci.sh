#!/bin/sh
# es-python CI driver
#
# Installs es-python on a CI runner, runs your test command under it, and fails
# the build when that run reported findings at or above a severity you choose.
#
#   sh es-python-ci.sh run     [options] -- <command> [args...]
#   sh es-python-ci.sh install [options]
#   sh es-python-ci.sh check   [options] --since <time>
#
# Needs EYALSEC_API_KEY in the environment, taken from your CI secret store.
# Never write the key into this file, a workflow file or an image.
#
# Run this script with sh. Do not source it.
#
# Options (each has an environment variable with the same effect):
#   --machine NAME        EYALSEC_MACHINE         the machine name for this pipeline (required)
#   --distro ID           EYALSEC_DISTRO          e.g. ubuntu_24_04 (needed the first time)
#   --arch ARCH           EYALSEC_ARCH            x86_64 or aarch64 (needed the first time)
#   --python-version V    EYALSEC_PYTHON_VERSION  e.g. 3.12 (first time only; defaults to the usual default)
#   --fail-on SEVERITY    EYALSEC_FAIL_ON         critical, high (default), medium, low, info or never
#   --new-only            EYALSEC_NEW_ONLY=1      fail only on findings never seen before on your account
#   --sources LIST        EYALSEC_SOURCES         comma list; default socket,file; "dashboard" uses
#                                                 only the machine's settings on the dashboard
#   --wait SECONDS        EYALSEC_WAIT            pause before asking for findings (default 10)
#   --since TIME          EYALSEC_SINCE           window start (RFC3339, Unix seconds or an HTTP date);
#                                                 "run" starts it just before your command by itself
#   --skip-install        EYALSEC_SKIP_INSTALL=1  "run" uses an es-python installed earlier in the job
#   --url URL             EYALSEC_URL             your EyalSec address
#
# Exit status: 0 nothing at or above the threshold; 3 findings at or above it;
# 4 the driver itself could not do its job (key, install, network); anything
# else is your command's own non-zero status, which always wins.

# Sourcing guard. bash and zsh can tell they are sourcing a file; a plain POSIX
# sh cannot, which is why everything below also runs in a subshell and ends in a
# return-or-exit that is harmless either way.
__es_ci_sourced=0
# shellcheck disable=SC3028,SC3054
if [ -n "${BASH_VERSION:-}" ] && [ "${BASH_SOURCE:-$0}" != "$0" ]; then
    __es_ci_sourced=1
elif [ -n "${ZSH_EVAL_CONTEXT:-}" ]; then
    case "$ZSH_EVAL_CONTEXT" in *:file*) __es_ci_sourced=1 ;; esac
fi

__es_ci_main() (
    url_default='__ES2_SERVER_URL__'

    say()  { printf '%s\n' "$*"; }
    warn() { printf 'es-python-ci: %s\n' "$*" >&2; }
    die()  { warn "$*"; exit 4; }

    usage() {
        say "usage: sh es-python-ci.sh run [options] -- <command> [args...]"
        say "       sh es-python-ci.sh install [options]"
        say "       sh es-python-ci.sh check [options] --since <time>"
        say "Options are listed at the top of this script."
    }

    mode="${1:-}"
    case "$mode" in
        run|install|check) shift ;;
        -h|--help|help) usage; exit 0 ;;
        *) usage >&2; exit 4 ;;
    esac

    machine="${EYALSEC_MACHINE:-}"
    distro="${EYALSEC_DISTRO:-}"
    arch="${EYALSEC_ARCH:-}"
    pyver="${EYALSEC_PYTHON_VERSION:-}"
    fail_on="${EYALSEC_FAIL_ON:-high}"
    new_only="${EYALSEC_NEW_ONLY:-0}"
    sources="${EYALSEC_SOURCES:-socket,file}"
    wait_s="${EYALSEC_WAIT:-10}"
    since=""
    [ "$mode" = check ] && since="${EYALSEC_SINCE:-}"
    skip_install="${EYALSEC_SKIP_INSTALL:-0}"
    base="${EYALSEC_URL:-$url_default}"

    need_arg() { [ "$#" -ge 2 ] || die "$1 needs a value"; }
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --machine)        need_arg "$@"; machine="$2"; shift 2 ;;
            --distro)         need_arg "$@"; distro="$2"; shift 2 ;;
            --arch)           need_arg "$@"; arch="$2"; shift 2 ;;
            --python-version) need_arg "$@"; pyver="$2"; shift 2 ;;
            --fail-on)        need_arg "$@"; fail_on="$2"; shift 2 ;;
            --new-only)       new_only=1; shift ;;
            --sources)        need_arg "$@"; sources="$2"; shift 2 ;;
            --wait)           need_arg "$@"; wait_s="$2"; shift 2 ;;
            --since)          need_arg "$@"; since="$2"; shift 2 ;;
            --skip-install)   skip_install=1; shift ;;
            --url)            need_arg "$@"; base="$2"; shift 2 ;;
            --) shift; break ;;
            *) die "unknown option: $1 (put your command after --)" ;;
        esac
    done

    # ── Checks that need no network ──────────────────────────────────────────
    # The pattern is split by quotes on purpose: the server replaces every
    # whole copy of the placeholder with its address when it serves this file,
    # and a whole copy here would become that address too, refusing every run.
    case "$base" in
        *__ES2_SERVER"_URL__"*|'') die "set EYALSEC_URL to your EyalSec address (or download this script from it at /ci.sh)" ;;
    esac
    base="${base%/}"
    [ -n "${EYALSEC_API_KEY:-}" ] || die "EYALSEC_API_KEY is not set. Add your API key to the CI secret store and pass it in as EYALSEC_API_KEY."
    [ -n "$machine" ] || die "--machine (or EYALSEC_MACHINE) is required: one name per pipeline, such as ci-myrepo"
    case "$fail_on" in
        critical|high|medium|low|info|never) ;;
        *) die "--fail-on must be critical, high, medium, low, info or never" ;;
    esac
    case "$wait_s" in ''|*[!0-9]*) die "--wait must be a whole number of seconds" ;; esac
    if [ "$mode" = run ] && [ "$#" -eq 0 ]; then
        die "run needs a command after --, for example: -- es-python -m pytest"
    fi
    if [ "$mode" = check ] && [ -z "$since" ]; then
        die "check needs --since (or EYALSEC_SINCE): the moment your run started"
    fi
    command -v curl >/dev/null 2>&1 || die "curl is required"

    work="$(mktemp -d 2>/dev/null)" || die "mktemp failed"
    trap 'rm -rf "$work"' EXIT
    trap 'exit 130' INT TERM
    # The key goes to curl through a 0600 file, never on its command line,
    # where any other process on the runner could read it.
    (umask 077 && printf 'X-API-Key: %s\n' "$EYALSEC_API_KEY" > "$work/hdr") || die "cannot write a temporary file"

    # api METHOD PATH [curl args...]: the response body lands in $work/body and
    # the HTTP status is printed. 000 means the server could not be reached.
    api() {
        __m="$1"; __p="$2"; shift 2
        curl -sS -X "$__m" -H "@$work/hdr" -o "$work/body" -w '%{http_code}' \
            --retry 2 --retry-delay 3 "$@" "$base$__p" 2>"$work/curlerr" || true
    }
    # kv KEY: one value from a key=value answer.
    kv() { sed -n "s/^$1=//p" "$work/body" 2>/dev/null | head -n 1; }
    api_fail() {
        __msg="$(kv error)"
        [ -n "$__msg" ] || __msg="$(head -c 300 "$work/body" 2>/dev/null)"
        [ -n "$__msg" ] || __msg="$(cat "$work/curlerr" 2>/dev/null)"
        die "$1 failed (HTTP $2): $__msg"
    }

    # ── install ─────────────────────────────────────────────────────────────
    do_install() {
        say "es-python-ci: preparing machine $machine on $base"
        set -- -d attested=true -d format=text --data-urlencode "machine_name=$machine"
        [ -n "$distro" ] && set -- "$@" --data-urlencode "distro=$distro"
        [ -n "$arch" ] && set -- "$@" --data-urlencode "arch=$arch"
        [ -n "$pyver" ] && set -- "$@" --data-urlencode "python_version=$pyver"
        code="$(api POST /api/ci/install/ "$@")"
        [ "$code" = 200 ] || api_fail "getting an install command" "$code"
        secret="$(kv secret)"
        script="$(kv script_path)"
        since="$(kv server_time)"
        [ -n "$secret" ] && [ -n "$script" ] || die "the server's answer had no install secret"
        say "es-python-ci: machine $(kv machine_name) ($(kv os_type), Python $(kv python_version)); installing"
        command -v bash >/dev/null 2>&1 || die "bash is required to run the installer"
        (umask 077 && printf 'secret=%s' "$secret" > "$work/sec") || die "cannot write a temporary file"
        glibc="$(ldd --version 2>/dev/null | head -n 1)"
        host_arch="$(uname -m 2>/dev/null)"
        tries=0
        while :; do
            tries=$((tries + 1))
            icode="$(curl -sS -o "$work/install.sh" -w '%{http_code}' -d "@$work/sec" \
                --data-urlencode "glibc=$glibc" --data-urlencode "arch=$host_arch" \
                "$script" 2>"$work/curlerr" || true)"
            # 503 is "busy, retry": the one-time secret is still valid then.
            [ "$icode" = 503 ] && [ "$tries" -lt 4 ] && { say "es-python-ci: install service busy, retrying in 30s"; sleep 30; continue; }
            break
        done
        rm -f "$work/sec"
        case "$icode" in
            200) ;;
            000) die "could not reach $script: $(cat "$work/curlerr")" ;;
            *)
                # Refusals come back as a short script that prints the reason.
                if head -n 1 "$work/install.sh" | grep -q '^#'; then
                    bash "$work/install.sh" || true
                fi
                die "the install was refused (HTTP $icode)"
                ;;
        esac
        # Executed, not sourced: it must not touch this shell.
        bash "$work/install.sh" || die "the es-python install failed (see the lines above)"
        PATH="$HOME/.local/bin:$PATH"
        export PATH
        # GitHub Actions: later steps of this job find es-python too.
        if [ -n "${GITHUB_PATH:-}" ]; then
            printf '%s\n' "$HOME/.local/bin" >> "$GITHUB_PATH"
        fi
        if [ -n "${GITHUB_ENV:-}" ]; then
            printf 'EYALSEC_SINCE=%s\nEYALSEC_MACHINE=%s\n' "$since" "$machine" >> "$GITHUB_ENV"
        fi
    }

    # The server's clock, from the Date header of a public page, so a runner
    # whose clock is off cannot move the window. Empty when unreachable.
    server_date() {
        curl -sS -o /dev/null -D - "$base/healthz" 2>/dev/null |
            sed -n 's/^[Dd][Aa][Tt][Ee]: *//p' | tr -d '\r' | head -n 1
    }

    # ── sources ─────────────────────────────────────────────────────────────
    # Environment defaults only: an explicit On or Off on the dashboard for this
    # machine still wins, exactly as for a flag on the command line.
    set_sources() {
        [ "$sources" = dashboard ] && return 0
        __old_ifs="$IFS"; IFS=','
        # shellcheck disable=SC2086
        set -- $sources
        IFS="$__old_ifs"
        for __s in "$@"; do
            case "$__s" in
                socket)      ES2_MAKE_SOCKET_VULN=1;      export ES2_MAKE_SOCKET_VULN ;;
                file)        ES2_MAKE_FILE_VULN=1;        export ES2_MAKE_FILE_VULN ;;
                stdin)       ES2_MAKE_STDIN_VULN=1;       export ES2_MAKE_STDIN_VULN ;;
                env)         ES2_MAKE_ENV_VULN=1;         export ES2_MAKE_ENV_VULN ;;
                foreign)     ES2_MAKE_FOREIGN_VULN=1;     export ES2_MAKE_FOREIGN_VULN ;;
                weak_random) ES2_MAKE_WEAKRANDOM_VULN=1;  export ES2_MAKE_WEAKRANDOM_VULN ;;
                hardcoded)   ES2_MAKE_SECRET_VULN=1;      export ES2_MAKE_SECRET_VULN ;;
                db_rows)     ES2_MAKE_DB_ROWS_VULN=1;     export ES2_MAKE_DB_ROWS_VULN ;;
                everything)  ES2_MAKE_EVERYTHING_VULN=1;  export ES2_MAKE_EVERYTHING_VULN ;;
                '') ;;
                *) die "unknown source: $__s (socket, file, stdin, env, foreign, weak_random, hardcoded, db_rows, everything, or dashboard)" ;;
            esac
        done
    }

    # ── check ───────────────────────────────────────────────────────────────
    # Prints the summary and returns 0 (pass) or 3 (findings at the threshold).
    do_check() {
        min="$fail_on"
        [ "$min" = never ] && min=info
        code="$(api GET "/api/ci/findings/" -G -d format=text -d limit=20 \
            --data-urlencode "machine=$machine" --data-urlencode "since=$since" \
            --data-urlencode "min_severity=$min")"
        [ "$code" = 200 ] || api_fail "asking for findings" "$code"
        total="$(kv total)"; found="$(kv findings)"; fresh="$(kv new_findings)"
        say ""
        say "es-python findings for machine $machine since $(kv since)"
        say "  reported by this run: $total (critical $(kv critical), high $(kv high), medium $(kv medium), low $(kv low), info $(kv info))"
        if [ "$fail_on" != never ]; then
            say "  at or above $fail_on: $found, of which $fresh new"
        fi
        # Line shape: id severity new|seen count last_seen label...
        sed -n 's/^event=//p' "$work/body" | while IFS=' ' read -r id sev state count _last where; do
            printf '    %-8s %-4s %s (event %s, %s occurrences in total)\n' "$sev" "$state" "$where" "$id" "$count"
        done
        hidden="$(kv hidden_by)"
        [ -n "$hidden" ] && say "  note: your Hide rule \"$hidden\" hides every es-python event, so nothing can be counted"
        [ "$(kv truncated)" = true ] && say "  note: this run reported more distinct events than one check reads; the counts are a lower bound"
        if [ "${total:-0}" = 0 ]; then
            say "  es-python reported nothing. If you expected findings, check that your command"
            say "  ran under es-python and that the sources you need are on (--sources)."
        fi
        say "  details: $(kv url)"
        [ "$fail_on" = never ] && return 0
        if [ "$new_only" = 1 ]; then
            [ "${fresh:-0}" = 0 ] && return 0
            say "es-python-ci: FAIL, $fresh new finding(s) at or above $fail_on"
            return 3
        fi
        [ "${found:-0}" = 0 ] && return 0
        say "es-python-ci: FAIL, $found finding(s) at or above $fail_on"
        return 3
    }

    case "$mode" in
        install)
            do_install
            say "es-python-ci: installed. Run your code with es-python (in $HOME/.local/bin)."
            say "es-python-ci: window start for a later check: $since"
            exit 0
            ;;
        check)
            do_check
            exit $?
            ;;
    esac

    # run
    if [ "$skip_install" = 1 ]; then
        PATH="$HOME/.local/bin:$PATH"
        export PATH
    else
        given_since="$since"
        do_install
        since="$given_since"
    fi
    command -v es-python >/dev/null 2>&1 || die "es-python is not on PATH after the install"
    set_sources
    # The window opens just before the command, on the server's clock, so the
    # install and anything earlier in the job are not counted. Without a Date
    # header, this runner's clock a minute early.
    if [ -z "$since" ]; then
        since="$(server_date)"
        [ -n "$since" ] || since="$(( $(date -u +%s) - 60 ))"
    fi
    say "es-python-ci: running: $*"
    rc=0
    "$@" || rc=$?
    say "es-python-ci: command finished with status $rc; waiting ${wait_s}s for its events to arrive"
    sleep "$wait_s"
    # In a subshell so that a failed check (exit 4) cannot hide the
    # command's own status, which always wins.
    check_rc=0
    ( do_check ) || check_rc=$?
    [ "$rc" != 0 ] && exit "$rc"
    exit "$check_rc"
)

if [ "$__es_ci_sourced" = 1 ]; then printf 'es-python-ci: run this script with sh, do not source it\n' >&2; return 2; fi
# One line, so a shell reading this script from a pipe has read all of it
# before your command runs and can never hand it the rest as input. return
# when sourced, exit when run.
# shellcheck disable=SC2317
{ __es_ci_rc=0; __es_ci_main "$@" || __es_ci_rc=$?; return "$__es_ci_rc" 2>/dev/null || exit "$__es_ci_rc"; }
