#!/bin/bash
set -e

echo ">>> [pg-standby] Waiting for pg-primary to accept connections..."
until pg_isready -h pg-primary -p 5432 -U sftpgo; do
  sleep 2
done

if [ ! -s "$PGDATA/PG_VERSION" ]; then
  echo ">>> [pg-standby] Data directory is empty. Pulling base backup from pg-primary..."
  rm -rf "$PGDATA"/*
  PGPASSWORD=replicatorpassword pg_basebackup -h pg-primary -D "$PGDATA" -U replicator -v -P -R -S standby_slot
  chmod 700 "$PGDATA"
  echo ">>> [pg-standby] Base backup completed and standby.signal configured."
fi

exec docker-entrypoint.sh postgres -c hot_standby=on
