#!/bin/bash -x

cd ~/develop-apis-apigee/rest-backend
source config.sh

gcloud services enable geocoding-backend.googleapis.com

API_KEY=$(gcloud alpha services api-keys create --project=${GOOGLE_CLOUD_PROJECT} --display-name="Geocoding API key for Apigee" --api-target=service=geocoding_backend --format "value(response.keyString)")
echo "export API_KEY=${API_KEY}" >> ~/.bashrc
echo "API_KEY=${API_KEY}"