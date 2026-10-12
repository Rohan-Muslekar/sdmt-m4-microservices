#!/usr/bin/env bash
# setup-ms4.sh - provision, deploy and tear down Milestone 4.
#
# Reference runbook. Run one subcommand at a time, from the GCP Cloud Shell or
# any machine with gcloud, kubectl and envsubst. Every gcloud call is scoped to
# the sdt-ms3 config so it never touches your default account.
#
#   Setup
#   ./scripts/setup-ms4.sh apis           # enable the APIs
#   ./scripts/setup-ms4.sh sa             # service account and its roles, no key
#   ./scripts/setup-ms4.sh deps           # local virtualenv + check ADC
#   ./scripts/setup-ms4.sh repo           # Artifact Registry docker repo
#   ./scripts/setup-ms4.sh cluster        # GKE cluster, 3 nodes
#
#   Part A, the voting system
#   ./scripts/setup-ms4.sh topic          # topic election + default subscription
#   ./scripts/setup-ms4.sh logger         # build, push and deploy logger + Redis
#   ./scripts/setup-ms4.sh recorder       # build, push and deploy recorder + PostgreSQL
#   ./scripts/setup-ms4.sh machine        # run a voting machine locally
#   ./scripts/setup-ms4.sh votes          # read the votes table out of PostgreSQL
#
#   Part B, the design
#   ./scripts/setup-ms4.sh design-topic   # topic meter, BigQuery table, BigQuery subscription
#   ./scripts/setup-ms4.sh design-build   # build and push both design images
#   ./scripts/setup-ms4.sh design-deploy  # deploy FilterReading and ConvertReading
#   ./scripts/setup-ms4.sh design-run     # publish Labels.csv from the local meter
#   ./scripts/setup-ms4.sh design-check   # count and show the rows that landed in BigQuery
#
#   Housekeeping
#   ./scripts/setup-ms4.sh status         # pods, subscriptions, row counts
#   ./scripts/setup-ms4.sh selftest       # the transforms, with no cloud
#   ./scripts/setup-ms4.sh reset          # clear the demo data for a retake
#   ./scripts/setup-ms4.sh teardown       # delete everything that bills
#
set -euo pipefail

export CLOUDSDK_ACTIVE_CONFIG_NAME="${CLOUDSDK_ACTIVE_CONFIG_NAME:-sdt-ms3}"
PROJECT="${PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
PROJECT="${PROJECT:-project-177cbd41-037f-441e-80d}"
REGION="${REGION:-northamerica-northeast2}"
ZONE="${ZONE:-${REGION}-a}"
CLUSTER="${CLUSTER:-sofe4630u}"
AR_REPO="${AR_REPO:-sofe4630u}"
REPO="${REPO:-${REGION}-docker.pkg.dev/${PROJECT}/${AR_REPO}}"

SA="${SA:-ms4-pubsub}"
SA_EMAIL="${SA}@${PROJECT}.iam.gserviceaccount.com"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# The local scripts need google-cloud-pubsub. This machine has an externally
# managed Python, so the dependency lives in a virtualenv next to the repo.
PY="$REPO_ROOT/.venv/bin/python"
[ -x "$PY" ] || PY="python3"

# This machine's shell profile exports GOOGLE_APPLICATION_CREDENTIALS for an
# unrelated project, and the file it names is not here. Left set, every Google
# client library in this repo fails on it before it ever reaches Application
# Default Credentials. Drop it unless it actually resolves.
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ] && [ ! -f "$GOOGLE_APPLICATION_CREDENTIALS" ]; then
  echo "GOOGLE_APPLICATION_CREDENTIALS points at a missing file, ignoring it:"
  echo "  $GOOGLE_APPLICATION_CREDENTIALS"
  unset GOOGLE_APPLICATION_CREDENTIALS
fi

LOGGER_IMAGE="$REPO/logger"
RECORDER_IMAGE="$REPO/recorder"
POSTGRES_IMAGE="$REPO/postgres:election"
FILTER_IMAGE="$REPO/filter-reading"
CONVERT_IMAGE="$REPO/convert-reading"

