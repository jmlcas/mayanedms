#!make
include config.env

ifneq ($(wildcard config-local.env),)
	include config-local.env
endif

CONSOLE_COLUMNS ?= `echo $$(tput cols)`
CONSOLE_LINES ?= `echo $$(tput lines)`
IMAGE_VERSION ?= `cat docker/rootfs/version`
DOCKER_HOST_REGISTRY_NAME ?= $(DOCKER_HOST_REGISTRY_NAME)
DOCKER_HOST_REGISTRY_PORT ?= $(DOCKER_HOST_REGISTRY_PORT)
DOCKER_IMAGE_MAYAN_NAME ?= $(DOCKER_IMAGE_MAYAN_NAME)
DOCKER_IMAGE_DATE_TIME ?= `date -Iseconds  --utc`
DOCKER_IMAGE_LABELS ?= --label org.opencontainers.image.created="$(DOCKER_IMAGE_DATE_TIME)" --label org.opencontainers.image.version=$(IMAGE_VERSION) $(DOCKER_IMAGE_LABELS_EXTRA)
MAYAN_TEST_MEDIA_ROOT ?= /tmp/mayan-test

# Build

docker-buildkitd-config-create:
	@echo "debug = true" > /tmp/buildkitd.toml
	@if [ $(DOCKER_MIRROR) ]; then \
		echo "" >> /tmp/buildkitd.toml; \
		echo '[registry."docker.io"]' >> /tmp/buildkitd.toml; \
		echo '  mirrors = ["$(DOCKER_MIRROR)"]' >> /tmp/buildkitd.toml; \
	fi

docker-build: ## Build a new image locally.
docker-build: docker-dockerfile-update docker-buildkitd-config-create
	docker buildx rm mirrored || true
	docker context rm tls-context || true
	docker context create tls-context
	docker buildx create --bootstrap --config /tmp/buildkitd.toml --driver docker-container --name mirrored --use tls-context
	DOCKER_BUILDKIT=1 docker build --build-arg APT_PROXY=$(APT_PROXY) --build-arg PIP_INDEX_URL=$(PIP_INDEX_URL) --build-arg PIP_TRUSTED_HOST=$(PIP_TRUSTED_HOST) --build-arg HTTP_PROXY=$(HTTP_PROXY) --build-arg HTTPS_PROXY=$(HTTPS_PROXY) --builder mirrored --file docker/Dockerfile $(DOCKER_IMAGE_LABELS) --output type=docker --tag $(DOCKER_IMAGE_MAYAN_NAME):$(IMAGE_VERSION) .
	docker buildx stop mirrored

docker-dockerfile-update: ## Update the Dockerfile file from the platform template.
docker-dockerfile-update: copy-config-env
	./manage.py platform_template docker_dockerfile > docker/Dockerfile

docker-docker-compose-update: ## Update the Docker Compose file from the platform template.
docker-docker-compose-update: copy-config-env
	./manage.py platform_template docker_docker_compose > docker/docker-compose.yml

# Registry

docker-registry-push: ## Push a built image to the test Docker registry.
	docker tag $(DOCKER_IMAGE_MAYAN_NAME):$(IMAGE_VERSION) $(DOCKER_HOST_REGISTRY_NAME):$(DOCKER_HOST_REGISTRY_PORT)/$(DOCKER_IMAGE_MAYAN_NAME):$(IMAGE_VERSION)
	docker push $(DOCKER_HOST_REGISTRY_NAME):$(DOCKER_HOST_REGISTRY_PORT)/$(DOCKER_IMAGE_MAYAN_NAME):$(IMAGE_VERSION)
	# /etc/docker/daemon.json {"insecure-registries" : ["docker-registry.local:5000"]}
	# /etc/hosts <ip address>  docker-registry.local

docker-registry-pull: ## Pull an image from the test Docker registry.
	docker pull $(DOCKER_HOST_REGISTRY_NAME):$(DOCKER_HOST_REGISTRY_PORT)/$(DOCKER_IMAGE_MAYAN_NAME):$(IMAGE_VERSION)
	docker tag $(DOCKER_HOST_REGISTRY_NAME):$(DOCKER_HOST_REGISTRY_PORT)/$(DOCKER_IMAGE_MAYAN_NAME):$(IMAGE_VERSION) $(DOCKER_IMAGE_MAYAN_NAME):$(IMAGE_VERSION)

docker-registry-catalog: ## Show the test Docker registry catalog.
	curl http://$(DOCKER_HOST_REGISTRY_NAME):$(DOCKER_HOST_REGISTRY_PORT)/v2/_catalog

docker-registry-tags: ## Show the tags for the image in the test Docker registry.
	curl http://$(DOCKER_HOST_REGISTRY_NAME):$(DOCKER_HOST_REGISTRY_PORT)/v2/$(DOCKER_IMAGE_MAYAN_NAME)/tags/list

