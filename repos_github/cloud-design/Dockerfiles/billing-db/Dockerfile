FROM postgres:14-alpine

# Optional init scripts: create extensions, tune, etc.
COPY initdb/ /docker-entrypoint-initdb.d/

EXPOSE 5432

