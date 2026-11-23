# orbit-railway

Wrapper images that run [Noveum Orbit](https://github.com/Noveum/orbit) (Apache-2.0, upstream marks it Preview) on Railway as seven
services: web, realtime, scheduler, gateway (Caddy), Postgres, Redis and SeaweedFS (S3). Each image pins the upstream image by digest and adds
`railway-boot.sh`, which waits for dependencies, runs migrations, creates the S3 bucket and the one admin account from `ADMIN_EMAIL` /
`ADMIN_PASSWORD`, and closes sign-up to every other email domain.

Images: `ghcr.io/bon5co/orbit-railway-<role>:2026.09.24`, built by `.github/workflows/publish.yml`.