docker-registry-run: # Launch a test Docker registry.
	docker run --detach --name registry --publish 5000:5000 registry:2

# Test

docker-shell: ## Launch a bash instance inside a running container. Pass the container name via DOCKER_CONTAINER.
	docker exec --env TERM=$(TERM) --env "COLUMNS=$(CONSOLE_COLUMNS)" --env "LINES=$(CONSOLE_LINES)" --interactive --tty $(DOCKER_CONTAINER) /bin/bash

docker-runtest-container: ## Run a test container.
docker-runtest-container: docker-test-cleanup
	docker run \
	--detach \
	--name test-mayan-edms \
	--publish 80:8000 \
	--volume test-mayan_data:/var/lib/mayan \
	$(DOCKER_IMAGE_MAYAN_NAME):$(IMAGE_VERSION)

docker-runtest-cleanup: ## Delete the test container and the test volume.
	@docker rm --file test-mayan-edms || true
	@docker volume rm test-mayan_data || true

docker-runtest-all: ## Executed the test suite in a test container.
	docker run --rm $(DOCKER_IMAGE_MAYAN_NAME):$(IMAGE_VERSION) run_tests

# Test and staging containers

docker-elastic-start: ## Start an Elastic Search test container.
docker-elastic-start:
	@docker run --detach -e ES_JAVA_OPTS="-Xms256m -Xmx256m" -e "discovery.type=single-node" -e "network.host=0.0.0.0" -e "ingest.geoip.downloader.enabled=false" --name $(CONTAINER_NAME_TEST_ELASTIC) --publish 9200:9200 --publish 9300:9300 $(DOCKER_ELASTIC_IMAGE_NAME):$(DOCKER_ELASTIC_IMAGE_TAG)
	@while ! nc -z 127.0.0.1 9200; do echo -n .; sleep 1; done

docker-elastic-stop: ## Stop and delete the Elastic Search container.
docker-elastic-stop:
	@docker rm --force $(CONTAINER_NAME_TEST_ELASTIC) >/dev/null 2>&1

docker-mysql-start: ## Start a MySQL Docker test container.
	@docker run --detach --name $(CONTAINER_NAME_TEST_MYSQL) --publish 3306:3306 --env MYSQL_ALLOW_EMPTY_PASSWORD="yes" --env MYSQL_USER=$(DEFAULT_DATABASE_USER) --env MYSQL_PASSWORD=$(DEFAULT_DATABASE_PASSWORD) --env MYSQL_DATABASE=$(DEFAULT_DATABASE_NAME) --volume $(CONTAINER_NAME_TEST_MYSQL):/var/lib/mysql $(DOCKER_MYSQL_IMAGE_VERSION) --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci
	@while ! mysql -h 127.0.0.1 --user=$(DEFAULT_DATABASE_USER) --password=$(DEFAULT_DATABASE_PASSWORD) --execute "SHOW TABLES;" $(DEFAULT_DATABASE_NAME) >/dev/null 2>&1; do echo -n .;sleep 2; done

docker-mysql-stop: ## Stop and delete the MySQL container.
	@docker rm --force $(CONTAINER_NAME_TEST_MYSQL) >/dev/null 2>&1
	@docker volume rm $(CONTAINER_NAME_TEST_MYSQL) >/dev/null 2>&1 || true

docker-mysql-backup:
	@mysqldump --host=127.0.0.1 --no-tablespaces --user=$(DEFAULT_DATABASE_USER) --password=$(DEFAULT_DATABASE_PASSWORD) $(DEFAULT_DATABASE_NAME) > mayan-docker-mysql-backup.sql

docker-mysql-restore:
	@mysql --host=127.0.0.1 --user=$(DEFAULT_DATABASE_USER) --password=$(DEFAULT_DATABASE_PASSWORD) $(DEFAULT_DATABASE_NAME) < mayan-docker-mysql-backup.sql

docker-oracle-start: ## Start an Oracle test container.
docker-oracle-start:
	@docker run --detach --name $(CONTAINER_NAME_TEST_ORACLE) --publish 49160:22 --publish 49161:1521 --env ORACLE_ALLOW_REMOTE=true --volume $(CONTAINER_NAME_TEST_ORACLE):/u01/app/oracle $(DOCKER_ORACLE_IMAGE_VERSION)
	@sleep 10
	@while ! nc -z 127.0.0.1 49161; do echo -n .; sleep 2; done

docker-oracle-stop:
docker-oracle-stop: ## Stop and delete the Oracle test container.
	@docker rm --force $(CONTAINER_NAME_TEST_ORACLE) >/dev/null 2>&1
	@docker volume rm $(CONTAINER_NAME_TEST_ORACLE) >/dev/null 2>&1 || true

