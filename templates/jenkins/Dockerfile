# floci-jenkins image: stock Jenkins LTS + the pinned plugin set + a static
# `docker` CLI.
#
# This Jenkins runs as a plain Docker container (no Kubernetes plugin, no
# build agents) -- see main.tf's `--- jenkins ---` section. Pipelines build
# images by shelling `docker build` / `docker run` against the host daemon
# socket bind-mounted into this container, so the `docker` CLI has to be
# present here (only the client -- the daemon is the host's).
#
# Plugins are installed here, at build time. The stock jenkins/jenkins:lts
# entrypoint does NOT install from a runtime plugins.txt (the old Helm setup
# did) -- without this step Jenkins boots with zero plugins and the
# init.groovy.d seed script fails on `import hudson.plugins.git.*`.
FROM jenkins/jenkins:lts

USER root

# --- plugins -------------------------------------------------------------
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt --verbose

# --- docker CLI + buildx plugin --------------------------------------
# Pinned -- an unpinned "latest" static bundle URL 404s the moment Docker
# publishes a newer point release and drops the old file. aarch64 + x86_64
# both handled so this builds on Apple Silicon and CI Linux alike.
#
# buildx is required, not optional: the modern `docker` CLI routes
# `docker build` through buildx, and without it a build of the app's
# BuildKit Dockerfiles fails outright ("BuildKit is enabled but the buildx
# component is missing"). Installed as a CLI plugin; it drives the host
# daemon's own embedded BuildKit (the default `docker` driver), so no
# separate builder container is needed.
ARG DOCKER_CLI_VERSION=27.5.1
ARG BUILDX_VERSION=0.20.1
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) darch=x86_64; bxarch=amd64 ;; \
      arm64) darch=aarch64; bxarch=arm64 ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://download.docker.com/linux/static/stable/${darch}/docker-${DOCKER_CLI_VERSION}.tgz" \
      -o /tmp/docker.tgz; \
    tar -xzf /tmp/docker.tgz -C /usr/local/bin --strip-components=1 docker/docker; \
    rm /tmp/docker.tgz; \
    mkdir -p /usr/local/lib/docker/cli-plugins; \
    curl -fsSL "https://github.com/docker/buildx/releases/download/v${BUILDX_VERSION}/buildx-v${BUILDX_VERSION}.linux-${bxarch}" \
      -o /usr/local/lib/docker/cli-plugins/docker-buildx; \
    chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx; \
    docker --version; \
    docker buildx version

# The container itself is started with `user = "0:0"` in main.tf (the
# bind-mounted host socket is root-owned and Docker Desktop doesn't expose a
# stable gid to add `jenkins` to) -- this USER line only affects an
# interactive `docker exec` default.
USER jenkins
