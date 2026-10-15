# es-python for GitHub Actions

**Run your test suite under es-python in GitHub Actions. Every injection flow your tests reach is summarised on the run's page, and the job fails at the severity you choose.**

[![Website](https://img.shields.io/badge/website-eyalsec.com-e8b04b)](https://eyalsec.com)
[![Docs](https://img.shields.io/badge/docs-run%20in%20CI-2a2c27)](https://eyalsec.com/docs/ci)

Your tests already drive your code through its real paths. With this action
they also tell you when untrusted data on one of those paths reached a SQL
query, a shell command, a deserializer, a file path or a dynamic import.
Keep the test runner, the linters and the scanners you use today; this adds
one step next to them.

**For:** teams with an EyalSec account that includes es-python, on Linux
runners (x86_64 or aarch64), Python 3.9 to 3.14.

## Quick start

1. On your EyalSec dashboard, open **Settings > API access** and create a
   full-access key ([API keys](https://eyalsec.com/docs/api-keys)).
2. In your repository, add it as an Actions secret named `EYALSEC_API_KEY`
   (**Settings > Secrets and variables > Actions**).
3. Add the step after your dependencies are installed:

```yaml
name: tests
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-24.04
    # One run at a time per machine: a second install would stop the first
    # run's es-python from reporting.
    concurrency:
      group: es-python-${{ github.repository }}
      cancel-in-progress: false
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.13"
      - run: pip install -r requirements.txt pytest
      - uses: EyalSec/es-python-action@v1
        with:
          api-key: ${{ secrets.EYALSEC_API_KEY }}
          run: es-python -m pytest
```

Wherever you would type `python`, the command types `es-python`. It uses the
packages installed for the runner's own Python of the same version, which is
why the step comes after `pip install`.

## What you see

After the command, the step log prints the check, and the run's summary page
gets a table like this one, from this repository's own
[end-to-end test](.github/workflows/e2e.yml), whose deliberately vulnerable
[example](example/) joins text received over a network connection into a
shell command:

> ### es-python: Failed: findings at or above **high**
>
> | Reported by this run | Critical | High | Medium | Low | Info |
> |---:|---:|---:|---:|---:|---:|
> | 10 | 3 | 0 | 0 | 0 | 7 |
>
> | Severity | | Operation | Event | Occurrences, all runs |
> |---|---|---|---:|---:|
> | critical | new | `subprocess exec` | 22517588 | 1 |
> | critical | new | `subprocess shell` | 22517587 | 1 |
> | critical | new | `shell injection` | 22517546 | 1 |

**new** means no earlier run had reached that finding; **seen** means one
had. The value that reached the operation is never printed in the log or the
summary, because CI pages are often public. Follow the link at the bottom of
the summary to the dashboard for the whole flow: where the data came in, the
call path, and the line that used it.

## Inputs

| Input | Default | Meaning |
|---|---|---|
| `api-key` | required | Your EyalSec API key, from a secret. Full access, because installing is a write. |
| `run` | required | The command to run under es-python, in bash. Several lines run as one script that stops at the first failing line. |
| `machine` | `ci-<repository name>` | The EyalSec machine this job reports under, created on the first run. |
| `url` | `https://eyalsec.com` | Your EyalSec address. |
| `python-version` | the runner's `python3` | The Python version, fixed when the machine is created. |
| `distro`, `arch` | read from the runner | The runner's target as EyalSec names it, such as `ubuntu_24_04` and `x86_64`. See [supported targets](https://eyalsec.com/docs/api-machines#os-types). |
| `fail-on` | `high` | `critical`, `high`, `medium`, `low`, `info`, or `never` to report without failing. |
| `new-only` | `false` | Fail only on findings no earlier run had reached. |
| `sources` | `socket,file` | The [taint sources](https://eyalsec.com/docs/taint-sources) to switch on for the command, comma-separated, or `dashboard` to use only the machine's Configure settings. |
| `wait` | `10` | Seconds to wait for the run's events to arrive before checking. |
| `working-directory` | `.` | Where the command runs. |

A source set here is a default for the run: an explicit **On** or **Off** for
the same source on your dashboard still wins.

## Outputs

| Output | Meaning |
|---|---|
| `result` | `pass`, `fail` (findings at the threshold), `error` (the action could not do its job), or `command-failed`. |
| `total` | Every event the run reached, at any severity. |
| `findings` | Those at or above `fail-on`. |
| `new-findings` | Of `findings`, the ones no earlier run had reached. |
| `events-url` | The dashboard's events list for this machine. |

The step fails when your command fails (its own exit status is kept), when
findings reach `fail-on`, or when the action cannot install or check. To keep
the job going and decide yourself, set `continue-on-error: true` on the step
and read `result`.

## Things to know

- **One run per machine at a time.** Each run reinstalls the machine with a
  fresh one-time install secret, so no machine credential is ever cached, and
  a second job installing the same machine stops the first one's reporting.
  Use `concurrency` as above, or give each job its own `machine`.
- **Matrix builds need one machine per leg**, for example
  `machine: ci-myrepo-py${{ matrix.python }}`. A machine's Python version is
  fixed when it is created, and each name counts once against your machine
  limit however often it runs.
- **Pull requests from forks get no secrets**, so the step stops with
  "api-key is empty". To run those tests without es-python, add
  `if: github.event.pull_request.head.repo.fork != true` to this step and a
  plain test step with the opposite condition.
- **Accepting a finding.** A finding keeps failing the job on every run that
  reaches it, until the flow is fixed or you add a **Hide**
  [rule](https://eyalsec.com/docs/rules) for it. Hidden and suppressed events
  never fail a build.
- **The API key acts as you.** Keep it in the secret store, and regenerate it
  if a log or a fork ever exposed it. The action passes it to `curl` through a
  private file, never on a command line, and masks it in the log.
- **Events are kept like any other**: they count toward your event quota and
  appear on the Events page under the CI machine's name.

The same flow without this action, and for GitLab CI, is in
[Run es-python in CI](https://eyalsec.com/docs/ci).
`lib/es-python-ci.sh` is the CI driver described there, and it can be run on
its own.

## Getting access

**[Book a live demo](https://eyalsec.com/contact)** and we run it on your own
code with you. There is no self-serve plan and no trial; pricing is metered by
machines and events ([eyalsec.com/pricing](https://eyalsec.com/pricing)).

## Support and security

- Questions and problems: **support@eyalsec.com**, or an
  [issue](https://github.com/EyalSec/es-python-action/issues) here. Never paste
  an API key or an install command into an issue.
- A vulnerability in EyalSec itself: **security@eyalsec.com**, under our
  [disclosure policy](https://eyalsec.com/legal/vulnerability-disclosure).

More about es-python: **[EyalSec/es-python](https://github.com/EyalSec/es-python)**.

## License

[MIT](LICENSE) for the contents of this repository. es-python itself is
licensed with your EyalSec account.

---

Python is a trademark of the Python Software Foundation. EyalSec is not
affiliated with or endorsed by the PSF. GitHub and GitHub Actions are
trademarks of GitHub, Inc.
