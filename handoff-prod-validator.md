# Handoff: csyn-consensus-prod (Prod/Mainnet Validator) Session

**Date:** 2026-06-20  
**From:** Grok  
**To:** Claude (start this session in /Users/pmorse/claude/cs/csyn-consensus-prod)  
**Context:** CONSPLIT2 (A+Clean) split is complete. This repo is now **pure prod/mainnet regulated**. Practice/testnet work is in sibling repo csyn-consensus-infra.

## Required First Reads (do this before any work)
1. Read this handoff file completely.
2. Read `TASKS.md` (full current state + CONSPLIT2 pointer).
3. Read `~/.ai-hybrid-activity.md` (latest Grok entries about the split and hygiene).
4. Read the CONSPLIT2 decision record: `/Users/pmorse/claude/cs/cloud-syndicate-platform/docs/everforge-readiness/decisions/2026-06-20-always-split-consensus-repos.md`
5. Read `README.md` and `ledger-workloads/validator-prod/README.md`.
6. Read `docs/dev-to-prod-readiness.md` (cross-repo version) for prod-specific lessons.

## Current Actual State (as of handoff)
- This repo owns **only prod/mainnet** root: `validator-prod` (standalone mainnet XRPL validator project under ledger/prod).
- No practice content (all dev roots are in csyn-consensus-infra).
- Latest commits include the split + .gitignore.
- Repo is on GitHub (csyn-portfolio/csyn-consensus-prod).
- Modules pinned by tag from sibling practice repo.
- WIF provider registered in substrate (dedicated for this repo).
- State: same `csyn-tf-state` + `ledger-workloads/validator-prod` prefix.
- Git hygiene: initial prod content pushed cleanly; untracked handoff + TASKS mods from prep.

## What Was Done (Grok side)
- CONSPLIT2 decision recorded (practice vs prod split).
- validator-prod root moved here; practice roots left in sibling.
- CI workflows adapted for prod-only.
- Docs (README, AGENTS, CLAUDE, TASKS), scope notes, and references updated.
- Substrate WIF + principalSet prepared for this repo.
- Git hygiene and pushes executed for the split.

## Next Steps for Prod/Mainnet Validator (execute in this session)
Run prod validator builds and validation in parallel with the testnet Claude session.

**Always set this first in this dir:**
```bash
export TF_CLI_CONFIG_FILE="$PWD/.ci/tofu-mirror.tofurc"
```

**Confirm secrets are set in this GitHub repo** (csyn-portfolio/csyn-consensus-prod):
- WIF_PROVIDER_PLAN
- WIF_PROVIDER_APPLY
- Module-reader GitHub App credentials

**Apply the validator:**
```bash
gh workflow run apply.yml -f configs="ledger-workloads/validator-prod"
```

**Verification (regulated surface – be thorough):**
- `tofu -chdir=ledger-workloads/validator-prod plan -lock=false`
- Validate HSM token, CMEK, Shielded VM, peer_private=1, observability, no public exposure.
- Cross-check against dev-to-prod-readiness.md prod rows and CONSVAL1.
- Confirm in GCP console + logs.
- Record evidence in TASKS.md.

**Substrate note:** If WIF not yet applied, only Pete-apply in cloud-syndicate-platform/wif (the binding for this repo is already there).

## Parallel Execution Note
This session (prod validator) runs independently and in parallel with the testnet/practice session in csyn-consensus-infra. Coordinate only on shared substrate items if the WIF apply is still pending.

## Success Criteria for This Session
- validator-prod fully applied and validated.
- All prod-specific controls and lessons implemented.
- TASKS.md updated.
- No practice/testnet references left in active prod code.
- Ready for any follow-on mainnet work.

## Reminders
- Full absolute paths.
- Update TASKS.md after every step.
- This is the regulated surface – extra care on evidence and posture.
- If switching back to Grok, append to the hybrid log.

Start with confirming secrets + the validator apply. Let's finish the mainnet validator today.
