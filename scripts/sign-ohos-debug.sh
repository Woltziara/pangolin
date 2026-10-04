#!/bin/zsh
print -u2 -- "scripts/sign-ohos-debug.sh retired."
print -u2 -- "Canonical HAP/manifest can only be published by scripts/r1-build.sh under package.lock."
print -u2 -- "The OpenHarmony debug profile path is rejected."
exit 2
