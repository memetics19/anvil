#!/usr/bin/env bash
# The media library as a home device sees it: NFS exports exactly the movies and TV folders,
# and SMB offers exactly the Movies and TV shares. Nothing else, so downloads stay private.
source "$(dirname "$0")/lib.sh"

h=$(site 's["hosts"]["ragnarok"].get("home_ip", "")')
[ -n "$h" ] || skip "site.hosts.ragnarok.home_ip is not set (no media for the home)"

if command -v showmount >/dev/null; then
  exports=$(showmount -e "$h" 2>/dev/null | awk 'NR > 1 {print $1}' | sort | tr '\n' ' ')
  if [ "$exports" = "/home/ubuntu/media/movies /home/ubuntu/media/tv " ]; then
    ok "NFS exports exactly movies and tv"
  else
    bad_ "NFS exports exactly movies and tv (got: ${exports:-nothing})"
  fi
else
  echo "skip NFS: showmount missing"
fi

if command -v smbutil >/dev/null; then
  shares=$(smbutil view -G "//$h" 2>/dev/null | awk '$2 == "Disk" {print $1}' | sort | tr '\n' ' ')
elif command -v smbclient >/dev/null; then
  shares=$(smbclient -N -g -L "//$h" 2>/dev/null | awk -F'|' '$1 == "Disk" {print $2}' | sort | tr '\n' ' ')
else
  shares=skip
fi
case "$shares" in
  skip) echo "skip SMB: neither smbutil nor smbclient" ;;
  "Movies TV ") ok "SMB offers exactly Movies and TV" ;;
  *) bad_ "SMB offers exactly Movies and TV (got: ${shares:-nothing})" ;;
esac
done_ media
