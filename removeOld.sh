#!/usr/bin/env bash

BACKUP_RETAIN_DURATION=10
fullPath=""
find $fullPath -mtime +"${BACKUP_RETAIN_DURATION}" -exec rm -rfv {} \;