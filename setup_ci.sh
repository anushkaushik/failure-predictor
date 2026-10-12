#!/usr/bin/env bash
# Step 10: create the service account GitHub Actions uses to deploy.
#   bash setup_ci.sh YOUR_PROJECT_ID
set -euo pipefail
PROJECT_ID="${1:-$(gcloud config get-value project 2>/dev/null)}"
SA="github-deployer"
SA_EMAIL="${SA}@${PROJECT_ID}.iam.gserviceaccount.com"
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"

gcloud iam service-accounts create "$SA" --display-name="GitHub Actions deployer" 2>/dev/null \
  || echo "(service account already exists)"

for role in roles/run.admin roles/cloudbuild.builds.editor roles/storage.admin \
            roles/artifactregistry.writer roles/iam.serviceAccountUser \
            roles/serviceusage.serviceUsageConsumer; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" --role="$role" --condition=None --quiet >/dev/null
done

gcloud iam service-accounts keys create key.json --iam-account="$SA_EMAIL"
echo
echo "Done. Now:"
echo "1) Open key.json (Cloud Shell: click 'Open Editor'), copy ALL of its contents."
echo "2) GitHub repo -> Settings -> Secrets and variables -> Actions -> New repository secret"
echo "   Name: GCP_SA_KEY    Value: (paste the contents)"
echo "3) Delete the key file:  rm key.json"