BQ_DATASET="${BQ_DATASET:-SmartMeter}"
BQ_TABLE="${BQ_TABLE:-Readings}"

echo "project=$PROJECT region=$REGION zone=$ZONE cluster=$CLUSTER config=$CLOUDSDK_ACTIVE_CONFIG_NAME"

# This project enforces constraints/iam.disableServiceAccountKeyCreation, so
# there is no service account key anywhere. In the cluster the pods read the
# metadata server and come up as the node pool's service account. Locally the
# scripts use Application Default Credentials. Both paths need no file.
require_adc() {
  if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
    echo "No Application Default Credentials. Run: gcloud auth application-default login" >&2
    exit 1
  fi
}

case "${1:-}" in
apis)
  gcloud services enable pubsub.googleapis.com artifactregistry.googleapis.com \
    cloudbuild.googleapis.com container.googleapis.com bigquery.googleapis.com \
    --project "$PROJECT"
  ;;

sa)
  gcloud iam service-accounts create "$SA" --project "$PROJECT" \
    --display-name "Milestone 4 Pub/Sub service account" || true
  # Pub/Sub Admin, not Editor: the services create their own filtered
  # subscriptions on first start, which Editor is not allowed to do.
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member "serviceAccount:$SA_EMAIL" --role roles/pubsub.admin
  # Roles the same account needs to also act as the GKE node service account:
  # pull images, write logs and metrics, and write to BigQuery.
  for role in roles/artifactregistry.reader roles/logging.logWriter \
              roles/monitoring.metricWriter roles/monitoring.viewer \
              roles/stackdriver.resourceMetadata.writer roles/bigquery.dataEditor; do
    gcloud projects add-iam-policy-binding "$PROJECT" \
      --member "serviceAccount:$SA_EMAIL" --role "$role" --quiet >/dev/null
  done
  echo "service account: $SA_EMAIL"
  echo "No key is created. This project enforces"
  echo "constraints/iam.disableServiceAccountKeyCreation, so the cluster runs its"
  echo "nodes AS this account instead and the pods read the metadata server."
  ;;

deps)
  # google-cloud-pubsub for the two scripts that run on this machine. The system
  # Python is externally managed, so it goes in a virtualenv.
  python3 -m venv "$REPO_ROOT/.venv"
  "$REPO_ROOT/.venv/bin/pip" install --quiet --upgrade pip
  "$REPO_ROOT/.venv/bin/pip" install --quiet google-cloud-pubsub
  "$REPO_ROOT/.venv/bin/python" -c "import google.cloud.pubsub_v1; print('google-cloud-pubsub ready')"
  gcloud auth application-default print-access-token >/dev/null 2>&1 \
    && echo "Application Default Credentials ready" \
    || echo "Run: gcloud auth application-default login"
  ;;

repo)
  gcloud artifacts repositories create "$AR_REPO" --project "$PROJECT" \
    --repository-format docker --location "$REGION" \
    --description "SOFE4630U milestone 4 images" || true
  gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet
  echo "REPO=$REPO"
  ;;

cluster)
  # --service-account plus the cloud-platform scope is what replaces the key
  # file: every pod on these nodes authenticates as $SA_EMAIL via the metadata
  # server. Default GKE scopes do not include Pub/Sub, hence the explicit one.
  gcloud container clusters create "$CLUSTER" --project "$PROJECT" \
    --zone "$ZONE" --num-nodes 3 --machine-type e2-medium \
    --service-account "$SA_EMAIL" \
    --scopes https://www.googleapis.com/auth/cloud-platform
  gcloud container clusters get-credentials "$CLUSTER" \
    --zone "$ZONE" --project "$PROJECT"
  kubectl get nodes
  ;;

# ---------------------------------------------------------------- Part A ----

