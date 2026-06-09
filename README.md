# JumpServerCE Installer

> One-command deployment of [JumpServer CE](https://www.jumpserver.com) on Ubuntu 24.04 LTS —
> with TLS, hardened security, and a sane reverse-proxy out of the box.

---

## What it does

```
curl/bash → certbot → nginx (TLS) → JumpServer (port 8080)
                                     Port 2222 (SSH sessions, direct)
fail2ban monitors: SSH :22 · Koko :2222 · nginx access log
ufw: allow 22, 80, 443, 2222 — deny everything else
```

| Component | Role |
|---|---|
| **JumpServerCE** | Privileged access management — web UI + SSH gateway (Koko) |
| **nginx** | TLS termination, HTTP→HTTPS redirect, WebSocket proxy |
| **Let's Encrypt** | Automated certificate issuance and renewal |
| **fail2ban** | Brute-force protection on SSH, Koko, and web login |
| **ufw** | Host-level firewall — minimal ingress surface |

---

## Requirements

| | Minimum | Notes |
|---|---|---|
| OS | Ubuntu 24.04 LTS | Other distros: warned, not blocked |
| CPU | 4 cores | Bypass with `--force-hardware` (**BUT DON'T DO THIS**) |
| RAM | 8 GB | Bypass with `--force-hardware` (**BUT DON'T DO THIS**)|
| Disk | 50 GB free | JumpServer + Docker images |
| DNS | A record → this server | Verified before cert issuance |
| Ports | 80, 443, 2222 open inbound | 80 needed transiently for certbot |

---

## Quick start

```bash
git clone <this-repo>
cd JumpServerInstall
sudo bash install.sh
```

The script will prompt for your FQDN and a Let's Encrypt email, then handle everything else.

---

## Options

```
sudo bash install.sh [--force-hardware] [--fqdn <domain>] [--email <addr>]
```

| Flag | Description |
|---|---|
| `--force-hardware` | Skip CPU and RAM minimum checks (**BUT DON'T DO THIS**)| 
| `--fqdn <domain>` | Pre-supply the FQDN — skips the interactive prompt |
| `--email <addr>` | Let's Encrypt notification address — skips the interactive prompt |

**Fully non-interactive example:**

```bash
sudo bash install.sh --fqdn jump.example.com --email ops@example.com
```

---

## What the installer does, step by step

```
Phase 1  Pre-flight     OS check · hardware check · port availability
Phase 2  FQDN           Format validation · DNS A-record verification · user confirm
Phase 3  Packages       nginx · certbot · fail2ban · ufw
Phase 4  Certificate    certbot standalone · deploy hook · auto-renewal
Phase 5  nginx          TLS proxy config · HTTP→HTTPS redirect · WebSocket headers
Phase 6  JumpServer     quick_start.sh · port reconfiguration (80→8080) · health check
Phase 7  fail2ban       SSH jail · Koko jail · web login jail
Phase 8  Firewall       ufw rules · deny-by-default ingress
Phase 9  Summary        URLs · credentials reminder · service status
```

---

## Idempotency

Running the script a second time detects the existing installation and offers:

```
  [1] Reinstall  — remove everything, then fresh install
  [2] Uninstall  — remove JumpServer, nginx config, fail2ban config
  [3] Exit
```

Both paths prompt separately before touching the Let's Encrypt certificate or the
JumpServer data directory (`/opt/jumpserver`).

---

## After install

| Task | How |
|---|---|
| Open the web UI | `https://<your-fqdn>` |
| SSH into a managed host | `ssh <user>@<your-fqdn> -p 2222` |
| **Change default password** | Log in as `admin / ChangeMe` — change immediately |
| Check service status | `/opt/jumpserver/jmsctl.sh status` |
| Restart JumpServer | `/opt/jumpserver/jmsctl.sh restart` |
| Check banned IPs | `fail2ban-client status jumpserver-web` |
| View install log | `cat /var/log/jumpserver-install.log` |

---

## Security posture

- TLS 1.2/1.3 only, with a Mozilla "Intermediate" cipher suite
- HSTS with `includeSubDomains` and `preload` (`max-age=63072000`)
- `X-Frame-Options: SAMEORIGIN` and `X-Content-Type-Options: nosniff` headers
- JumpServer does **not** bind to public ports — nginx is the only public listener
- fail2ban bans after 5 failures on SSH/Koko, 10 failures on web login (1-hour ban)
- ufw denies all ingress except ports 22, 80, 443, 2222

---

## Troubleshooting

**certbot fails**
Ensure port 80 is reachable from the internet (check your cloud/firewall security group)
and that the DNS A record has fully propagated (`dig +short <your-fqdn>`).

**JumpServer health check times out**
```bash
/opt/jumpserver/jmsctl.sh status
docker ps -a | grep jms
```
Image pulls on slow connections can take longer than 3 minutes; the service will still
come up — the health check warning is non-fatal.

**nginx fails to start after JumpServer install**
JumpServer may not have released port 80 yet. Check:
```bash
ss -tlnp | grep ':80 '
/opt/jumpserver/jmsctl.sh stop
systemctl start nginx
```

**Port 2222 fail2ban jail not triggering**
Koko runs inside Docker; auth failures may not reach `/var/log/auth.log` depending on
the JumpServer version. Monitor with `fail2ban-client status jumpserver-koko` and adjust
the `logpath` in `/etc/fail2ban/jail.d/jumpserver.conf` if needed.

---

## License

MIT