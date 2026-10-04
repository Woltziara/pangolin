#!/bin/zsh
# Old watchdog would restart soak2 and splice a lost session. That is forbidden.
print -u2 -- "soak-watch retired. hdc-wait is observe-only and must not install."
exit 2
