#!/bin/bash
# Stand-in for ssh in the tests. rsync runs "<rsh> [options] [-l user] host rsync --server ..." (or user@host).
# This skips the options, maps the host to a jail directory (FAKE_SSH_MAP="host=dir,host=dir") and runs the REAL
# rrsync there with the flags setup-recv.sh puts in authorized_keys (-wo -no-del), as sshd would.
while [ $# -gt 0 ]; do case "$1" in -i|-o|-p|-l|-F|-c|-m) shift 2;; -*) shift;; *) break;; esac; done
host="${1#*@}"; shift
jail=""; IFS=, read -ra m <<<"$FAKE_SSH_MAP"; for kv in "${m[@]}"; do [ "${kv%%=*}" = "$host" ] && jail="${kv#*=}"; done
[ -n "$jail" ] || { echo "fake-ssh: no jail for '$host'" >&2; exit 255; }
SSH_ORIGINAL_COMMAND="$*" exec /usr/bin/rrsync -wo -no-del "$jail"
