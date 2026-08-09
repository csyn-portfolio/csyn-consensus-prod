# validator1 public landing (Option A1)

**Production artifact** for `https://validator1.cloudsyndicate.io/`.

## Host

| Item | Value |
|------|--------|
| Project | `csyn-www-prod` |
| Bucket | `gs://csyn-www-validator1-toml/` |
| Object | `index.html` |
| Also present | `.well-known/xrp-ledger.toml` (do not overwrite) |

## Deploy (after approval)

```bash
gcloud storage cp docs/public/validator1/index.html \
  gs://csyn-www-validator1-toml/index.html \
  --content-type=text/html \
  --cache-control="public, max-age=300"
```

## Verify

```bash
curl -sS -o /dev/null -w "%{http_code}\n" https://validator1.cloudsyndicate.io/index.html   # expect 200
curl -sS -o /dev/null -w "%{http_code}\n" https://validator1.cloudsyndicate.io/             # expect 200 after URL rewrite if needed
curl -sS -o /dev/null -w "%{http_code}\n" https://validator1.cloudsyndicate.io/.well-known/xrp-ledger.toml  # expect 200
```

If `/` is still 403/404 after `index.html` is 200, pathMatcher `validator1` on `csyn-www-url-map` needs `/` → `/index.html` rewrite (www TF home, not this repo).