topic)
  gcloud pubsub topics create election --project "$PROJECT" || true
  gcloud pubsub subscriptions create election-sub \
    --topic election --project "$PROJECT" || true
  echo "The three filtered subscriptions are created by the services and the"
  echo "voting machine themselves on first start, not here."
  ;;

logger)
  cd "$REPO_ROOT/voting_logger"
  gcloud builds submit -t "$LOGGER_IMAGE" --project "$PROJECT"
  PROJECT="$PROJECT" LOGGER_IMAGE="$LOGGER_IMAGE" \
    envsubst '$PROJECT $LOGGER_IMAGE' < logger.yaml | kubectl apply -f -
  kubectl get pods
  ;;

recorder)
  cd "$REPO_ROOT/voting_record/postgres"
  gcloud builds submit -t "$POSTGRES_IMAGE" --project "$PROJECT"
  cd "$REPO_ROOT/voting_record"
  gcloud builds submit -t "$RECORDER_IMAGE" --project "$PROJECT"
  PROJECT="$PROJECT" RECORDER_IMAGE="$RECORDER_IMAGE" POSTGRES_IMAGE="$POSTGRES_IMAGE" \
    envsubst '$PROJECT $RECORDER_IMAGE $POSTGRES_IMAGE' < recorder.yaml | kubectl apply -f -
  kubectl get pods
  ;;

machine)
  require_adc
  cd "$REPO_ROOT/voting_machine"
  GCP_PROJECT="$PROJECT" "$PY" main.py
  ;;

votes)
  POD="$(kubectl get pods -l app=postgres -o jsonpath='{.items[0].metadata.name}')"
  kubectl exec "$POD" -- psql -U admin -d election \
    -c 'SELECT electionID, machineID, voting, count(*) OVER () AS total FROM votes ORDER BY id DESC LIMIT 20;'
  ;;

# ---------------------------------------------------------------- Part B ----

design-topic)
  gcloud pubsub topics create meter --project "$PROJECT" || true

  bq --project_id "$PROJECT" --location "$REGION" mk \
    --dataset "${PROJECT}:${BQ_DATASET}" || true
  bq --project_id "$PROJECT" mk --table \
    "${PROJECT}:${BQ_DATASET}.${BQ_TABLE}" \
    time:FLOAT,profileName:STRING,temperature:FLOAT,humidity:FLOAT,pressure:FLOAT || true

  # The BigQuery subscription is written to by the Pub/Sub service agent, not by
  # us, so that agent is the account that needs the BigQuery roles. Skipping
  # this is the usual reason a BigQuery subscription silently stays empty.
  PROJECT_NUMBER="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')"
  PUBSUB_AGENT="service-${PROJECT_NUMBER}@gcp-sa-pubsub.iam.gserviceaccount.com"
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member "serviceAccount:$PUBSUB_AGENT" --role roles/bigquery.dataEditor
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member "serviceAccount:$PUBSUB_AGENT" --role roles/bigquery.metadataViewer

  # --use-table-schema maps the JSON keys of the message onto the table columns.
  # The filter means only the finished, converted readings are ever written.
  gcloud pubsub subscriptions create meter-store-bq-sub \
    --topic meter --project "$PROJECT" \
    --bigquery-table "${PROJECT}:${BQ_DATASET}.${BQ_TABLE}" \
    --use-table-schema \
    --message-filter 'attributes.function="store"' || true

  gcloud pubsub subscriptions describe meter-store-bq-sub --project "$PROJECT"
  ;;

design-build)
  cd "$REPO_ROOT/design/filterReading"
  gcloud builds submit -t "$FILTER_IMAGE" --project "$PROJECT"
  cd "$REPO_ROOT/design/convertReading"
  gcloud builds submit -t "$CONVERT_IMAGE" --project "$PROJECT"
  ;;

