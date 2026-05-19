# Allow reading of secrets under the jenkins namespace
path "secret/data/jenkins/*" {
  capabilities = ["read"]
}

# Allow reading of database credentials for the jenkins-db-role
path "database/creds/jenkins-db-role" {
  capabilities = ["read"]
}

# Allow renewing the own token to keep authentication valid
path "auth/token/renew-self" {
  capabilities = ["update"]
}

# Allow listing metadata under the jenkins namespace
path "secret/metadata/jenkins/" {
  capabilities = ["list"]
}

# Deny all other operations
path "*" {
  capabilities = []
}