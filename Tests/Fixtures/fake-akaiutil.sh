#!/bin/sh

printf '/disk0/A/VOLUME 001 > '
while IFS= read -r command; do
    case "$command" in
        q|quit|exit)
            exit 0
            ;;
        df)
            printf '\n   0   FLL     1   0x0400   0x0320     0.8     0x031c     0.8   99.5\n/disk0/A/VOLUME 001 > '
            ;;
        dir)
            printf '\nfnr  fname               size/B  startblk  uncompr\n  1  TEST.S                1024   0x0004     -\ntotal: 1 file(s) (max. 64), 1024 bytes\n/disk0/A/VOLUME 001 > '
            ;;
        *)
            printf '\nOK: %s\n/disk0/A/VOLUME 001 > ' "$command"
            ;;
    esac
done
