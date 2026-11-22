#!/bin/bash
#
# CI for wt-launchd-run, drafted 2026-10-26 by dev-toolchain's ci/gen_ci_sh.py
# from ci.yml.
# Review it, then make the workflow's one step `bash tests/ci.sh`; from then
# on edit this file, not the workflow.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# job: test (ci.yml)
# runs-on: macos-latest

# step: actions/checkout@v5
# uses: actions/checkout@v5 (nothing needed: the repo is already checked out)

# step: Install shellcheck and shfmt
command -v shellcheck || brew install shellcheck
command -v shfmt || brew install shfmt

# step: Format (shfmt, Google shell guide flags)
# Every tracked .sh, so a new file cannot be forgotten here: stage it first.
git ls-files '*.sh' | xargs shfmt -d -i 2 -ci -bn

# step: Shellcheck
git ls-files '*.sh' | xargs shellcheck

# step: Tests (bash on PATH)
bash tests/version.sh
bash tests/run.sh
bash tests/lr_stop_select_signals.sh
bash tests/lr_env_s3_boundary.sh
bash tests/lr_env_select_env.sh
bash tests/lr_count_select_edges.sh
bash tests/lr_docs_verify_rotation.sh
bash tests/lr_docs_select_boundary.sh

# step: Tests (/bin/bash 3.2, as launchd runs it)
/bin/bash tests/version.sh
/bin/bash tests/run.sh
/bin/bash tests/lr_stop_select_signals.sh
/bin/bash tests/lr_env_s3_boundary.sh
/bin/bash tests/lr_env_select_env.sh
/bin/bash tests/lr_count_select_edges.sh
/bin/bash tests/lr_docs_verify_rotation.sh
/bin/bash tests/lr_docs_select_boundary.sh
