# Traefik v3 Reverse Proxy Setup

This guide documents the `setup-traefik.sh` script, which deploys a production-ready **Traefik v3** reverse proxy on Ubuntu with Docker Compose. It includes TLS via Let's Encrypt, security headers, rate limiting, and an optional protected dashboard.

## Table of Contents
- [Features](#features)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Configuration Options](#configuration-options)
- [Usage Examples](#usage-examples)
- [Adding Applications to Traefik](#adding-applications-to-traefik)
- [Dashboard Access](#dashboard-access)
- [Troubleshooting](#troubleshooting)
- [File Structure](#file-structure)

---

## Features

- **Automatic TLS** with Let's Encrypt (HTTP or DNS challenge)
- **Security Headers**: HSTS, X-Frame-Deny, Content-Type sniff protection
- **Rate Limiting**: Prevents abuse with configurable request limits
- **Basic Auth Middleware**: Protect sensitive routes (including dashboard)
- **IP Allowlist**: Restrict dashboard access to private networks
- **Hot Reload**: Dynamic configuration updates without restart
- **Dashboard** (optional): Web UI for monitoring routers, services, and middlewares
- **Idempotent**: Safe to run multiple times; detects existing installations

---

## Prerequisites

Before running the setup script:

1. **Ubuntu** system with `sudo` privileges
2. **Docker Engine** installed and running
3. **User in docker group**: `groups $USER | grep docker` should show "docker"
4. **Valid email address** for Let's Encrypt account registration
5. **(Optional)** Cloudflare DNS API token if using DNS challenge

> ⚠️ The script will fail if `ACME_EMAIL` is not provided with a real email address (Let's Encrypt rejects placeholder emails).

---

## Quick Start

```bash
# Basic setup with default domain and HTTP challenge
ACME_EMAIL=your@email.com ./tasks/setup-traefik.sh

# With dashboard enabled
TRAEFIK_DASHBOARD=true ACME_EMAIL=your@email.com ./tasks/setup-traefik.sh

# Interactive mode (prompts for confirmation)
./tasks/setup-traefik.sh --interactive
```

After successful setup:
- **Logs**: `docker compose -f /opt/traefik/docker-compose.yml logs -f traefik`
- **Dashboard** (if enabled): Visit `https://<domain>/dashboard/` and use the generated credentials

---

## Configuration Options

All options can be set as environment variables before running the script. Override defaults by exporting them:

```bash
export TRAEFIK_DOMAIN="traefik.example.com"
export ACME_EMAIL="admin@example.com"
./tasks/setup-traefik.sh
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TRAEFIK_HOME` | `/opt/traefik` | Directory for Traefik configuration files |
| `TRAEFIK_IMAGE` | `traefik:v3` | Docker image tag to use |
| `TRAEFIK_DOMAIN` | `traefik.example.com` | Domain name for TLS certificate and dashboard URL |
| `TRAEFIK_DASHBOARD` | `false` | Enable Traefik dashboard (`true`/`false`) |
| `ACME_EMAIL` | *(required)* | Email for Let's Encrypt account registration (**must be real**) |
| `ACME_STAGING` | `false` | Use Let's Encrypt staging server (test certificates) |
| `DNS_PROVIDER` | *empty* | DNS provider for ACME challenge (`cloudflare`, etc.) |
| `CF_DNS_API_TOKEN` | *empty* | Cloudflare API token if using DNS challenge |
| `TRAEFIK_ADMIN_USER` | `admin` | Username for dashboard basic auth |
| `TRAEFIK_ADMIN_PASS` | *(auto-generated)* | Password for dashboard; empty = auto-generate secure password |
| `PROXY_NETWORK` | `proxy` | Docker network name for Traefik and backend services |
| `USE_SOCKET_PROXY` | `true` | Use docker-socket-proxy for enhanced security |
| `HTTP_PORT` | `80` | HTTP entry point port |
| `HTTPS_PORT` | `443` | HTTPS entry point port |

### Interactive Mode

When using `--interactive`, the script will:
1. Check if Traefik is already running and ask whether to tear down and recreate
2. Warn about default configuration values (e.g., `TRAEFIK_DOMAIN`)
3. Prompt for confirmation before overwriting existing configurations

---

## Usage Examples

### 1. Basic Setup with HTTP Challenge

```bash
ACME_EMAIL=admin@denkfabrik.space ./tasks/setup-traefik.sh
```

This creates a Traefik instance that:
- Uses HTTP challenge on port 80 for Let's Encrypt
- Generates a random admin password (displayed once)
- Does not enable the dashboard by default

### 2. Production Setup with Cloudflare DNS

```bash
export TRAEFIK_DOMAIN="proxy.example.com"
export ACME_EMAIL=admin@example.com
export DNS_PROVIDER=cloudflare
export CF_DNS_API_TOKEN="your_cloudflare_api_token_here"
export TRAEFIK_DASHBOARD=true
./tasks/setup-traefik.sh --interactive
```

This configures:
- DNS challenge via Cloudflare (no port 80 exposure needed)
- Dashboard accessible at `https://proxy.example.com/dashboard/`
- Protected dashboard with basic auth and IP allowlist

### 3. Staging Environment for Testing

```bash
ACME_EMAIL=test@example.com ACME_STAGING=true ./tasks/setup-traefik.sh
```

Uses Let's Encrypt staging server (produces untrusted certificates). Useful for testing without rate limit concerns.

### 4. Custom Ports and Network

```bash
HTTP_PORT=8080 HTTPS_PORT=8443 PROXY_NETWORK=myproxy \
ACME_EMAIL=admin@example.com ./tasks/setup-traefik.sh
```

Changes entry point ports to 8080/8443 and uses `myproxy` as the network name.

---

## Adding Applications to Traferik

To expose an application through Traefik, follow these steps:

### Step 1: Add Container to Proxy Network

Ensure your app container is connected to the `proxy` network (or whatever `PROXY_NETWORK` you chose):

```bash
docker network connect proxy my-app-container
# Or define in docker-compose.yml under service networks section
```

### Step 2: Add Traefik Labels to Your Container

Add these Docker labels to your application container. Here's an example using a `docker-compose.yml`:

```yaml
version: '3.8'

services:
  myapp:
    image: nginx:alpine
    container_name: myapp
    restart: unless-stopped
    
    # Connect to Traefik network
    networks:
      - proxy
    
    labels:
      # Enable Traefik for this service
      - "traefik.enable=true"
      
      # Specify the Docker network
      - "traefik.docker.network=proxy"
      
      # Define routing rule (domain-based)
      - "traefik.http.routers.myapp.rule=Host(`myapp.example.com`)"
      
      # Use HTTPS entry point
      - "traefik.http.routers.myapp.entrypoints=websecure"
      
      # Enable TLS with Let's Encrypt
      - "traefik.http.routers.myapp.tls=true"
      - "traefik.http.routers.myapp.tls.certresolver=letsencrypt"
      
      # Apply security headers middleware
      - "traefik.http.routers.myapp.middlewares=security-headers@file"
      
      # Define the backend service
      - "traefik.http.services.myapp.loadbalancer.server.port=80"

networks:
  proxy:
    external: true
```

#### WebSocket services (example: Pi Pocket)

Applications that open WebSockets alongside plain HTTP need no extra labels: Traefik
proxies the upgrade request on the same router. `setup-pi-pocket.sh` is a working
example — Pi Pocket serves the web UI and its session sockets on one port, and
`traefik.http.routers.pipocket.*` (plain name, no dots or hyphens: Traefik splits
label keys on `.`) is all the routing config it needs. If a WebSocket stream later
fails with `426`/`502`, check the idle timeout behind a `transportName` on the
router entry before inventing new label sets.

### Common Router Patterns

#### Host-based routing
```yaml
- "traefik.http.routers.myapp.rule=Host(`myapp.example.com`)"
```

#### Path-based routing
```yaml
- "traefik.http.routers.apiapp.rule=Host(`example.com`) && PathPrefix(`/api`)"
```

#### Combined host and path
```yaml
- "traefik.http.routers.myapp.rule=Host(`example.com`) && (PathPrefix(`/app1`) || PathPrefix(`/app2`))"
```

### Applying Basic Auth to Your App

Add the `auth-basic` middleware:

```yaml
labels:
  - "traefik.http.routers.myapp.middlewares=security-headers@file,auth-basic@file"
```

This applies both security headers and basic authentication.

---

## Dashboard Access

When enabled (`TRAEFIK_DASHBOARD=true`), the dashboard is accessible at `https://<domain>/dashboard/`.

### Security Features

The dashboard has built-in protections:
1. **Basic Auth**: Requires username/password (auto-generated or provided)
2. **IP Allowlist**: Only accessible from private IP ranges (RFC 1918 + loopback)
3. **TLS Required**: Dashboard only available over HTTPS

### Accessing the Dashboard

After setup, note these credentials from the script output:

```
Dashboard URL    https://traefik.example.com/dashboard/
Admin user       admin
Admin password   [randomly-generated-password]  (save this — it will not be shown again)
```

**Important**: If you set `TRAEFIK_ADMIN_PASS` manually, use that value instead of the generated one.

### Access from Outside Private Networks

The default IP allowlist blocks access from public IPs. To override:

1. Edit `/opt/traefik/dynamic/middlewares.yml`
2. Modify or remove the `ip-allowlist-private` middleware reference in `dashboard-security` chain
3. Traefik will hot-reload automatically (no restart needed)

---

## Troubleshooting

### Certificate Not Obtained

```bash
# Check Let's Encrypt logs
docker compose -f /opt/traefik/docker-compose.yml logs traefik

# Verify domain resolves to this server
dig +short example.com

# Test HTTP challenge manually (if using HTTP challenge)
curl -I http://example.com/.well-known/acme-challenge/test
```

### Dashboard Not Accessible

1. Check if dashboard is enabled: `TRAEFIK_DASHBOARD=true` during setup
2. Verify domain matches configured `TRAEFIK_DOMAIN`
3. Ensure TLS certificate was issued (check container logs)
4. Confirm you're accessing via HTTPS, not HTTP

### "Container Not Healthy" Error

Wait up to 60 seconds after startup for health check:

```bash
# Check status manually
docker ps --filter name=traefik --format "{{.Status}}"

# View recent logs
docker compose -f /opt/traefik/docker-compose.yml logs --tail=50 traefik
```

### Port Already in Use

Edit `TRAEFIK_HOME/.env` or set environment variables before running:

```bash
HTTP_PORT=8080 HTTPS_PORT=8443 ./tasks/setup-traefik.sh
```

Then restart Traefik:

```bash
docker compose -f /opt/traefik/docker-compose.yml restart traefik
```

### Existing Installation Detected

When running on an existing system, the script will ask whether to tear down and recreate. Data in `letsencrypt/` is preserved during teardown.

---

## File Structure

After setup, your Traefik configuration resides at `/opt/traefik/`:

```
/opt/traefik/
├── .env                          # Environment variables (ACME_EMAIL, CF_DNS_API_TOKEN)
├── traefik.yml                   # Static configuration (entry points, providers, certs)
├── docker-compose.yml            # Docker Compose definition for Traefik container
├── letsencrypt/
│   └── acme.json                 # Stored certificates (chmod 600 - KEEP SECURE!)
├── auth/
│   └── .htpasswd                 # Basic authentication credentials
└── dynamic/
    ├── middlewares.yml           # HTTP middlewares (security, rate-limit, auth)
    ├── tls.yml                   # TLS options (min version, ciphers)
    └── host-services.yml.example # Reference for proxying host-local services

```

### Configuration Files Explained

#### `traefik.yml` (Static Config)
- API/Dashboard settings
- Entry points (`web`, `websecure`)
- Docker provider configuration
- Let's Encrypt resolver settings

#### `dynamic/middlewares.yml` (Dynamic Config - Hot Reloadable)
- **security-headers**: HSTS, X-Frame-Deny, etc.
- **rate-limit**: Request throttling (100 req/s average, 50 burst)
- **auth-basic**: Basic authentication using `.htpasswd`
- **ip-allowlist-private**: Restrict access to private networks
- **dashboard-security**: Chain combining IP allowlist + auth for dashboard

#### `dynamic/tls.yml` (Dynamic Config - Hot Reloadable)
- Minimum TLS version: 1.2
- SNI strict mode enabled
- Cipher suites prioritizing ECDSA with RSA fallback

### Modifying Configuration

**Never edit these files manually!** Instead:

1. **Static config (`traefik.yml`)**: Re-run the setup script and set new environment variables
2. **Dynamic config**: Copy `.example` files, modify them, remove `.example` extension for activation
3. **Custom middlewares**: Edit `dynamic/middlewares.yml` directly; changes auto-reload

Example adding a custom middleware:

```yaml
# /opt/traefik/dynamic/custom-middleware.yml
http:
  middlewares:
    my-custom-header:
      headers:
        customRequestHeader: "MyValue"
```

Copy to `custom-middleware.yml` (remove `.example`) and apply via label:

```yaml
labels:
  - "traefik.http.routers.myapp.middlewares=my-custom-header@file,security-headers@file"
```

### Proxying Host-Local Services

To expose services running on the Docker host (not in containers):

1. Copy `dynamic/host-services.yml.example` to `dynamic/host-services.yml`
2. Edit and uncomment the router/service definitions
3. Ensure the host service binds to `0.0.0.0` (not `127.0.0.1`)

Example exposing a host media server on port 8096:

```yaml
http:
  routers:
    media:
      rule: "Host(`media.example.com`)"
      entrypoints:
        - websecure
      service: media
      tls:
        certResolver: letsencrypt
      middlewares:
        - security-headers@file

  services:
    media:
      loadBalancer:
        servers:
          - url: "http://host.docker.internal:8096"
```

---

## Useful Commands

### View Container Status

```bash
docker ps --filter name=traefik
```

### Follow Logs

```bash
docker compose -f /opt/traefik/docker-compose.yml logs -f traefik
```

### Restart Traefik (after config changes)

```bash
docker compose -f /opt/traefik/docker-compose.yml restart traefik
```

### Shell into Running Container

```bash
docker exec -it traefik sh
```

### Stop and Remove Everything

⚠️ **Warning**: This deletes containers but preserves certificates in `letsencrypt/acme.json`:

```bash
docker compose -f /opt/traefik/docker-compose.yml down
# To remove all configuration files:
rm -rf /opt/traefik
```

### Regenerate Passwords

```bash
TRAEFIK_ADMIN_USER=newadmin TRAEFIK_ADMIN_PASS=newpassword ./tasks/setup-traefik.sh
```

---

## Security Considerations

1. **acme.json Permissions**: The script sets `chmod 600` on `/opt/traefik/letsencrypt/acme.json`. Never expose this file publicly.
2. **Dashboard Access**: By default, dashboard is only accessible from private networks with basic auth. Disable IP allowlist at your own risk.
3. **Rate Limiting**: Default limits (100 req/s average) can be adjusted in `dynamic/middlewares.yml`.
4. **TLS Configuration**: Enforces TLS 1.2 minimum; cipher suites prioritize modern ECDSA algorithms.

---

## License

This setup script is provided as-is for educational and operational purposes. Ensure compliance with Let's Encrypt terms of service and applicable laws when deploying in production environments.
