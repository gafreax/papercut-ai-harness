# Sandbox notes

The settings that confine a run are **generated per run** by `bin/render.sh`
from `config.json`, into `<run_dir>/sandbox-settings.json`. There is no static
settings file to drift out of sync, and each run directory keeps a record of
exactly what that run was allowed to do.

## What the generated settings assert

```jsonc
{
  "permissions": {
    "defaultMode": "acceptEdits",        // never bypassPermissions
    "additionalDirectories": ["<workspace_root>"],
    "allow": ["Bash(<each verify command>:*)", ...]
  },
  "sandbox": {
    "enabled": true,
    "failIfUnavailable": true,           // no sandbox → no run, rather than a warning
    "allowUnsandboxedCommands": false,   // dangerouslyDisableSandbox is ignored
    "autoAllowBashIfSandboxed": true,    // required: headless has nobody to prompt
    "enableWeakerNetworkIsolation": true,
    "network": { "strictAllowlist": true, "allowedDomains": [...] },
    "filesystem": { "allowWrite": [...], "denyWrite": [...], "denyRead": [...] }
  }
}
```

## The two settings that deserve a second look

**`enableWeakerNetworkIsolation`** — reopens `com.apple.trustd.agent`. Needed
because Go-based CLIs (`gh`, `acli`, `gcloud`, `terraform`) verify TLS through
`trustd` and otherwise fail with `x509: OSStatus -26276`, even when `curl` to
the same host succeeds; `SSL_CERT_FILE` does not help on macOS. It is a narrow
exfiltration side-channel. Egress stays confined to `allowedDomains`. If your
checks and code host are reachable without Go CLIs, set it to `false`.

**`autoAllowBashIfSandboxed`** — sandboxed commands run without prompting. This
is what makes headless operation possible at all; the safety comes from the
sandbox around those commands, not from a human approving each one.
It does not cover everything, though: headless Claude Code still asked
approval for `HUSKY=0 pnpm install --frozen-lockfile`, and with nobody to
answer, the call was refused. So `permissions.allow` names every `verify`
command from `config.json` (install, hook install, hook probe, checks), with
and without its leading `VAR=value` assignments. The prompt tells workers to
run them as written, from inside the worktree: `pnpm --dir …` or `-C` would
not match the rule.

When a worker is stopped by the environment anyway, the agent writes
`<run_dir>/blocked.txt`. The runner then logs `BLOCKED:`, notifies "blocked by
the environment" instead of "nothing to do", and counts the run in the abort
streak.

## Getting the allowlist right

A missing domain shows up as a **DNS or connect failure inside the run**, not as
a permission error — easy to misread as "the network is down". Include:

- the package registry (and any tarball host it redirects to);
- the code host: API and git endpoints are often different hostnames;
- the tracker, plus its auth/identity hosts if it uses OAuth;
- **any private API a codegen step introspects** — the one everyone forgets.

## Extending writes

`allowWrite` must cover wherever the package manager writes outside the repo:
its content-addressable store, its cache, and tmp. Symptom of a missing entry:
`install` fails with `EACCES`/`EPERM` on a path in the home directory.

`denyWrite` is for things inside the workspace that must stay read-only — the
environment-file source, and the harness's own prompt and settings, so a run
cannot rewrite the rules it runs under.
