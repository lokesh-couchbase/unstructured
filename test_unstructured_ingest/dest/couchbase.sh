#!/usr/bin/env bash
set -e

SRC_PATH=$(dirname "$(realpath "$0")")
SCRIPT_DIR=$(dirname "$SRC_PATH")
cd "$SCRIPT_DIR"/.. || exit 1
OUTPUT_FOLDER_NAME=couchbase-dest
OUTPUT_DIR=$SCRIPT_DIR/structured-output/$OUTPUT_FOLDER_NAME
WORK_DIR=$SCRIPT_DIR/workdir/$OUTPUT_FOLDER_NAME
DOWNLOAD_DIR=$SCRIPT_DIR/download/$OUTPUT_FOLDER_NAME
DESTINATION_PATH=$SCRIPT_DIR/couchbase-dest
max_processes=${MAX_PROCESSES:=$(python3 -c "import os; print(os.cpu_count())")}
DESTINATION_CB_SCOPE="_default"
DESTINATION_CB_COLLECTION="_default"
CI=${CI:-"false"}

source scripts/couchbase-test-helpers/common/constants.env

# Check if all necessary environment variables are set
if [ -z "$CB_USERNAME" ] || [ -z "$CB_PASSWORD" ] || [ -z "$CB_CONN_STR" ] || [ -z "$CB_BUCKET" ];  then
  echo "Error: One or more environment variables are not set. Please set CB_CONN_STR, CB_USERNAME, CB_PASSWORD, and CB_BUCKET"
  exit 1
fi

# shellcheck disable=SC1091
source "$SCRIPT_DIR"/cleanup.sh

function cleanup() {

   # Remove docker container
  echo "Stopping Couchbase Docker container"
  docker-compose -f scripts/couchbase-test-helpers/common/docker-compose.yaml down --remove-orphans

  # Kill couchbase background process
  pgrep -f couchbase-dest | xargs kill
  cleanup_dir "$DESTINATION_PATH"
  cleanup_dir "$OUTPUT_DIR"
  cleanup_dir "$WORK_DIR"
  if [ "$CI" == "true" ]; then
    cleanup_dir "$DOWNLOAD_DIR"
  fi
}

trap cleanup EXIT

echo "Starting Couchbase Docker container and setup"

bash scripts/couchbase-test-helpers/common/setup_couchbase_cluster.sh
wait

python scripts/couchbase-test-helpers/destination_connector/ingest_destination_setup_cluster.py \
  --username "$CB_USERNAME" \
  --password "$CB_PASSWORD" \
  --connection_string "$CB_CONN_STR" \
  --bucket_name "$CB_BUCKET" \
  --scope_name "$DESTINATION_CB_SCOPE" \
  --collection_name "$DESTINATION_CB_COLLECTION" \
  --search_index_name "$CB_INDEX_NAME"
wait

PYTHONPATH=. ./unstructured/ingest/main.py \
  local \
  --num-processes "$max_processes" \
  --output-dir "$OUTPUT_DIR" \
  --strategy fast \
  --verbose \
  --input-path example-docs/book-war-and-peace-1p.txt \
  --work-dir "$WORK_DIR" \
  --chunking-strategy by_title \
  --chunk-max-characters 1500 \
  --chunk-multipage-sections \
  --embedding-provider "langchain-huggingface" \
  couchbase \
 --connection-string "$CB_CONN_STR" \
  --bucket "$CB_BUCKET" \
  --username "$CB_USERNAME" \
  --password "$CB_PASSWORD" \
  --scope "$DESTINATION_CB_SCOPE" \
  --collection "$DESTINATION_CB_COLLECTION" \
  --batch-size 80

python "$SCRIPT_DIR"/python/test-ingest-couchbase-output.py \
  --connection-string "$CB_CONN_STR" \
  --username "$CB_USERNAME" \
  --password "$CB_PASSWORD" \
  --bucket "$CB_BUCKET" \
  --scope "$DESTINATION_CB_SCOPE" \
  --collection "$DESTINATION_CB_COLLECTION" \
  check --expected-docs 3

stage_file=$(ls -1 "$WORK_DIR"/upload_stage | head -n 1)

python "$SCRIPT_DIR"/python/test-ingest-couchbase-output.py \
  --connection-string "$CB_CONN_STR" \
  --username "$CB_USERNAME" \
  --password "$CB_PASSWORD" \
  --bucket "$CB_BUCKET" \
  --scope "$DESTINATION_CB_SCOPE" \
  --collection "$DESTINATION_CB_COLLECTION" \
  check-vector \
  --output-json "$WORK_DIR"/upload_stage/"$stage_file"