# Kora Analytics API: DeployReady

My solution to the AmaliTech **DeployReady** DevOps challenge.

Kora Analytics used to deploy by hand: SSH into the server, pull the code, restart the process, with no tests and no way to know a deploy had broken something. This repository replaces that with a containerised app and an automated, tested, self-checking deployment to AWS.

**Live:** `http://34.244.170.53/health` returns `{"status":"ok"}`

The application code in `app/` is unchanged. All my work is around it.

---

## Architecture overview

```
Developer pushes to main
        │
        ▼
GitHub Actions  (.github/workflows/deploy.yml)
  1. test    npm ci + npm test (4 tests)
  2. build   docker build, tag = commit ID, push to Amazon ECR
  3. deploy  open SSH for the runner's IP only
             └─ on the server: tag current image "previous", pull new image,
                docker compose up -d --no-build
             health check http://<server>/health (10 tries)
             └─ if it fails: put "previous" back (rollback) and fail the run
             always close SSH again
        │
        ▼
AWS eu-west-1
  ECR repository  kora-analytics-api     (stores the images)
  EC2 t3.micro    deployready-server     (Ubuntu 26.04 + Docker)
    └─ container  kora-analytics-api     host port 80 → app port 3000
  Security group  deployready-sg         80 open to all, 22 my IP only
```

## What is in the repository

| File | Purpose |
|---|---|
| `Dockerfile` | Builds the app image: Node 22 on Alpine, production libraries only, runs as the non-root `node` user, reads `PORT` |
| `.dockerignore` | Keeps `node_modules`, `.env`, `.git` and `.pem` keys out of the image |
| `docker-compose.yml` | Runs the app as the `api` service: ports and `PORT` from `.env`, clean shutdown (`init`), auto-restart, Docker health check, rotated logs |
| `.env.example` | Template for the settings file (`PORT`, `HOST_PORT`). The real `.env` is never committed |
| `.github/workflows/deploy.yml` | The pipeline: test, build, push, deploy, health check, rollback |
| `DEPLOYMENT.md` | Cloud setup, IAM, how to check the container and read logs, observability, rollback bonus |

## Run it locally

Requires Docker.

```bash
cp .env.example .env          # on Windows: copy .env.example .env
docker compose up --build
```

Then open `http://localhost:3000/health`: `{"status":"ok"}`.
`docker ps` should show the container as `(healthy)` after about 30 seconds.
Stop with `Ctrl + C`, then `docker compose down`.

## Deploying

Push to `main`. The pipeline does the rest. Progress and results are in the **Actions** tab. Secrets (AWS keys, server IP, SSH key) are stored as GitHub repository secrets, never in the code. Full details are in [DEPLOYMENT.md](DEPLOYMENT.md).

---

## Decisions I made

| Decision | Choice | Why |
|---|---|---|
| Base image | `node:22-alpine` | Same Node version as development, about 150 MB instead of about 1 GB. Trade-off: Alpine uses a different C library, which this Express-only app doesn't depend on |
| Installing libraries | `npm ci --omit=dev` | Exact versions from `package-lock.json` every time, no test tools in production |
| Layer order | Copy `package*.json` and install before copying the code | Docker reuses the install layer, so code-only changes rebuild in seconds |
| User | `USER node` | The app doesn't run as root, so an attacker who breaks in gets very limited powers |
| Start command | `CMD ["node", "index.js"]` plus `init: true` | Node as PID 1 ignored stop signals (I saw Ctrl + C fail); Docker's init helper passes them on so the container stops cleanly |
| `.dockerignore` | `**/node_modules` | A plain `node_modules` missed `app/node_modules`; I spotted it because the build context was 27 MB instead of 172 B |
| Ports | `${HOST_PORT}:${PORT}` from `.env` | One compose file: 3000 on laptops (the brief), 80 on the server (the server's own `.env`) |
| Cloud | AWS EC2 + ECR, Ubuntu LTS | Existing account with credits; Docker installs with one command on Ubuntu |
| Registry access | IAM user (push only) + IAM role on the server (pull only) | Least privilege: each identity can touch only the one repository; the server holds no keys |
| SSH from the pipeline | Open port 22 for the runner's `/32` during the deploy, always close it after | Keeps SSH "my IP only" while still letting GitHub deploy |
| Image labels | Commit ID for every build, `previous` / `latest` on the server | Every image is traceable to its code, and rollback always knows what to go back to |
| Bonus | Automatic rollback, **tested** by deploying a deliberately broken image (Actions run #5) | A rollback you've never seen work is only a hope |

## What I would improve next

- Use **GitHub OIDC** instead of a long-lived AWS access key.
- Add a **CloudWatch alarm** on `/health` that emails when the service is down.
- Give the server an **Elastic IP** so its address survives a stop/start.
- Use **AWS Systems Manager** instead of SSH for deploys, removing the SSH door completely.
- Define the server and firewall with **Terraform**.
