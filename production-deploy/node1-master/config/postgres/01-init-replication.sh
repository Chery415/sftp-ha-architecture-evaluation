#!/bin/bash
set -e

# 從環境變數讀取 Replicator 密碼，若未提供則預設為 replicatorpassword
REP_PASS="${POSTGRES_REPLICATOR_PASSWORD:-replicatorpassword}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE USER replicator WITH REPLICATION ENCRYPTED PASSWORD '$REP_PASS';
    SELECT pg_create_physical_replication_slot('standby_slot');
EOSQL

# 允許來自所有網段 (或可限定 Node 2 IP) 的 replication 連線
echo "host replication replicator 0.0.0.0/0 scram-sha-256" >> "$PGDATA/pg_hba.conf"
echo "host replication replicator 0.0.0.0/0 md5" >> "$PGDATA/pg_hba.conf"
echo "host all all 0.0.0.0/0 scram-sha-256" >> "$PGDATA/pg_hba.conf"
echo "host all all 0.0.0.0/0 md5" >> "$PGDATA/pg_hba.conf"

pg_ctl reload -D "$PGDATA"
echo ">>> [Node 1] PostgreSQL Primary 複寫帳號 (replicator) 與 Slot (standby_slot) 建置完成。"
