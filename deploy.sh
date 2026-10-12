#!/usr/bin/env bash
# Steps 5-9: build the container, deploy to Cloud Run, wire up Firestore,
# Secret Manager, logging and monitoring.  Run from Google Cloud Shell:
#   bash deploy.sh YOUR_PROJECT_ID [region]
set -euo pipefail

PROJECT_ID="${1:-$(gcloud config get-value project 2>/dev/null)}"
REGION="${2:-asia-south1}"
SERVICE="failure-predictor"
RUNTIME_SA="predictor-run"
RUNTIME_SA_EMAIL="${RUNTIME_SA}@${PROJECT_ID}.iam.gserviceaccount.com"

[ -n "$PROJECT_ID" ] || { echo "Usage: bash deploy.sh PROJECT_ID [region]"; exit 1; }
[ -f model.joblib ] || { echo "model.joblib is missing. Upload it into this folder first."; exit 1; }
if grep -q REPLACE_SKLEARN requirements.txt; then
  echo "Set the scikit-learn version first, e.g.:"
  echo "  sed -i 's/REPLACE_SKLEARN/1.6.1/' requirements.txt"
  exit 1
fi

gcloud config set project "$PROJECT_ID"
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"

echo "== Enabling APIs"
gcloud services enable run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com \
  firestore.googleapis.com secretmanager.googleapis.com logging.googleapis.com monitoring.googleapis.com

echo "== Step 7: Firestore database"
gcloud firestore databases create --location="$REGION" --type=firestore-native 2>/dev/null \
  || echo "(Firestore database already exists)"

echo "== Runtime service account"
gcloud iam service-accounts create "$RUNTIME_SA" --display-name="Failure predictor runtime" 2>/dev/null \
  || echo "(service account already exists)"
for role in roles/datastore.user roles/logging.logWriter roles/monitoring.metricWriter; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${RUNTIME_SA_EMAIL}" --role="$role" --condition=None --quiet >/dev/null
done

echo "== Step 8: API key in Secret Manager"
if ! gcloud secrets describe api-key >/dev/null 2>&1; then
  openssl rand -hex 24 | gcloud secrets create api-key --data-file=- --replication-policy=automatic
fi
gcloud secrets add-iam-policy-binding api-key \
  --member="serviceAccount:${RUNTIME_SA_EMAIL}" --role="roles/secretmanager.secretAccessor" --quiet >/dev/null

echo "== Permissions for Cloud Build (needed for --source deploys)"
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role="roles/cloudbuild.builds.builder" --condition=None --quiet >/dev/null

echo "== Steps 5-6: build the Docker image and deploy to Cloud Run"
gcloud run deploy "$SERVICE" \
  --source . \
  --region "$REGION" \
  --service-account "$RUNTIME_SA_EMAIL" \
  --allow-unauthenticated \
  --memory 1Gi --cpu 1 \
  --min-instances 0 --max-instances 3 \
  --set-env-vars USE_FIRESTORE=1 \
  --set-secrets API_KEY=api-key:latest \
  --quiet

echo "== Step 9: log-based metric counting alerts"
gcloud logging metrics create predicted_failure_alerts \
  --description="Predictions that raised a failure alert" \
  --log-filter="resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"${SERVICE}\" AND jsonPayload.alert=true" \
  2>/dev/null || echo "(metric already exists)"

URL="$(gcloud run services describe "$SERVICE" --region "$REGION" --format='value(status.url)')"
echo
echo "=========================================================="
echo "DEPLOYED:  $URL"
echo "API docs:  $URL/docs"
echo "Get your API key with:"
echo "  gcloud secrets versions access latest --secret=api-key"
echo "Quick test:"
echo "  curl $URL/health"
echo "=========================================================="
