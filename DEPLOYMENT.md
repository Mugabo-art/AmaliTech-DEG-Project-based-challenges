# Deployment

How the Kora Analytics API is deployed: from a push on GitHub to a running container on AWS.

**Live health check:** `http://34.244.170.53/health` returns `{"status":"ok"}`

---

## 1. Cloud provider and service, and why

| What | Choice | Why |
|---|---|---|
| Cloud provider | **AWS** | I already had an account with free-plan credits, and AWS is widely used |
| Server | **EC2 `t3.micro`** in **eu-west-1 (Ireland)** | Free-tier eligible, enough for a small Node.js API; Ireland is one of the closer AWS regions to Rwanda |
| Operating system | **Ubuntu 26.04 LTS** | Docker and Docker Compose install with one command; long-term security updates; lots of documentation |
| Image registry | **Amazon ECR** (private repository `kora-analytics-api`) | Lives in the same AWS account, so access is controlled with IAM |

## 2. How I set up the virtual machine

Everything was done in the AWS console.

1. **Launched an EC2 instance** named `deployready-server`: Ubuntu 26.04 LTS, `t3.micro`, 8 GiB disk, a new key pair `deployready-key` (`.pem`, kept outside the repository).
2. **Created a firewall (security group) `deployready-sg`** with only two inbound rules:

| Port | Protocol | Source | Why |
|---|---|---|---|
| 80 | HTTP | `0.0.0.0/0` (everyone) | The public web door to the API |
| 22 | SSH | my own IP only (`x.x.x.x/32`) | Admin login; never open to the world |

3. **Created least-privilege IAM identities** (details in section 6).
4. **Attached the IAM role** `deployready-ec2-role` to the instance, so the server can download images without storing any AWS keys.

> Note: my home internet address changes from time to time. When it does, I update the SSH rule's source to my new `/32` address. The pipeline is not affected (it opens its own temporary access, see "The pipeline" below).

## 3. How I installed Docker and pulled the image

On the server (logged in with `ssh -i deployready-key.pem ubuntu@34.244.170.53`):

```bash
# Install Docker and Docker Compose
sudo apt update
sudo apt install -y docker.io docker-compose-v2
sudo docker run hello-world            # check Docker works

# Install the AWS command-line tool (used to log in to ECR)
sudo snap install aws-cli --classic
aws sts get-caller-identity            # shows the server is using deployready-ec2-role

# Get the project (for docker-compose.yml) and create the server's own .env
git clone https://github.com/Mugabo-art/AmaliTech-DEG-Project-based-challenges.git
cd AmaliTech-DEG-Project-based-challenges
echo "PORT=3000" > .env
echo "HOST_PORT=80" >> .env             # outside port 80 on the server, 3000 on laptops
```

Pulling and running the image is done by the pipeline on every deploy. By hand it is:

```bash
aws ecr get-login-password --region eu-west-1 | sudo docker login --username AWS --password-stdin 413724559765.dkr.ecr.eu-west-1.amazonaws.com
sudo docker pull 413724559765.dkr.ecr.eu-west-1.amazonaws.com/kora-analytics-api:<commit-id>
sudo docker tag 413724559765.dkr.ecr.eu-west-1.amazonaws.com/kora-analytics-api:<commit-id> kora-analytics-api:latest
sudo docker compose up -d --no-build
```

## 4. How to check the container is running

```bash
sudo docker compose ps
```

The `STATUS` column should say `Up ... (healthy)`. `(healthy)` comes from the Docker health check in `docker-compose.yml`, which calls `/health` inside the container every 30 seconds.

From anywhere:

```bash
curl http://34.244.170.53/health       # {"status":"ok"}
```

## 5. How to view the application logs

```bash
cd ~/AmaliTech-DEG-Project-based-challenges
sudo docker compose logs api --tail 100   # last 100 lines
sudo docker compose logs api -f           # follow live (Ctrl + C to stop)
sudo docker compose logs api --since 1h   # only the last hour
```

Logs are stored on disk by Docker (`json-file` driver) and rotated: at most 3 files of 10 MB, so they can be reviewed later without ever filling the disk.

---

## The pipeline (`.github/workflows/deploy.yml`)

Runs on every push to `main`. Three jobs; each only starts if the previous one passed.

| Job | What it does |
|---|---|
| **test** | Installs Node 22 and the exact libraries (`npm ci`), runs the 4 tests |
| **build** | Logs in to AWS, builds the image, labels it with the commit ID, pushes it to ECR |
| **deploy** | Opens SSH for the runner's own IP, logs in to the server, tags the running image `previous`, pulls the new image, restarts with `docker compose up -d --no-build`, runs a health check, rolls back if needed, and **always** closes SSH again |

**GitHub secrets used (nothing secret is in the code):**

| Secret | Contains |
|---|---|
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | Keys of the `github-actions-deployready` IAM user |
| `EC2_HOST` | The server's public IP |
| `EC2_SSH_KEY` | The private key used to log in to the server |

**How SSH stays "my IP only" while GitHub deploys:** the deploy job adds a port 22 rule for the runner's own address (`/32`), deploys, then removes it in a step that runs even if earlier steps failed (`if: always()`).

## 6. IAM: least privilege

| Identity | Used by | Allowed to do | Nothing else |
|---|---|---|---|
| IAM user `github-actions-deployready` | GitHub Actions | Log in to ECR; upload images to the `kora-analytics-api` repository only; add/remove inbound rules on `deployready-sg` only | No console access, no other services |
| IAM role `deployready-ec2-role` | The EC2 server | Log in to ECR; download images from the `kora-analytics-api` repository only | No keys stored on the server at all |

The `root` account is only used by me in the console. It has MFA and no access keys.

---

## Bonus: automatic rollback

I chose the rollback bonus. Before each deploy the running image is tagged `previous`. If the health check (10 tries, 3 seconds apart) fails after the deploy, the pipeline tags `previous` back to `latest`, restarts the app, and the workflow ends **failed** so the team is alerted.

**Tested on purpose (run #5):** I changed the Dockerfile's start command to a file that does not exist. Tests and build passed, the container crashed, the health check failed 10 times, the rollback ran, and `/health` returned `{"status":"ok"}` again about 30 seconds later. Run #6 restored the correct command.

---

## Observability

### Logs
Docker keeps the app's output on disk with rotation (3 × 10 MB). Read them with `sudo docker compose logs api` (see section 5).

### Health checks (monitoring signals)
1. **Docker health check:** every 30 seconds Docker calls `/health` inside the container. `docker compose ps` shows `healthy` or `unhealthy`.
2. **Pipeline health check:** after every deploy, GitHub calls `http://<server>/health` from outside. Failure triggers the rollback and fails the workflow.
3. **`/metrics` endpoint:** `curl http://34.244.170.53/metrics` shows uptime and memory use.

### How to spot problems

| Problem | How I would spot it |
|---|---|
| **Failed deployment** | The run is red in the GitHub **Actions** tab and GitHub emails the person who pushed. The deploy job shows which step failed; if it was the health check, the rollback step ran and the previous version is live |
| **Crash** | `sudo docker compose ps` shows `Restarting` or `unhealthy` instead of `Up (healthy)`; `curl /health` fails; `/metrics` shows uptime reset to a few seconds; the last lines of `sudo docker compose logs api` show the error |
| **Rising error rates** | Count error lines over time, e.g. `sudo docker compose logs api --since 1h \| grep -ci error`, and compare with the hour before. Watch for growing memory in `/metrics` |

### What I would add next
A **CloudWatch alarm** (or an uptime checker) that calls `/health` every minute and sends an email when it fails, so problems are noticed even when nobody is deploying.
