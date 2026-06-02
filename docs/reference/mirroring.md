# Mirroring And Consumer Baseline

This template is intentionally split into a shared repo-quality baseline, the
manifest-driven build tooling, and the starter application that downstream
repositories replace.

## Required Shared Baseline

Derived image repositories should keep these files close to the template unless
they have a documented reason to diverge:

- `.github/PULL_REQUEST_TEMPLATE.md`
- `.github/renovate.json5`
- `.markdownlint-cli2.jsonc`
- `contracts/image-manifest.schema.json`
- `tests/runtime-hardening.sh`
- `tools/check_image_manifest.py`
- `tools/generate_build_args.py`
- `tools/build_image.sh`
- `tools/verify_app_shas.py`
- `tools/verify.py`
- `docs/reference/image-manifest.md`
- `docs/reference/runtime-hardening.md`
- `docs/reference/supply-chain-evidence.md`

## Starter Layer

These files are meant to be edited immediately in downstream repositories:

- `README.md`
- `examples/image-manifest.json` (rename and move into your repository as the
  canonical manifest path you want to ship under)
- `app/` (replace with the real application source or remove if the artifact
  is fetched from a vendor release)
- `tools/build_app.sh` (rewrite to build or fetch the real artifact; keep the
  output filenames and locations the manifest expects)
- `containers/Dockerfile`
- `docs/explanation/*`
- `docs/how-to/*`
- `docs/decision-records/repo/*`

## New Image Repository Checklist

1. Rewrite the README for the real application image.
2. Replace `app/` and `tools/build_app.sh` with whatever produces the real
   `dist/app-{amd64,arm64}` artifacts (or update the manifest's
   `application.artifacts[].path` values to wherever your build deposits them).
3. Replace `examples/image-manifest.json` with real pins for the new
   application.
4. Update the Dockerfile only if the application stage needs a different
   verification surface than per-arch SHA256.
5. Add a release workflow that publishes, signs, and attests the image.
6. Run `python tools/verify.py ci` and `make image` locally.
7. Confirm CI's `image build + hardening` job passes for the new image.
