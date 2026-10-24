#!/bin/bash
set -e

PRIMARY_HOST="${POSTGRES_PRIMARY_HOST:-127.0.0.1}"
PRIMARY_PORT="${POSTGRES_PRIMARY_PORT:-5432}"
REP_USER="replicator"
REP_PASS="${POSTGRES_REPLICATOR_PASSWORD:-replicatorpassword}"

echo ">>> [Node 2 pg-standby] 等待 Node 1 ($PRIMARY_HOST:$PRIMARY_PORT) 主要資料庫就緒..."
until pg_isready -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$POSTGRES_USER"; do
  echo ">>> [Node 2 pg-standby] 等待 Node 1 PostgreSQL 響應中..."
  sleep 3
done

if [ ! -s "$PGDATA/PG_VERSION" ]; then
  echo ">>> [Node 2 pg-standby] 資料庫目錄為空，正在從 Node 1 進行初次 pg_basebackup 全庫拉取..."
  rm -rf "$PGDATA"/*
  PGPASSWORD="$REP_PASS" pg_basebackup -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -D "$PGDATA" -U "$REP_USER" -v -P -R -S standby_slot
  chmod 700 "$PGDATA"
  echo ">>> [Node 2 pg-standby] 基礎備份拉取完成，已自動產生 standby.signal 進入唯讀串流同步模式。"
fi

exec docker-entrypoint.sh postgres -c hot_standby=on
