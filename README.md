# Secrets Management with HashiCorp Vault on EKS

[![CI](https://github.com/srujantata/secrets-management-vault/actions/workflows/validate.yml/badge.svg)](https://github.com/srujantata/secrets-management-vault/actions)

Zero static secrets in Kubernetes. **HashiCorp Vault** on EKS issues dynamic credentials,
**External Secrets Operator (ESO)** syncs them as native K8s Secrets, and pods authenticate
via ServiceAccount JWT — no hardcoded passwords, no secret sprawl.

---

## Architecture

```
Pod (Jenkins / app)
  │  ServiceAccount JWT
  ▼
External Secrets Operator
  │  Vault Kubernetes auth
  ▼
HashiCorp Vault (EKS, HA with Raft)
  ├── kv/  ──────────────────────── static secrets (API keys, etc.)
  ├── database/  ────────────────── dynamic DB credentials (TTL-based)
  └── audit/  ───► Fluentd ──► Loki (audit trail for all secret access)
```

---

## Why This Architecture

| Problem | Solution |
|---------|---------|
| Static DB passwords in ConfigMaps | Vault dynamic credentials with 1h TTL |
| Secrets checked into Git | ESO pulls from Vault — nothing in Git |
| Credentials shared across services | Per-pod Vault role with least-privilege policy |
| No audit trail for secret access | Vault audit log forwarded to Loki |
| Secret rotation requires pod restart | ESO refresh interval auto-rotates without restart |

---

## Install Vault on EKS

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

helm install vault hashicorp/vault \
  --namespace vault --create-namespace \
  --set server.ha.enabled=true \
  --set server.ha.replicas=3 \
  --set server.ha.raft.enabled=true \
  --set injector.enabled=false   # using ESO instead of agent injector
```

Initialize and unseal (first deploy only):

```bash
kubectl exec -n vault vault-0 -- vault operator init \
  -key-shares=5 -key-threshold=3 \
  -format=json > vault-init.json   # store securely — not in Git

# Unseal each replica
for i in 0 1 2; do
  kubectl exec -n vault vault-$i -- vault operator unseal <unseal-key-1>
  kubectl exec -n vault vault-$i -- vault operator unseal <unseal-key-2>
  kubectl exec -n vault vault-$i -- vault operator unseal <unseal-key-3>
done
```

---

## Kubernetes Auth Method

Pods authenticate to Vault using their ServiceAccount JWT — no separate credentials needed.

```bash
# Enable Kubernetes auth
vault auth enable kubernetes

# Configure it (run inside the cluster or with kube API access)
vault write auth/kubernetes/config \
  kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443" \
  token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

# Create a policy for Jenkins
vault policy write jenkins-policy - <<EOF
path "secret/data/jenkins/*" {
  capabilities = ["read"]
}
path "database/creds/jenkins-role" {
  capabilities = ["read"]
}
EOF

# Bind the ServiceAccount to the policy
vault write auth/kubernetes/role/jenkins-role \
  bound_service_account_names=jenkins-sa \
  bound_service_account_namespaces=jenkins \
  policies=jenkins-policy \
  ttl=1h
```

---

## External Secrets Operator

ESO watches Vault and syncs secrets into Kubernetes on a configurable refresh interval.
Pods see a normal `Secret` — zero Vault SDK needed in application code.

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace \
  --set installCRDs=true
```

### SecretStore (cluster-scoped Vault connection)

```yaml
# k8s/vault-secret-store.yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: vault-backend
spec:
  provider:
    vault:
      server: "http://vault.vault.svc.cluster.local:8200"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "jenkins-role"
          serviceAccountRef:
            name: jenkins-sa
            namespace: jenkins
```

### ExternalSecret (sync a specific secret)

```yaml
# k8s/jenkins-db-secret.yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: jenkins-db-secret
  namespace: jenkins
spec:
  refreshInterval: 1m        # re-syncs every minute
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: jenkins-db-creds   # creates this K8s Secret
    creationPolicy: Owner
  data:
  - secretKey: db-password
    remoteRef:
      key: jenkins/database
      property: password
```

---

## Dynamic Database Credentials

Vault generates short-lived, unique credentials for each request — no shared password.

```bash
# Enable the database engine
vault secrets enable database

# Configure PostgreSQL connection
vault write database/config/app-postgres \
  plugin_name=postgresql-database-plugin \
  allowed_roles="jenkins-role" \
  connection_url="postgresql://{{username}}:{{password}}@postgres.default.svc:5432/appdb" \
  username="vault-admin" \
  password="${POSTGRES_ADMIN_PASSWORD}"

# Create a role — each request gets a new user with 1h TTL
vault write database/roles/jenkins-role \
  db_name=app-postgres \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE app_readonly;" \
  default_ttl=1h \
  max_ttl=24h
```

Vault returns something like:
```
username: v-jenkins-role-x8K2mNpQ-1716000000
password: A1B2-C3D4-E5F6-G7H8
lease_duration: 1h
```
After 1h, the credential expires and Postgres revokes it automatically.

---

## Vault Audit Logs → Loki

Every secret read, write, and auth event is recorded in the audit log.

```bash
# Enable file audit backend
vault audit enable file file_path=/vault/audit/vault-audit.log
```

```yaml
# fluentd/vault-audit-forward.yaml
<source>
  @type tail
  path /vault/audit/vault-audit.log
  pos_file /var/log/fluentd/vault-audit.pos
  tag vault.audit
  <parse>
    @type json
  </parse>
</source>

<match vault.audit>
  @type loki
  url http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push
  flush_interval 5s
  <label>
    job vault-audit
    cluster devops-poc
  </label>
</match>
```

Grafana query to find all secret reads in the last 1h:
```logql
{job="vault-audit"} | json | type="response" | path=~"secret/data/.*"
```

---

## Skills Demonstrated

- HashiCorp Vault HA deployment on EKS (Raft storage backend)
- Kubernetes auth method — pods authenticate via ServiceAccount JWT, no static tokens
- External Secrets Operator — Vault secrets synced as native K8s Secrets
- Dynamic database credentials — per-request, TTL-scoped, auto-expiring
- Secret rotation without pod restarts (ESO refresh interval)
- Vault audit log forwarding to Loki for compliance traceability
- Zero static secrets — nothing hardcoded in manifests or container images
