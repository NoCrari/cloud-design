FROM postgres:14-alpine

# Optional init scripts can be placed here to customize the DB
# Any *.sql or *.sh file copied into /docker-entrypoint-initdb.d/
# will be executed on first container startup when the data dir is empty.

COPY initdb/ /docker-entrypoint-initdb.d/

# Expose standard Postgres port
EXPOSE 5432

