#!/bin/zsh
# soak2 produced false CANARY_OK after 20:17:25 HDC loss.
# Original log is frozen. This name must not continue that soak.
print -u2 -- "soak2 is OBSERVABILITY_LOST/INCONCLUSIVE (breakpoint 2026-09-03 20:17:25 R32)."
print -u2 -- "Refusing to resume. Start a NEW soak with scripts/stage1-soak-failclosed.sh after unique X5 is visible."
exit 2
