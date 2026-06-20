# csyn-consensus-prod

OpenTofu for the **Cloud Syndicate Consensus XRPL prod / mainnet regulated** practice infra.
Owns the `ledger-workloads/*` prod roots (starting with `validator-prod`) that deploy into the GCP **`ledger/prod`** folder.

**Practice / testnet** workloads live in the sibling repo `csyn-consensus-infra`.

## This repo owns prod workloads; the *substrate* lives next door

The org substrate stays in the sister repo **`cloud-syndicate-platform`**
(bootstrap-class — applies locally from Pete's workstation, never from CI):

| Concern | Home |
|---|---|
| `ledger/{dev,prod}` GCP folders, org policies, audit sink | `cloud-syndicate-platform/bootstrap/org-foundation/` |
| The folder-scoped **`ledger-apply`** service account + its WIF principalSet | `cloud-syndicate-platform/bootstrap/org-foundation/ledger-apply-sa.tf` |
| The shared **`platform`** WIF pool (this repo registers as a consumer) | `cloud-syndicate-platform/wif/` |
| **This repo (prod):** the `ledger-workloads/*` prod roots (validator-prod + future) | `csyn-consensus-prod` |
| **Sibling (practice):** dev roots + shared modules + docker + image builds | `csyn-consensus-infra` |

**No Terraform state migration ever happened.** Every root uses the same
`csyn-tf-state` GCS bucket and the same `ledger-workloads/<root>` prefix.

## Apply model

CI (GitHub Actions) plans on PRs and applies on dispatch, **impersonating the
existing `ledger-apply@csyn-platform.iam.gserviceaccount.com`** (folder-scoped to
`ledger/{dev,prod}`). This repo creates no new apply identity. See
[docs/BOOTSTRAP.md in sibling](https://github.com/csyn-portfolio/csyn-consensus-infra/blob/main/docs/BOOTSTRAP.md) for how WIF auth is wired.

Changes to the SA itself, its grants, or the `ledger/` folder/org-policies are
**bootstrap-class** and happen in `cloud-syndicate-platform` (Pete-apply only) —
not here.

## Dev → prod

Practice lessons from the sibling repo carry forward via
**[docs/dev-to-prod-readiness.md](https://github.com/csyn-portfolio/cloud-syndicate-platform/blob/main/docs/everforge-readiness/dev-to-prod-readiness.md)**
(the cross-repo one-home plan).

**Read it before authoring any prod workload.**

## Safety rules — never skip

Ask before any **push**, **`apply.yml` dispatch**, branch-protection change, or
**merge to `main`** (it can trigger deploys). `tofu plan` and reads are fine
without asking. All changes go through a PR — no direct push to `main`. Secret
hygiene: never echo WIF provider names / tokens into chat; `gh secret set --body`
piped directly.

## Concurrent sessions

Pete runs 2–4 Claude/Grok sessions. If another session might be active on this
repo, do local commits in a `git worktree`, not the shared checkout.

## Decision home

- CONSPLIT1: `cloud-syndicate-platform/docs/everforge-readiness/decisions/2026-06-16-split-consensus-infra-repo.md`
- CONSPLIT2: `cloud-syndicate-platform/docs/everforge-readiness/decisions/2026-06-20-always-split-consensus-repos.md`
- Index: `~/.ai-decisions.md`. **Name guard:** not `cs-ledger-infra`
  (that's the cs-ledger plugin's canon infra — unrelated).