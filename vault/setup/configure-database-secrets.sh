#!/bin/bash

# Enable the database secrets engine in Vault
vault secrets enable database

# Configure PostgreSQL connection details
POSTGRES_URL="postgresql://user:password@host:port/database"
vault write database/config/my-postgresql-database \
    plugin_name=postgresql-database-plugin \
    allowed_roles="jenkins-db-role,sonarqube-db-role" \
    connection_url="${POSTGRES_URL}"

# Create jenkins-db-role with 1-hour TTL and CREATE ROLE permissions
vault write database/roles/jenkins-db-role \
    db_name=my-postgresql-database \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration_time}}'; GRANT CREATE ON DATABASE \"database\" TO \"{{name}}\";" \
    default_ttl=1h \
    max_ttl=1h

# Create sonarqube-db-role with the same pattern
vault write database/roles/sonarqube-db-role \
    db_name=my-postgresql-database \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration_time}}'; GRANT CREATE ON DATABASE \"database\" TO \"{{name}}\";" \
    default_ttl=1h \
    max_ttl=1h

# Test: Read credentials for jenkins-db-role
vault read database/creds/jenkins-db-role