docker-postgresql-start: ## Start a PostgreSQL Docker test container.
	@docker run --detach --name $(CONTAINER_NAME_TEST_POSTGRESQL) --env POSTGRES_HOST_AUTH_METHOD=trust --env POSTGRES_USER=$(DEFAULT_DATABASE_USER) --env POSTGRES_PASSWORD=$(DEFAULT_DATABASE_PASSWORD) --env POSTGRES_DB=$(DEFAULT_DATABASE_NAME) --publish 5432:5432 --volume $(CONTAINER_NAME_TEST_POSTGRESQL):/var/lib/postgresql/data $(DOCKER_POSTGRESQL_IMAGE_NAME):$(DOCKER_POSTGRESQL_IMAGE_TAG)
	@while ! docker exec --interactive --tty $(CONTAINER_NAME_TEST_POSTGRESQL) psql --command "\l" --dbname=$(DEFAULT_DATABASE_NAME) --host=127.0.0.1 --username=$(DEFAULT_DATABASE_USER) >/dev/null 2>&1; do echo -n .;sleep 1; done

docker-postgresql-stop: ## Stop and delete the PostgreSQL container.
	@docker rm --force $(CONTAINER_NAME_TEST_POSTGRESQL) >/dev/null 2>&1
	@docker volume rm $(CONTAINER_NAME_TEST_POSTGRESQL) >/dev/null 2>&1 || true

docker-postgresql-backup:
	@PGPASSWORD="$(DEFAULT_DATABASE_PASSWORD)" pg_dump --dbname=$(DEFAULT_DATABASE_NAME) --host=127.0.0.1 --username=$(DEFAULT_DATABASE_USER) > mayan-docker-postgresql-backup.sql

docker-postgresql-restore:
	@cat mayan-docker-postgresql-backup.sql | psql --dbname=$(DEFAULT_DATABASE_NAME) --host=127.0.0.1 --username=$(DEFAULT_DATABASE_USER) > /dev/null

docker-redis-start: ## Start a Redis Docker test container.
docker-redis-start:
	docker run --detach --name $(CONTAINER_NAME_TEST_REDIS) --publish 6379:6379 --volume $(CONTAINER_NAME_TEST_REDIS):/data $(DOCKER_REDIS_IMAGE_NAME):$(DOCKER_REDIS_IMAGE_TAG)
	@while ! docker exec --interactive --tty $(CONTAINER_NAME_TEST_REDIS) redis-cli CONFIG GET databases >/dev/null 2>&1; do echo -n .;sleep 1; done

docker-redis-stop: ## Stop and delete the Redis container.
docker-redis-stop:
	@docker rm --force $(CONTAINER_NAME_TEST_REDIS) >/dev/null 2>&1
	@docker volume rm $(CONTAINER_NAME_TEST_REDIS) >/dev/null 2>&1 || true

# Staging

docker-staging-start: ## Launch and initialize production-like services using Docker (PostgreSQL and Redis).
docker-staging-start: docker-staging-stop docker-postgresql-start docker-redis-start
	export MAYAN_DATABASES="{'default':{'ENGINE':'django.db.backends.postgresql','NAME':'$(DEFAULT_DATABASE_NAME)','PASSWORD':'$(DEFAULT_DATABASE_PASSWORD)','USER':'$(DEFAULT_DATABASE_USER)','HOST':'127.0.0.1'}}"; \
	rm --force --recursive $(MAYAN_TEST_MEDIA_ROOT); \
	export MAYAN_MEDIA_ROOT=$(MAYAN_TEST_MEDIA_ROOT); \
	./manage.py common_initial_setup --settings=mayan.settings.staging.docker

docker-staging-stop: ## Stop and delete the Docker production-like services.
docker-staging-stop: docker-postgresql-stop docker-redis-stop

docker-staging-frontend: ## Launch a front end instance that uses the production-like services.
	export MAYAN_DATABASES="{'default':{'ENGINE':'django.db.backends.postgresql','NAME':'$(DEFAULT_DATABASE_NAME)','PASSWORD':'$(DEFAULT_DATABASE_PASSWORD)','USER':'$(DEFAULT_DATABASE_USER)','HOST':'127.0.0.1'}}"; \
	$(COMMAND_SENTRY); ./manage.py runserver --settings=mayan.settings.staging.docker

docker-staging-worker: ## Launch a worker instance that uses the production-like services.
	export MAYAN_DATABASES="{'default':{'ENGINE':'django.db.backends.postgresql','NAME':'$(DEFAULT_DATABASE_NAME)','PASSWORD':'$(DEFAULT_DATABASE_PASSWORD)','USER':'$(DEFAULT_DATABASE_USER)','HOST':'127.0.0.1'}}"; \
	DJANGO_SETTINGS_MODULE=mayan.settings.staging.docker celery -A mayan worker -B -l INFO -O fair

