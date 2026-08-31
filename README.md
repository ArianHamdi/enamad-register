# enamad site

A single static page served by Caddy in Docker, with automatic Let's Encrypt SSL
and a log of every incoming request. Targets a Linux server; also runs on macOS
for local testing.

## Requirements

Docker. On **Linux**, `./prod.sh` installs it for you (with your confirmation)
and enables it at boot. On **macOS** it will not install anything - it tells you
to run `brew install --cask docker` and stops.

Everything else runs inside the `caddy:2-alpine` container; no web server, Caddy
binary, or certbot is installed on the host.

## Setup

1. Point your domain's `A` record (and `www`, if you keep `WITH_WWW=1`) at this server.
2. Run it:

```sh
./prod.sh
```

The first run asks for the two things it needs and saves them to `config.env`,
so it never asks again:

```
==> enamad code (the number from enamad.ir): 60511192
==> domain to serve it on (e.g. mysite.ir): mysite.ir
==> saved to config.env - it will not ask again
```

You can paste `https://www.mysite.ir/` — it is trimmed down to the host, and a
leading `www.` just turns on `WITH_WWW`.

To skip the prompts entirely (CI, systemd, cron), fill `config.env` in ahead of
time or pass the values as env vars — with no terminal attached the script exits
with an error instead of hanging:

```sh
DOMAIN=mysite.ir ENAMAD_CODE=60511192 ./prod.sh
```

Env vars win over `config.env` for that run and are not written back to it.

Then it renders the site, writes the `Caddyfile`, pulls `caddy:2-alpine` and
starts it detached. The certificate is obtained on first boot and renewed
automatically.

## What gets served

| URL | Content |
| --- | --- |
| `https://DOMAIN/` | page whose `<title>` is the code, with `<meta name="enamad" content="CODE" />` |
| `https://DOMAIN/CODE.txt` | the code, as `text/plain` |

`site/` and `Caddyfile` are generated from `template.html` + `config.env` on every
run — edit those two, not the generated output.

## Commands

```sh
./prod.sh            # build + start in the background
./prod.sh up         # same, attached to the logs
./prod.sh restart    # regenerate the site and reload
./prod.sh stop       # stop and remove the container
./prod.sh logs       # follow ./logs/access.log (JSON, one line per request)
./prod.sh console    # follow Caddy's readable console output
./prod.sh status     # container state + issued certificates
./prod.sh build      # regenerate only, don't start
```

Any config value can be overridden per-run:

```sh
DOMAIN=staging.example.ir HTTPS_PORT=8443 ./prod.sh
```

## Request log

Every request is written to `./logs/access.log` as one JSON object per line —
client IP, method, host, URI, headers, status, response size, duration, TLS
details. It rolls at 10 MiB, keeps 10 files for 30 days.

```sh
./prod.sh logs
tail -f logs/access.log | jq '{ip: .request.client_ip, uri: .request.uri, status}'
```

Certificates live in the `caddy_data` Docker volume, so they survive
`./prod.sh stop` and are not re-issued on every restart.

## Docker bootstrap

On the first run `./prod.sh` checks, in order:

| Check | Linux | macOS |
| --- | --- | --- |
| Docker missing | asks, then installs via `get.docker.com` | prints the `brew` command and stops |
| Daemon stopped | `systemctl enable --now docker` (also survives reboots) | launches Docker Desktop and waits |
| No socket permission | falls back to `sudo docker`, tells you to `usermod -aG docker` | n/a |
| Compose plugin missing | installs `docker-compose-plugin` | n/a |

For unattended installs (CI, cloud-init, a fresh VPS) set `ASSUME_YES=1` to skip
the confirmation prompt:

```sh
ASSUME_YES=1 DOMAIN=mysite.ir ENAMAD_CODE=60511192 ./prod.sh
```

Without a terminal and without `ASSUME_YES`, the script exits with instructions
rather than hanging on a prompt.

## Notes

- Port 80 must be reachable from the internet — Let's Encrypt uses it to verify
  the domain. Keep `HTTP_PORT=80`.
- HTTP is redirected to HTTPS automatically; HTTP/3 is enabled on 443/udp.
- `restart` is enough after changing the code or the page; the certificate is untouched.
- The container is `restart: unless-stopped`, and Docker is enabled at boot on
  Linux, so the site comes back by itself after a reboot.
- `DOMAIN=localhost` is accepted for local testing - Caddy issues an internal
  certificate for it instead of talking to Let's Encrypt.
