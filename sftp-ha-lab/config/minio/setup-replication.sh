#!/bin/sh
set -e

echo ">>> [MinIO Setup] Waiting for MinIO Node A and Node B..."
until mc alias set mna http://minio-a:9000 minioadmin minioadminpassword; do
  echo ">>> Waiting for minio-a..."
  sleep 2
done

until mc alias set mnb http://minio-b:9000 minioadmin minioadminpassword; do
  echo ">>> Waiting for minio-b..."
  sleep 2
done

echo ">>> [MinIO Setup] Both MinIO nodes online. Creating bucket 'sftp-data'..."
mc mb --ignore-existing mna/sftp-data
mc mb --ignore-existing mnb/sftp-data

echo ">>> [MinIO Setup] Enabling bucket versioning (required for 2-way replication)..."
mc version enable mna/sftp-data
mc version enable mnb/sftp-data

echo ">>> [MinIO Setup] Configuring Active-Active 2-Way Site/Bucket Replication..."
mc replicate add mna/sftp-data --remote-bucket "http://minioadmin:minioadminpassword@minio-b:9000/sftp-data" || true
mc replicate add mnb/sftp-data --remote-bucket "http://minioadmin:minioadminpassword@minio-a:9000/sftp-data" || true

echo ">>> [MinIO Setup] Replication rules applied successfully."
mc replicate ls mna/sftp-data || true
mc replicate ls mnb/sftp-data || true
echo ">>> [MinIO Setup] Initialization complete."
exit 0
