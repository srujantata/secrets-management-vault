# Secrets Management with HashiCorp Vault on EKS

## Overview

This repository demonstrates a comprehensive secrets management solution using HashiCorp Vault installed on Amazon EKS via Helm, Kubernetes authentication method for pods, External Secrets Operator (ESO) for syncing Vault secrets to Kubernetes secrets, dynamic database credentials generation, secret rotation without pod restarts, and forwarding Vault audit logs to Loki. The architecture ensures zero static secrets by avoiding hardcoded credentials.

## Architecture Diagram

+-------------------+
|                   |
|   Jenkins Pod     |
|                   |
+--------^----------+
         |
         v
+--------^----------+
|                   |
|  External Secrets Operator (ESO) |
|                   |
+--------^----------+
         |
         v
+--------^----------+
|                   |
|      Kubernetes   |
|                   |
+--------^----------+
         |
         v
+--------^----------+
|                   |
|     HashiCorp Vault |
|                   |
+-------------------+

## Installation

### Prerequisites

- EKS cluster with at least one node
- Helm 3 installed
- kubectl configured to interact with your EKS cluster

### Install HashiCorp Vault via Helm

helm repo add hashicorp https://helm.releases.hashicorp.com
helm install vault hashicorp/vault --set server.dev.enabled=true

### Configure Kubernetes Authentication Method

1. Create a ServiceAccount for the Jenkins pod:

    ```yaml
    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: jenkins-sa
      namespace: default
    
2. Bind the ServiceAccount to a Role with permissions to access Vault secrets:

    ```yaml
    apiVersion: rbac.authorization.k8s.io/v1
    kind: Role
    metadata:
      name: vault-reader
      namespace: default
    rules:
    - apiGroups: [""]
      resources: ["secrets"]
      verbs: ["get", "list", "watch"]
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: RoleBinding
    metadata:
      name: vault-reader-binding
      namespace: default
    subjects:
    - kind: ServiceAccount
      name: jenkins-sa
      namespace: default
    roleRef:
      kind: Role
      name: vault-reader
      apiGroup: rbac.authorization.k8s.io
    
3. Deploy the Jenkins pod with the ServiceAccount:

    ```yaml
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: jenkins
      namespace: default
    spec:
      replicas: 1
      selector:
        matchLabels:
          app: jenkins
      template:
        metadata:
          labels:
            app: jenkins
        spec:
          serviceAccountName: jenkins-sa
          containers:
          - name: jenkins
            image: jenkins/jenkins:lts
            env:
            - name: VAULT_ADDR
              value: "http://vault.default.svc.cluster.local"
            volumeMounts:
            - name: vault-token
              mountPath: /var/run/secrets/kubernetes.io/serviceaccount/token
          volumes:
          - name: vault-token
            projected:
              sources:
              - serviceAccountToken: {}
    
### Install External Secrets Operator (ESO)

helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets --set installCRDs=true

### Configure ESO to Sync Vault Secrets

1. Create a SecretStore resource to configure the connection to Vault:

    ```yaml
    apiVersion: external-secrets.io/v1alpha1
    kind: SecretStore
    metadata:
      name: vault-secret-store
      namespace: default
    spec:
      provider:
        vault:
          server: "http://vault.default.svc.cluster.local"
          path: "secret/data/my-app"
          auth:
            jwt:
              role: "jenkins-role"
              serviceAccountRef:
                name: jenkins-sa
                namespace: default
    
2. Create a ExternalSecret resource to sync the secret:

    ```yaml
    apiVersion: external-secrets.io/v1alpha1
    kind: ExternalSecret
    metadata:
      name: my-app-secret
      namespace: default
    spec:
      refreshInterval: 1m
      secretStoreRef:
        name: vault-secret-store
        kind: SecretStore
      target:
        name: my-app-secret
        creationPolicy: Owner
      data:
      - secretKey: db-password
        remoteRef:
          key: my-app/db-password
    
### Configure Vault for Dynamic Database Credentials

1. Enable the database secrets engine:

    ```bash
    vault secrets enable database
    
2. Configure the database connection:

    ```bash
    vault write database/config/my-postgres-database \
      plugin_name=postgresql-database-plugin \
      allowed_roles=my-role \
      connection_url="postgresql://{{username}}:{{password}}@my-postgres-db.default.svc.cluster.local:5432/mydb?sslmode=disable" \
      username="root" \
      password="root-password"
    
3. Create a role for dynamic credentials:

    ```bash
    vault write database/roles/my-role \
      db_name=my-postgres-database \
      creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';" \
      default_ttl=1h \
      max_ttl=24h
    
### Configure Vault Audit Log Forwarding to Loki

1. Enable the audit log:

    ```bash
    vault audit enable file file_path=/var/log/vault/audit.log
    
2. Configure EFK stack for Loki, Elasticsearch, and Fluentd.

3. Create a Fluentd configuration to forward logs to Loki:

    ```yaml
    <source>
      @type tail
      path /var/log/vault/audit.log
      pos_file /var/log/fluentd/vault-audit.pos
      tag vault.audit
      read_from_head true
      <parse>
        @type none
      </parse>
    </source>

    <match vault.audit>
      @type loki
      url http://loki.default.svc.cluster.local:3100/loki/api/v1/push
      flush_interval 5s
      labels job=vault-audit
    </match>
    
## Example: Jenkins Pod Getting DB Password Dynamically

The Jenkins pod is configured to use the `my-app-secret` Kubernetes secret, which is synced from Vault. The Jenkins application can access the database password using the environment variable `DB_PASSWORD`.

apiVersion: apps/v1
kind: Deployment
metadata:
  name: jenkins
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: jenkins
  template:
    metadata:
      labels:
        app: jenkins
    spec:
      serviceAccountName: jenkins-sa
      containers:
      - name: jenkins
        image: jenkins/jenkins:lts
        env:
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: my-app-secret
              key: db-password

## Skills Demonstrated

- HashiCorp Vault installation and configuration on EKS via Helm
- Kubernetes authentication method for pods using ServiceAccount JWT
- External Secrets Operator for syncing Vault secrets to Kubernetes secrets
- Dynamic database credentials generation in Vault
- Secret rotation without pod restarts (ESO refresh interval)
- Vault audit log forwarding to Loki
- Zero static secrets by avoiding hardcoded credentials