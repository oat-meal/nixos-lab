# Test-only key material

Every key in this directory exists ONLY for the VM tests in `tests/` and is used by no real
host. They are committed so the tests are reproducible and CI can run them. Generated
2026-10-10 with `wg genkey` / `ssh-keygen -t ed25519`. gitleaks is told to skip this
directory in `.gitleaks.toml` for exactly that reason; nothing outside it is exempt.
