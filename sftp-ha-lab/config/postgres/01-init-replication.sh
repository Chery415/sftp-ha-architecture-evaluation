#!/bin/bash
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE USER replicator WITH REPLICATION ENCRYPTED PASSWORD 'replicatorpassword';
    SELECT pg_create_physical_replication_slot('standby_slot');
EOSQL

echo "host replication replicator 0.0.0.0/0 md5" >> "$PGDATA/pg_hba.conf"
pg_ctl reload -D "$PGDATA"
echo ">>> PostgreSQL Primary Replication User & Slot configured successfully."