design-deploy)
  cd "$REPO_ROOT/design"
  PROJECT="$PROJECT" FILTER_IMAGE="$FILTER_IMAGE" CONVERT_IMAGE="$CONVERT_IMAGE" \
    envsubst '$PROJECT $FILTER_IMAGE $CONVERT_IMAGE' < design.yaml | kubectl apply -f -
  kubectl get pods -l 'app in (filter-reading,convert-reading)'
  echo
  echo "Give the pods a few seconds, then watch a replica create its subscription:"
  echo "  kubectl logs -l app=filter-reading --tail 20"
  ;;

design-run)
  require_adc
  cd "$REPO_ROOT"
  GCP_PROJECT="$PROJECT" "$PY" design/producer.py
  ;;

design-check)
  bq --project_id "$PROJECT" query --use_legacy_sql=false \
    "SELECT count(*) AS rows_landed FROM \`${PROJECT}.${BQ_DATASET}.${BQ_TABLE}\`"
  bq --project_id "$PROJECT" query --use_legacy_sql=false \
    "SELECT profileName, round(temperature,2) AS temp_F, round(pressure,3) AS press_psi, round(humidity,2) AS humidity
     FROM \`${PROJECT}.${BQ_DATASET}.${BQ_TABLE}\` ORDER BY time DESC LIMIT 10"
  ;;

# ---------------------------------------------------------- Housekeeping ----

selftest)
  cd "$REPO_ROOT"
  python3 design/filterReading/filterReading.py --selftest
  python3 design/convertReading/convertReading.py --selftest
  python3 design/producer.py --selftest
  ;;

status)
  kubectl get pods || true
  gcloud pubsub subscriptions list --project "$PROJECT" \
    --format 'table(name.basename(), filter, bigqueryConfig.table)'
  bq --project_id "$PROJECT" query --use_legacy_sql=false \
    "SELECT count(*) AS readings_in_bigquery FROM \`${PROJECT}.${BQ_DATASET}.${BQ_TABLE}\`" || true
  ;;

reset)
  # Put the demo data back to empty so a retake shows 0 rows becoming 78 and an
  # empty votes table filling up. Leaves the cluster and the topics alone.
  bq --project_id "$PROJECT" query --use_legacy_sql=false \
    "TRUNCATE TABLE \`${PROJECT}.${BQ_DATASET}.${BQ_TABLE}\`" || true
  POD="$(kubectl get pods -l app=postgres -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -n "$POD" ] && kubectl exec "$POD" -- psql -U admin -d election -c 'TRUNCATE votes;' || true
  RPOD="$(kubectl get pods -l app=redis -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -n "$RPOD" ] && kubectl exec "$RPOD" -- redis-cli -a election FLUSHALL || true
  echo "Demo data cleared. BigQuery 0 rows, votes empty, Redis flushed."
  ;;

teardown)
  # The cluster is the only thing here that bills by the minute. Delete it first.
  gcloud container clusters delete "$CLUSTER" --zone "$ZONE" \
    --project "$PROJECT" --quiet || true
  for s in election-sub election-submit-sub election-record-sub \
           meter-filter-sub meter-convert-sub meter-store-bq-sub; do
    gcloud pubsub subscriptions delete "$s" --project "$PROJECT" --quiet || true
  done
  # The voting machines name their subscriptions after their machine ID, so
  # remove whatever is left over rather than guessing the IDs that were used.
  for s in $(gcloud pubsub subscriptions list --project "$PROJECT" \
             --format 'value(name.basename())' | grep '^election-result-' || true); do
    gcloud pubsub subscriptions delete "$s" --project "$PROJECT" --quiet || true
  done
  for t in election meter; do
    gcloud pubsub topics delete "$t" --project "$PROJECT" --quiet || true
  done
  bq --project_id "$PROJECT" rm -r -f --dataset "${PROJECT}:${BQ_DATASET}" || true
  gcloud artifacts repositories delete "$AR_REPO" --location "$REGION" \
    --project "$PROJECT" --quiet || true
  echo "Torn down. Check the billing page to confirm nothing is still running."
  ;;

*)
  grep '^#   ' "$0" | sed 's/^#   //'
  ;;
esac
