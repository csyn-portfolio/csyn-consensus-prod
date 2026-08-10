# validator1 public landing (Option A1)

**Canonical ship path is OpenTofu in `cloud-syndicate-platform/shared/www/`** — not
`gcloud storage cp` from this repo.

| Item | Value |
|------|--------|
| TF root | `cloud-syndicate-platform/shared/www` (branch `feat/www-validator1-trust-card`) |
| Content in TF tree | `shared/www/validator1-content/index.html` + `.well-known/xrp-ledger.toml` |
| Resources | `google_storage_bucket_object.validator1_index` / `validator1_toml` |
| `/` rewrite | `gclb.tf` path_matcher `validator1` route_rules → `/index.html` |
| Project / bucket | `csyn-www-prod` · `gs://csyn-www-validator1-toml/` |

This file under `docs/public/validator1/` is the **design source** mirrored into the
www content dir for that PR. Prefer editing the www `validator1-content/` copy when
landing the apply, or keep both in sync.

## Verify (after apply)

```bash
curl -sS -o /dev/null -w "%{http_code}\n" https://validator1.cloudsyndicate.io/
curl -sS -o /dev/null -w "%{http_code}\n" https://validator1.cloudsyndicate.io/index.html
curl -sS -o /dev/null -w "%{http_code}\n" https://validator1.cloudsyndicate.io/.well-known/xrp-ledger.toml
# all expect 200; toml body must still contain the master key
```

## First apply note

Import the pre-existing toml object before apply if not in state:

```bash
tofu -chdir=shared/www import \
  'google_storage_bucket_object.validator1_toml' \
  'csyn-www-validator1-toml/.well-known/xrp-ledger.toml'
```
