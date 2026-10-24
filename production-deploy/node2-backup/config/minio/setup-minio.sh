#!/bin/sh
set -e

LOCAL_ENDPOINT="http://127.0.0.1:9000"
REMOTE_HOST="${REMOTE_MINIO_HOST:-127.0.0.1}"
REMOTE_PORT="${REMOTE_MINIO_PORT:-9000}"
REMOTE_ENDPOINT="http://${REMOTE_HOST}:${REMOTE_PORT}"
BUCKET_NAME="${MINIO_BUCKET:-sftp-data}"
ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"
ROOT_PASS="${MINIO_ROOT_PASSWORD:-minioadminpassword}"

echo ">>> [MinIO Node 2] 正在等待本地 MinIO 服務上線..."
until mc alias set local_mno "$LOCAL_ENDPOINT" "$ROOT_USER" "$ROOT_PASS" > /dev/null 2>&1; do
  sleep 2
done

echo ">>> [MinIO Node 2] 本地服務在線，確保儲存桶 '$BUCKET_NAME' 存在並啟用版本控制..."
mc mb --ignore-existing "local_mno/$BUCKET_NAME"
mc version enable "local_mno/$BUCKET_NAME"

echo ">>> [MinIO Node 2] 檢查對向節點 (Node 1: $REMOTE_ENDPOINT) 是否就緒..."
if mc alias set remote_mno "$REMOTE_ENDPOINT" "$ROOT_USER" "$ROOT_PASS" > /dev/null 2>&1; then
  echo ">>> [MinIO Node 2] 偵測到 Node 1 已就緒，建立雙向 S3 儲存桶複寫規則..."
  mc mb --ignore-existing "remote_mno/$BUCKET_NAME" || true
  mc version enable "remote_mno/$BUCKET_NAME" || true
  mc replicate add "local_mno/$BUCKET_NAME" --remote-bucket "http://${ROOT_USER}:${ROOT_PASS}@${REMOTE_HOST}:${REMOTE_PORT}/${BUCKET_NAME}" || true
  echo ">>> [MinIO Node 2] 複寫規則已配置完成。"
else
  echo ">>> [MinIO Node 2] Node 1 尚未連通，本地初始化完成。"
fi
