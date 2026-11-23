#!/bin/sh
# Orbit boot script for Railway. One file, one role per image (ORBIT_ROLE is baked into each image).
#
# Differences from upstream's compose stack (Noveum/orbit, deploy/docker/compose.yaml) that Railway forces:
#   - private hosts are <service>.railway.internal and the private network can be IPv6 only, so every private listener is
#     reachable on both families through dual-forward.mjs;
#   - Railway injects PORT into every service and overrides the image's own, so private services ignore it and use fixed ports,
#     while the public ones (gateway, storage) honour it, because the healthcheck dials the injected port;
#   - a template deploy starts every service at once, so each role waits for what it depends on;
#   - the one admin account is created from ADMIN_EMAIL / ADMIN_PASSWORD at boot, and sign-up is closed to everyone else by
#     setting ALLOWED_EMAIL_DOMAINS to the domain of ADMIN_EMAIL (generated and unguessable).
set -eu

role="${ORBIT_ROLE:?ORBIT_ROLE is not set}"
log() { echo "[orbit-boot:$role] $*"; }

DB_HOST="${DB_HOST:-db.railway.internal}"
REDIS_HOST="${REDIS_HOST:-redis.railway.internal}"
WEB_HOST="${WEB_HOST:-web.railway.internal}"

# Wait until host:port accepts a TCP connection.
wait_tcp() {
  until node -e 'const s=require("net").connect(+process.argv[2],process.argv[1]);s.on("connect",()=>process.exit(0));s.on("error",()=>process.exit(1));setTimeout(()=>process.exit(1),3000)' "$1" "$2" >/dev/null 2>&1; do
    log "waiting for $1:$2"
    sleep 3
  done
}

# Environment shared by web, realtime and scheduler.
app_env() {
  : "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is not set}"
  : "${REDIS_PASSWORD:?REDIS_PASSWORD is not set}"
  : "${S3_SECRET_ACCESS_KEY:?S3_SECRET_ACCESS_KEY is not set}"
  : "${BETTER_AUTH_SECRET:?BETTER_AUTH_SECRET is not set}"
  : "${CRON_SECRET:?CRON_SECRET is not set}"
  : "${BETTER_AUTH_URL:?BETTER_AUTH_URL is not set}"
  : "${S3_ENDPOINT:?S3_ENDPOINT is not set}"
  export DATABASE_URL="postgres://orbit:${POSTGRES_PASSWORD}@${DB_HOST}:5432/orbit"
  export DIRECT_URL="$DATABASE_URL"
  # ioredis defaults to IPv4 only; family=0 lets it use whichever family the private name resolves to.
  export REDIS_URL="redis://:${REDIS_PASSWORD}@${REDIS_HOST}:6379?family=0"
  export NEXT_PUBLIC_APP_URL="$BETTER_AUTH_URL"
  export ORBIT_INTERNAL_URL="http://${WEB_HOST}:3001"
  # Sign-up is limited to the (unguessable) domain of the admin address. Anything the deployer set stays allowed too.
  if [ -n "${ADMIN_EMAIL:-}" ]; then
    admin_domain="${ADMIN_EMAIL#*@}"
    if [ -n "${ALLOWED_EMAIL_DOMAINS:-}" ]; then
      export ALLOWED_EMAIL_DOMAINS="${ALLOWED_EMAIL_DOMAINS},${admin_domain}"
    else
      export ALLOWED_EMAIL_DOMAINS="$admin_domain"
    fi
  fi
}

case "$role" in
redis)
  : "${REDIS_PASSWORD:?REDIS_PASSWORD is not set}"
  # The stock entrypoint chowns /data and drops to the redis user itself. A start command would replace it, so call it from here.
  exec docker-entrypoint.sh redis-server --requirepass "$REDIS_PASSWORD" --appendonly yes --dir /data
  ;;

storage)
  : "${S3_SECRET_ACCESS_KEY:?S3_SECRET_ACCESS_KEY is not set}"
  : "${BETTER_AUTH_URL:?BETTER_AUTH_URL is not set}"
  # `weed server -s3` is anonymous unless an identity is configured. One identity, the key Orbit signs with.
  printf '{"identities":[{"name":"orbit","credentials":[{"accessKey":"orbit","secretKey":"%s"}],"actions":["Admin","Read","Write","List","Tagging"]}]}' \
    "$S3_SECRET_ACCESS_KEY" > /tmp/s3.json
  mkdir -p /data/seaweed
  # Slot sizing: every bucket is a collection that grows several volumes (docs/field-traps.md, SeaweedFS).
  # The volume server defaults to 8080, which is the injected PORT the S3 gateway has to take, so move it.
  exec weed server -dir=/data/seaweed -ip.bind=0.0.0.0 -master.volumeSizeLimitMB=256 -volume.max=1000 -volume.port=18081 \
    -s3 -s3.port="${PORT:-8080}" -s3.config=/tmp/s3.json -s3.allowedOrigins="$BETTER_AUTH_URL"
  ;;

web)
  app_env
  : "${ADMIN_EMAIL:?ADMIN_EMAIL is not set}"
  : "${ADMIN_PASSWORD:?ADMIN_PASSWORD is not set}"
  wait_tcp "$DB_HOST" 5432
  wait_tcp "$REDIS_HOST" 6379
  cd /app
  log "migrating"
  node apps/web/migrate.mjs
  HOSTNAME=127.0.0.1 PORT=3000 node apps/web/start.mjs &
  app=$!
  node /usr/local/bin/dual-forward.mjs 3001 3000 &
  fwd=$!
  trap 'kill "$app" "$fwd" 2>/dev/null || true' TERM INT
  (
    until node -e 'fetch("http://127.0.0.1:3000/api/health").then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))'; do sleep 2; done
    log "web answers /api/health, bootstrapping"
    node /app/orbit-boot/bootstrap.mjs
  ) &
  wait "$app"
  ;;

realtime)
  app_env
  wait_tcp "$DB_HOST" 5432
  wait_tcp "$REDIS_HOST" 6379
  cd /app
  node apps/web/realtime.mjs &
  app=$!
  # realtime.mjs binds 0.0.0.0:3100; the forwarder adds the IPv6 listener the private network may need.
  node /usr/local/bin/dual-forward.mjs 3101 3100 &
  fwd=$!
  trap 'kill "$app" "$fwd" 2>/dev/null || true' TERM INT
  wait "$app"
  ;;

scheduler)
  : "${CRON_SECRET:?CRON_SECRET is not set}"
  export ORBIT_INTERNAL_URL="http://${WEB_HOST}:3001"
  wait_tcp "$WEB_HOST" 3001
  cd /app
  exec node apps/web/scheduler.mjs
  ;;

*)
  log "unknown role"
  exit 2
  ;;
esac
