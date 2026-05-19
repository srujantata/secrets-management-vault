path "secret/data/sonarqube/*" {
  capabilities = ["read"]
}

path "database/creds/sonarqube-db-role" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}