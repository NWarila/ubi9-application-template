## Summary

<!-- 1-3 bullets describing what this PR changes and why. -->

## Risk

<!-- What could break? What did you test? Reference image/runtime impact when applicable. -->

## Test plan

- [ ] `python tools/verify.py ci` passes locally or in PR
- [ ] If touching `containers/Dockerfile`: manifest pins and runtime assertions were reviewed
- [ ] If touching release/build behavior: SBOM, provenance, signing, and attestation evidence are updated
- [ ] Documentation reflects the change
