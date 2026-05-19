#!/bin/bash

# Ensure required environment variables are set
if [ -z "$VAULT_ADDR" ] || [ -z "$VAULT_TOKEN" ]; then
  echo "Error: VAULT_ADDR and VAULT_TOKEN must be set as environment variables."
  exit 1
fi

# Enable Kubernetes auth method in Vault
vault auth enable kubernetes
echo "Kubernetes auth method enabled."

# Get the cluster CA certificate and API server URL from kubectl
CLUSTER_CA=$(kubectl config view --raw -o jsonpath="{.clusters[0].cluster.certificate-authority-data}" | base64 --decode)
API_SERVER_URL=$(kubectl config view --raw -o jsonpath="{.clusters[0].cluster.server}")

# Configure the Kubernetes auth method with cluster CA and API server URL
vault write auth/kubernetes/config \
  token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
  kubernetes_host="${API_SERVER_URL}" \
  kubernetes_ca_cert="$CLUSTER_CA"
echo "Kubernetes auth method configured with cluster CA and API server URL."

# Create roles and associate them with policies
vault write auth/kubernetes/role/jenkins-role \
  bound_service_account_names=jenkins \
  bound_service_account_namespaces=default \
  policies=jenkins-policy \
  ttl=1h max_ttl=24h
echo "Role jenkins-role created and associated with policy jenkins-policy."

vault write auth/kubernetes/role/sonarqube-role \
  bound_service_account_names=sonarqube \
  bound_service_account_namespaces=default \
  policies=sonarqube-policy \
  ttl=1h max_ttl=24h
echo "Role sonarqube-role created and associated with policy sonarqube-policy."

vault write auth/kubernetes/role/harbor-role \
  bound_service_account_names=harbor \
  bound_service_account_namespaces=default \
  policies=harbor-policy \
  ttl=1h max_ttl=24h
echo "Role harbor-role created and associated with policy harbor-policy."

echo "Vault Kubernetes auth method configured successfully."

This script enables the Kubernetes authentication method in Vault, configures it using the cluster CA and API server URL obtained from `kubectl`, creates roles for Jenkins, SonarQube, and Harbor, associates each role with its respective Vault policy, and sets a TTL of 1 hour with a maximum of 24 hours. It requires `VAULT_ADDR` and `VAULT_TOKEN` to be set as environment variables.