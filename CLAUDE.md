# Project: csyn-consensus-prod (Consensus XRPL prod/mainnet regulated infra)

OpenTofu for the Cloud Syndicate Consensus XRPL **prod / mainnet regulated** workloads
(`ledger/prod` folder). Split from `csyn-consensus-infra` per **CONSPLIT2**
(2026-06-20). Practice/testnet workloads live in sibling repo `csyn-consensus-infra`.
See [README.md](README.md) for the charter.

## What this repo is (and is not)

- **Is:** the prod roots (`ledger-workloads/validator-prod` and future prod roots),
  referencing modules by tag from sibling.
- **Is not:** org substrate (see `cloud-syndicate-platform/...`). Practice roots are in sibling `csyn-consensus-infra`.

## Apply identity — this repo is 100% ledger

CI **always** impersonates `ledger-apply@csyn-platform.iam.gserviceaccount.com`
(folder-scoped to `ledger/{dev,prod}`). There is **no** SA-selection ternary
(unlike `cloud-syndicate-platform`, which multiplexes several apply SAs). The SA,
its folder/state grants, and the principalSet that lets this repo impersonate it
are defined in `cloud-syndicate-platform/bootstrap/org-foundation/ledger-apply-sa.tf`
— **Pete-apply-only**.

## Infra rules

- **OpenTofu only, pinned 1.12.0.** Use `tofu`, never `terraform` — the provider
  cache + `.terraform.lock.hcl` hashes are not interchangeable. CI uses
  `opentofu/setup-opentofu@847eaa4 # v2.0.1`. Regenerate locks with
  `tofu providers lock -platform=linux_amd64 -platform=darwin_arm64`.
- **Provider mirror is mandatory.** All provider installs route through the
  CS-owned mirror via **`TF_CLI_CONFIG_FILE`** pointing at
  `.ci/tofu-mirror.tofurc`. The env var is `TF_CLI_CONFIG_FILE` (Terraform-compat
  name) — **`TOFU_CLI_CONFIG_FILE` is silently ignored** by OpenTofu and falls
  back to the public registry. Locally: `export TF_CLI_CONFIG_FILE="$PWD/.ci/tofu-mirror.tofurc"`.
- **State is unchanged.** `csyn-tf-state` bucket, `ledger-workloads/<root>`
  prefixes. Never change a backend prefix — that would orphan live state.
- **`billing_project = "csyn-platform"` + `user_project_override = true`** in
  every provider block (the workload projects are under the `ledger/` folder, not
  the platform project). Corollary — **any API new to the estate must ALSO be
  enabled on the quota project `csyn-platform`** (home:
  `cloud-syndicate-platform/shared-services/platform-services.tf` `platform_apis`),
  else a 403 *"<API> has not been used in project csyn-platform"* even when the
  workload project has it. Hit twice (servicenetworking, sqladmin); 2026-06-18.
- **First-of-kind resource → specialist pre-consult.** Before authoring the FIRST
  instance of a GCP resource type new to this repo (first Cloud SQL, first Cloud
  Run, first LB, …), run a `gcp-arch-expert:gcp-ask <specialist>` consult for its
  current prerequisites + provider defaults — don't go straight to apply. (Wave-1
  flare-sys's first Cloud SQL took 4 apply passes on prerequisites a pre-consult
  would have surfaced: Shared-VPC private-IP needs the Service Networking API on
  the instance's OWN project; the provider now defaults to `ENTERPRISE_PLUS` so
  shared-core tiers need `edition = "ENTERPRISE"`; SM `auto{}` replication violates
  the us-only `gcp.resourceLocations` policy → `user_managed` regional. 2026-06-18.)

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
- CONSPLIT2: `cloud-syndicate-platform/docs/everforge-readiness/decisions/2026-06-20-always-split-consensus-repos.md` (always-split practice vs prod)
- Index: `~/.ai-decisions.md`. **Name guard:** not `cs-ledger-infra`.

The practice repo owns only `ledger/dev` workloads + shared modules.
