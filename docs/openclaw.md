# OpenClaw, an ops colleague (roadmap)

A plan, not built yet. It comes after [monitoring](monitoring.md), because it works from
what monitoring finds.

[OpenClaw](https://github.com/openclaw/openclaw) is an open source AI agent that runs on
your own machine and talks to you in a chat app. Here it watches the lab and works like a
colleague on the ops team: it notices problems, explains them, proposes fixes and talks
them through before it changes anything. It fixes small, safe things on its own and says
so afterwards.

## How it behaves

**It discusses first.** For anything that changes the lab it writes, in the chat:

- what it saw, with the alert, graph or log line
- what it thinks is wrong, and how sure it is
- what it would do: the exact `anvil` command, or a pull request
- what could go wrong, and how to undo it

Then it waits for a yes. A "no" or a question is a normal answer, not a failure.

**It fixes simple things on its own.** Only the actions on a short list, each one
reversible and each one reported after it is done:

- restart a container that crashed and is in a restart loop
- run `anvil apply` for a target whose check shows only a known, harmless drift, on a
  target that is not marked risky
- remove a dead download (no seeders, stuck for a day) and let the app search again
- clear disk space that the list names as safe to clear, such as old container images

The list lives in this repo. Adding to it is a reviewed pull request, never something the
agent decides.

**It never does these, even when asked in the chat:**

- the risky targets: `tf`, `cluster`, `switch`, `enclave`, `host-network`
- anything in the secrets enclave: Vault, Vaultwarden, their backups
- delete data, force-push, or merge its own pull requests
- read, print or move a secret

**Code changes go through pull requests.** It may open a branch and a pull request with
the fix and the reasoning. A person reviews and merges it, the same as any other change.

## Where it runs

- Its own VM on the second server. Nothing on the internet can reach it. It reaches out to
  the chat service and to the model API only.
- Its own accounts, each with the least access: read-only Grafana and Pulse, `anvil check`
  on every target, `anvil apply` only through the allowlist above, and a sudo rule for
  container restarts on the app VMs. No root on the Proxmox hosts. No route to the enclave.
- The chat is a private channel that only the operator is in. It ignores everyone else.
- Every action it takes, with the reason, goes to a log that it cannot edit.

## The model

It uses Claude through an **Anthropic API key**, kept in Vault and read at run time, with a
monthly spending limit set in the Anthropic console.

It does not use the token of a Claude Pro or Max subscription. Anthropic's terms do not
allow subscription logins in third-party tools such as OpenClaw, and accounts that did so
were blocked. An API key is the supported way to run an agent unattended.

## Risks to plan for

OpenClaw is powerful and young, and its known problems shape this plan:

- **Prompt injection.** It reads logs, web pages and chat text that someone else may have
  written. Text it reads can try to give it orders. The allowlist and the accounts above
  limit what such an order could do.
- **Third-party skills.** Skills from public skill stores have carried malware. Only skills
  written and reviewed in this repo are installed.
- **Cost.** A loop can spend money fast. The spending limit and a daily report of its usage
  cap that.

## Steps

1. Monitoring first: alerts it can read and act on.
2. The VM, the accounts and the read-only access. It only reports at first.
3. A week of it explaining alerts in the chat, with nothing it may do on its own.
4. The allowlist, one action at a time, each added after it proved useful.
5. Pull requests for code fixes.
