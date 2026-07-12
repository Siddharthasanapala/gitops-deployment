# Enterprise-Style CI/CD Deployment Plan (Minikube + Jenkins + ArgoCD + Helm)

**Status:** Planning document only. Nothing in this plan has been implemented yet — no manifests,
no Helm chart, no Jenkinsfile exist in this folder yet. We implement phase by phase, in a
follow-up session, only after this plan is reviewed.

**Goal:** Learn (not just use) a realistic enterprise CI/CD loop, entirely on free/local
resources: Jenkins builds and tests the app and pushes an image, a **separate GitOps repo**
holds the desired state, and **ArgoCD** pulls from that repo and reconciles a local **Minikube**
cluster — deployed two ways (plain Kubernetes YAML *and* a Helm chart) so both approaches are
exercised side by side.

---

## 0. How this plan is organized

1. Decisions & why (the "why" matters more than the "how" for a learning project)
2. Two-repo strategy (this repo vs. the new GitOps repo)
3. Architecture diagram (full automated flow)
4. Tool inventory & Windows-specific prerequisites
5. Target folder/file layout (what we'll build, later, phase by phase)
6. Phase-by-phase implementation plan (10 phases)
7. Consolidated bottlenecks & edge-case analysis (the part that actually matters at this scale)
8. Secrets strategy
9. Rollback strategy
10. Acceptance checklist for this deployment project itself
11. Command cheat-sheet appendix

---

## 1. Decisions & why

| Decision | Choice | Why |
|---|---|---|
| Cluster | Minikube, `docker` driver | You already run Docker Desktop for this project's own `docker-compose.yml`; the `docker` driver reuses it — no Hyper-V/VirtualBox needed. |
| CI | Jenkins, as a Docker container on the host (outside the cluster) | Matches your explicit ask; keeps CI credentials (registry, git) out of the cluster entirely — CI never touches `kubectl`. |
| CD | ArgoCD, inside the cluster | Pull-based GitOps: the cluster reconciles itself from git, nobody ever runs `kubectl apply`/`helm upgrade` by hand against a "production" namespace. |
| Registry | GHCR (`ghcr.io`) | Free, no anonymous-pull rate limit (unlike Docker Hub's 100 pulls/6h), and reuses the same GitHub PAT you'll already need for the GitOps repo. |
| Manifest formats | Both plain YAML **and** Helm, as two separate ArgoCD Applications in two separate namespaces | You explicitly asked for both, for learning. They must not fight over the same objects — see §7.3. |
| Image tag bump | Jenkins commits the new tag into the GitOps repo (classic push-CI/pull-CD split) | This is the pattern that teaches the full loop end-to-end, rather than ArgoCD Image Updater doing it invisibly (mentioned as an optional later enhancement in §6, Phase 11). |
| Ingress | `ingress-nginx` via `minikube addons enable ingress` + `minikube tunnel` | Closest to how a real cluster is reached (hostname + Ingress), avoids NodePort-only URLs. |
| Secrets | Manual `kubectl create secret` for the fast path; Sealed Secrets for the "do it properly" path | A real GitOps repo must never contain plaintext secrets — see §8. |

---

## 2. Two-repo strategy

- **`siddhartha-portfolio`** (this repo, existing GitHub remote, branch `siddhu`) — application source
  code + `Dockerfile`. Jenkins checks this out to build/test/push the image. It does **not**
  contain Kubernetes manifests.
- **`portfolio-gitops`** (new repo, to be created on GitHub) — the only thing ArgoCD ever looks
  at. Contains `k8s/raw/*.yaml`, `helm/portfolio/*`, and the two ArgoCD `Application` objects.
  Jenkins pushes commits here (bumping the image tag); nothing else pushes here.

This folder (`gitops-deploy/`) lives inside the app repo **for now**, purely so it's easy to draft
and review in one place. Before Phase 6 (installing ArgoCD), we'll turn it into its own repo:

```bash
cd gitops-deploy
git init
git remote add origin https://github.com/<you>/portfolio-gitops.git
git add .
git commit -m "initial GitOps repo layout"
git push -u origin main
```

I've already added `gitops-deploy/` to this repo's root `.gitignore` (see §4.4) so the app repo
never tracks it once it becomes its own independent `.git`. Two separate physical folders
(`d:\siddhartha-portfolio` and, say, `d:\portfolio-gitops`) also works and is arguably cleaner —
your call when we get to Phase 1; nothing here depends on which you pick.

---

## 3. Architecture — fully automated flow

```mermaid
flowchart LR
    DEV["Developer\n(you)"] -->|git push| APPREPO[("GitHub\nsiddhartha-portfolio\n(app source)")]

    subgraph JENKINS["Jenkins — Docker container on host (CI only, no cluster access)"]
        direction TB
        POLL["SCM poll / webhook"] --> LINT["npm ci · lint · tsc\n(agent: node:20-alpine)"]
        LINT --> DBUILD["docker build\n(agent: Jenkins controller,\ndocker.sock mounted)"]
        DBUILD --> DPUSH["docker push :sha + :latest"]
        DPUSH --> BUMP["clone GitOps repo,\nsed image tag,\ngit commit + push"]
    end

    APPREPO -->|poll every N min\n(or webhook via tunnel)| POLL
    DPUSH --> REGISTRY[("ghcr.io\nportfolio image")]
    BUMP -->|git push| GITOPS[("GitHub\nportfolio-gitops\n(k8s/ + helm/)")]

    subgraph CLUSTER["Minikube cluster"]
        direction TB
        subgraph ARGOCD["ArgoCD (ns: argocd)"]
            SYNCRAW["Application: portfolio-raw\n(kubectl-style YAML)"]
            SYNCHELM["Application: portfolio-helm\n(Helm chart)"]
        end
        SYNCRAW -->|apply| NSRAW["ns: portfolio-raw\nDeployment/Service/Ingress"]
        SYNCHELM -->|helm template + apply| NSHELM["ns: portfolio-helm\nDeployment/Service/Ingress"]
        NSRAW --> ING["ingress-nginx"]
        NSHELM --> ING
    end

    GITOPS -->|poll every 3min\n(or webhook)| SYNCRAW
    GITOPS --> SYNCHELM
    REGISTRY -.image pull by kubelet.-> NSRAW
    REGISTRY -.image pull by kubelet.-> NSHELM
    ING -->|minikube tunnel\n+ hosts file| BROWSER["Browser\nportfolio-raw.local\nportfolio-helm.local"]
```

Read it as two independent loops glued by git, not by any direct network call:

1. **CI loop (push-based):** code change → Jenkins builds, tests, containerizes, pushes an
   image, then makes a *second* commit — to a *different* repo — bumping the tag that repo
   references. Jenkins's job ends there. It never talks to the cluster.
2. **CD loop (pull-based):** ArgoCD independently notices the GitOps repo changed (polling or
   webhook), diffs desired vs. live state, and applies the difference. It never talks to
   Jenkins.

If you only remember one thing from this plan, remember that split — it's the entire point of
GitOps, and it's what makes this "enterprise-style" rather than "a script that runs
`kubectl apply`."

---

## 4. Tool inventory & prerequisites

### 4.1 Install on the Windows host

| Tool | Install (Windows) | Used for |
|---|---|---|
| Docker Desktop | already installed | Minikube's `docker` driver, Jenkins container, image builds |
| `kubectl` | `choco install kubernetes-cli` (or Docker Desktop's bundled one) | talking to the minikube cluster |
| `minikube` | `choco install minikube` | the local cluster |
| `helm` | `choco install kubernetes-helm` | packaging + rendering the Helm chart |
| `argocd` CLI | `choco install argocd-cli` (optional — UI + `kubectl` are enough) | scripted ArgoCD operations |
| `git` | already installed | both repos |
| `kubeseal` (optional) | matches whatever Sealed Secrets controller version we install | encrypting secrets for the GitOps repo — see §8 |

If `choco` isn't installed, each tool also ships a direct Windows binary/installer from its own
project — we'll pin exact install commands when we execute Phase 1, rather than baking a
version number into this plan that will be stale by the time we run it.

### 4.2 Resource budget (this matters more than it sounds like)

Minikube's `docker` driver runs the entire cluster as one Docker Desktop container, sized by
`--cpus`/`--memory` flags at `minikube start` time, drawn from whatever Docker Desktop itself is
allowed to use (Settings → Resources). On top of that we're running:

- Jenkins container (JVM — budget ~1–2 GB)
- ArgoCD (several controller pods inside the cluster)
- The portfolio app itself, **twice** (once in `portfolio-raw`, once in `portfolio-helm`)
- Whatever you already had running (per `docker ps -a`, this machine also has an idle
  Prometheus/Grafana/Loki/Alertmanager/Fluent-bit/Alloy stack from a different project — currently
  stopped, but if you start those too, budget for them separately)

**Recommendation:** give Docker Desktop at least 8 GB RAM / 4 CPUs in its own settings, then
start minikube with `--cpus=4 --memory=6144` (leaves headroom for Jenkins + host OS). If your
machine has less than 16 GB total RAM, drop the second (`portfolio-helm`) namespace until the
raw-YAML path is working, to reduce concurrent load — see §7.6.

### 4.3 A concrete port collision, specific to this repo

This repo's own `docker-compose.yml` (Phase 6, already built) runs a `caddy` service bound to
host ports **80 and 443**. `minikube tunnel` (§6, Phase 5) *also* wants to bind 80/443 on
`localhost` to route to `ingress-nginx`. **Don't run both at once.** Before starting
`minikube tunnel`, stop the compose stack's `caddy` service (`docker compose stop caddy` — the
`portfolio` app service on port 3000 can keep running, it doesn't conflict). We already stopped
`caddy` at the end of the last session for exactly this reason.

### 4.4 `.gitignore` change made now

Added to this repo's root `.gitignore`:

```gitignore
# GitOps folder is planned to become its own independent git repo (ArgoCD source) —
# never tracked from the app repo, to avoid nested-.git confusion.
/gitops-deploy/
```

This only takes effect once `gitops-deploy/` actually contains its own `.git` (or you move it
out entirely); until then it's harmless for this doc to live there and be reviewed via the IDE.

---

## 5. Target folder/file layout (built phase by phase, not yet)

```
gitops-deploy/                       (→ becomes its own repo: portfolio-gitops)
├── DEPLOYMENT.md                    (this file)
├── k8s/
│   └── raw/
│       ├── namespace.yaml
│       ├── deployment.yaml
│       ├── service.yaml
│       ├── ingress.yaml
│       ├── configmap.yaml
│       └── secret.example.yaml      (placeholder shape only — never real values, never applied from here)
├── helm/
│   └── portfolio/
│       ├── Chart.yaml
│       ├── values.yaml              (image.repository / image.tag / ingress.host / resources / replicaCount)
│       ├── templates/
│       │   ├── _helpers.tpl
│       │   ├── deployment.yaml
│       │   ├── service.yaml
│       │   ├── ingress.yaml
│       │   ├── configmap.yaml
│       │   ├── secret.yaml
│       │   └── hpa.yaml             (optional, disabled by default)
│       └── .helmignore
├── argocd/
│   ├── application-raw.yaml         (Application CR → k8s/raw, ns portfolio-raw)
│   └── application-helm.yaml        (Application CR → helm/portfolio, ns portfolio-helm)
└── jenkins/
    ├── Dockerfile.jenkins           (jenkins/jenkins:lts + docker-cli, so pipeline can `docker build`)
    └── Jenkinsfile                  (lives here for reference; the *real* one Jenkins runs is
                                       fetched from the APP repo, since that's what "CI checks out
                                       its own pipeline definition" means in practice — see Phase 8)
```

---

## 6. Phase-by-phase implementation plan

Each phase has an explicit **Done when** so we know when to move on — same discipline as the
main build's roadmap.

### Phase 1 — Minikube cluster
- `minikube start --driver=docker --cpus=4 --memory=6144 --addons=ingress,metrics-server`
- `minikube addons enable ingress` (if not already via `--addons`)
- `minikube addons enable metrics-server` (needed only if we add HPA later)
- Sanity check: `kubectl get nodes`, `kubectl get pods -A`
- **Done when:** `kubectl get nodes` shows `Ready`, `ingress-nginx-controller` pod is `Running`.

### Phase 2 — Container registry
- Create a GitHub PAT with `write:packages`, `read:packages`, `repo` scopes (the `repo` scope is
  also what Jenkins will use to push to the GitOps repo — one PAT, two uses, stored as two
  separate Jenkins credentials so each pipeline step only requests what it needs).
- First push can happen manually to prove the registry path before Jenkins exists:
  `docker build -t ghcr.io/<you>/siddhartha-portfolio:manual-test .`
  `docker login ghcr.io -u <you> --password-stdin` (paste PAT)
  `docker push ghcr.io/<you>/siddhartha-portfolio:manual-test`
- Set the GHCR package visibility to **public** (Package settings on github.com) — sidesteps
  needing an `imagePullSecret` in the cluster entirely, simplest for a learning project. (The
  "properly private" path is documented in §7.9 if you'd rather practice that instead.)
- **Done when:** the manually-pushed image is visible and pullable anonymously
  (`docker pull ghcr.io/<you>/siddhartha-portfolio:manual-test` from a clean shell).

### Phase 3 — Raw Kubernetes manifests
- `namespace.yaml` — `portfolio-raw`
- `deployment.yaml` — 1 replica to start, resource requests/limits, `livenessProbe`/
  `readinessProbe` both `httpGet: /api/health` on port 3000 (this endpoint already exists and is
  exactly what the Docker `HEALTHCHECK` already uses — reuse it, don't invent a new one),
  `envFrom: secretRef` for the app's env vars.
- `service.yaml` — `ClusterIP`, port 80 → targetPort 3000.
- `ingress.yaml` — host `portfolio-raw.local`, backend = the Service above.
- `configmap.yaml` — only for genuinely non-secret config (e.g. `NODE_ENV=production`); actual
  secrets (`GEMINI_API_KEY`, `RESEND_API_KEY`, SMTP vars, `CONTACT_EMAIL`, `SITE_URL`) go in a
  `Secret`, created per §8 — **not** committed as plaintext YAML.
- Apply manually first (before ArgoCD exists) to prove the manifests work in isolation:
  `kubectl apply -f k8s/raw/` (with a manually-created Secret already in place).
- **Done when:** `kubectl port-forward svc/portfolio -n portfolio-raw 3000:80` and
  `curl localhost:3000/api/health` returns `{"status":"ok"}`.

### Phase 4 — Helm chart (same app, parametrized)
- `helm create` scaffold, then strip the demo boilerplate down to exactly the same 5 objects as
  Phase 3, but templated: `values.yaml` exposes `image.repository`, `image.tag`, `replicaCount`,
  `resources`, `ingress.host` (default `portfolio-helm.local`), `secretName`.
- `helm lint helm/portfolio`
- `helm template helm/portfolio` — diff the rendered output against the Phase 3 raw YAML by eye;
  they should be equivalent (same probes, same ports, same env wiring) — this is the actual
  learning exercise, seeing the same infrastructure expressed both ways.
- `helm install portfolio-helm helm/portfolio -n portfolio-helm --create-namespace` to prove it
  installs standalone, same as Phase 3's manual `kubectl apply` check.
- **Done when:** same `curl .../api/health` check passes against the Helm-installed copy, in its
  own namespace, without touching the raw-YAML copy.

### Phase 5 — Ingress + hosts file (make both reachable by name)
- `minikube tunnel` in its own elevated terminal (keep it running — it's foreground-only).
- Edit `C:\Windows\System32\drivers\etc\hosts` (as Administrator) to add:
  ```
  127.0.0.1 portfolio-raw.local
  127.0.0.1 portfolio-helm.local
  ```
- Browse both hostnames.
- **Done when:** both hostnames load the site in a browser, independently, at the same time.

### Phase 6 — ArgoCD install
- `kubectl create namespace argocd`
- `kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml`
- `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d`
- `kubectl port-forward svc/argocd-server -n argocd 8080:443` → https://localhost:8080
- (optional) `argocd login localhost:8080 --username admin --password <pw> --insecure`
- **Done when:** you can log into the ArgoCD UI.

### Phase 7 — Turn `gitops-deploy/` into its own repo, push it
- As shown in §2. Push the Phase 3/4 content (manifests + chart) that we already proved works
  by hand.
- **Done when:** `portfolio-gitops` exists on GitHub with `k8s/raw/` and `helm/portfolio/` in it.

### Phase 8 — ArgoCD `Application` objects (this is where "GitOps" actually starts)
- Delete the manually-created resources from Phases 3/4 first (`kubectl delete ns portfolio-raw
  portfolio-helm`) — the whole point from here on is that ArgoCD creates everything, nothing is
  ever `kubectl apply`'d by a human again.
- Apply `argocd/application-raw.yaml` and `argocd/application-helm.yaml` (both target
  `portfolio-gitops`, `targetRevision: main`, `syncPolicy.automated: {prune: true, selfHeal:
  true}`, `syncOptions: [CreateNamespace=true]`).
- **Done when:** both Applications show `Synced` + `Healthy` in the ArgoCD UI, and both
  hostnames from Phase 5 load again — this time entirely because ArgoCD created them, not
  because you ran `kubectl apply`.

### Phase 9 — Jenkins
- Build `jenkins/Dockerfile.jenkins` (base `jenkins/jenkins:lts` + Docker CLI installed, so
  pipeline steps that need `docker build`/`docker push` on the controller agent work against
  the mounted host socket).
- `docker volume create jenkins_home`
- `docker run -d --name jenkins -p 8080:8080 -p 50000:50000 -v jenkins_home:/var/jenkins_home -v /var/run/docker.sock:/var/run/docker.sock <built-image>`

  ⚠️ Port 8080 — check nothing else on this host already uses it before running this.
- Unlock (initial admin password from `docker logs jenkins`), install suggested plugins +
  **Docker Pipeline**, **Pipeline: Groovy**, **Credentials Binding**, **Git**.
- Add credentials: `ghcr-creds` (GHCR username + PAT), `gitops-repo-creds` (GitHub username +
  PAT for `portfolio-gitops`).
- Create a Pipeline job pointed at the **app repo**, Pipeline script from SCM,
  `Jenkinsfile` path (we author this in the app repo, not in `gitops-deploy/` — see the note in
  §5's file tree).
- **Done when:** a manually-triggered build succeeds end-to-end once, using a real code change.

### Phase 10 — Wire up automatic triggering + verify the full loop
- Simplest: Poll SCM, e.g. `H/5 * * * *` (every ~5 min) on the Jenkins job, pointed at the app
  repo's `siddhu` branch.
- Stretch goal (optional, see §7.11): real GitHub webhook via `ngrok http 8080` or a Cloudflare
  Tunnel, so a `git push` triggers Jenkins within seconds instead of up to 5 minutes later.
- **Done when:** make a trivial, visible change (e.g. edit hero description text), push it,
  and — with zero manual `kubectl`/`docker`/`helm` commands from you — watch it appear at
  `portfolio-raw.local`/`portfolio-helm.local` on its own, driven only by: Jenkins polls → builds
  → pushes image → bumps GitOps repo → ArgoCD notices → syncs.

This last step is the actual deliverable of the whole exercise — the rest of this plan exists to
get here without any of the bottlenecks in §7 silently breaking it.

---

## 7. Bottlenecks & edge-case analysis

This is the part you specifically asked for — the failure modes that don't show up until you're
mid-implementation, gathered up front instead of hit one at a time.

### 7.1 Docker Desktop is the one thing everything shares
Minikube (`docker` driver), the Jenkins container, and every image build all go through the same
Docker Desktop engine. If Docker Desktop restarts (it's done so before, mid-session, per this
project's own history), *everything* — minikube's node, Jenkins, ArgoCD's pods — goes down
together and needs `minikube start` / `docker start jenkins` again. There's no way around this
locally; just don't be surprised by it. `restart: unless-stopped`-equivalent for the raw `docker
run` Jenkins container is `--restart unless-stopped`, worth adding.

### 7.2 Jenkins can't build images with the stock image
`jenkins/jenkins:lts` has no Docker CLI baked in. Mounting `/var/run/docker.sock` alone isn't
enough — the container also needs the `docker` binary to talk to that socket ("Docker outside of
Docker" / DooD pattern). Hence `jenkins/Dockerfile.jenkins` in the layout above. The alternative
—full Docker-in-Docker via a `docker:dind` sidecar—is heavier and unnecessary for a
single-host learning setup; DooD is the right call here.

### 7.3 Raw-YAML and Helm paths **will** collide if not deliberately separated
If both ArgoCD Applications tried to own a `Deployment` named `portfolio` in the same namespace,
they'd fight — each `selfHeal` reverting the other's changes, endless out-of-sync flapping. This
plan avoids it structurally: **different namespaces** (`portfolio-raw` vs `portfolio-helm`) and
different Ingress hostnames. Don't "simplify" this later by pointing both at one namespace —
that's the one shortcut in this plan that isn't actually a shortcut.

### 7.4 `minikube tunnel` vs. this repo's own Caddy — same host ports
Covered in §4.3. This is the single most likely "why isn't anything loading" moment, because
both processes fail *silently enough* — one just won't bind, or you'll get traffic routed to the
wrong place — rather than erroring clearly.

### 7.5 Windows hosts-file editing needs admin rights
Notepad (or your editor) must be run **as Administrator** to save
`C:\Windows\System32\drivers\etc\hosts`. A silent save failure here looks identical to a DNS/
ingress problem and wastes time in the wrong place if you don't check this first.

### 7.6 Resource contention compounds fast
Two full copies of the same Next.js app (raw + Helm namespaces) plus ArgoCD's own controller
pods plus Jenkins is a lot for a laptop-class machine. If pods start `CrashLoopBackOff` or get
`Evicted`, check `kubectl top nodes` / `kubectl describe node` for memory pressure before
assuming it's an app bug. If tight on resources, do Phases 1–3 and 6–10 with **only** the raw-YAML
path first, add the Helm path (Phase 4) as a second, later pass once the loop is proven once.

### 7.7 Two independent CI systems would conflict
This repo already has `.github/workflows/docker-publish.yml` (a GitHub Actions workflow that
builds and pushes to GHCR on every push to `main`, from Phase 6 of the main build). If that stays
enabled *and* Jenkins also builds/pushes on every push, you get two independent, possibly
racing, image builds with two different ideas of what `:latest` means, and nothing bumping the
GitOps repo from the Actions side. **Before Phase 9:** disable that workflow (delete the file, or
rename it `.disabled`, or restrict its trigger to something Jenkins doesn't also cover, e.g. only
run it manually) so Jenkins is the single source of CI truth for this exercise.

### 7.8 Rate limiting and any per-process caches assume one replica
`lib/rateLimit.ts` already documents this: it's an in-memory `Map`, correct for a single
container, and would silently under-enforce (each pod gets its own counter) the moment
`replicaCount`/HPA scales the Deployment past 1. Not a blocker for this learning project (keep
`replicaCount: 1`), but don't add an HPA that scales this Deployment without also swapping this
for a shared store (Redis) — otherwise it *looks* like it's working (no errors) while silently
not rate-limiting correctly across pods.

### 7.9 Registry auth if you don't make the GHCR package public
The plan defaults to a public GHCR package specifically to skip this, but if you'd rather
practice the "real enterprise" private-registry path instead: create an `imagePullSecret` —
```bash
kubectl create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io --docker-username=<you> --docker-password=<PAT> \
  -n portfolio-raw
```
— and reference it via `imagePullSecrets:` on the Deployment's pod spec (and the equivalent
`values.yaml` field in the Helm chart). This has to be created in **every namespace** that pulls
the image (once per namespace, not once per cluster) — a common surprise the first time someone
hits `ImagePullBackOff` despite "already having" the secret, just in the wrong namespace.

### 7.10 ArgoCD's Helm support ≠ the `helm` CLI's release history
ArgoCD renders Helm charts via `helm template` and applies the output directly — it does not
maintain a `helm` CLI release object. That means `helm rollback` won't do anything useful for an
ArgoCD-managed Helm app; **ArgoCD's own rollback/history view is the one that matters** once
Phase 8 is live (see §9). Only while manually `helm install`-ing in Phase 4, before ArgoCD owns
it, does the `helm` CLI's own history apply.

### 7.11 Jenkins can't receive real GitHub webhooks without extra infra
Jenkins running locally has no public URL, so GitHub can't push webhook events to it directly.
Poll SCM (Phase 10's default) is simplest and needs nothing extra, at the cost of up to
~5 minutes of latency. If you want the "instant trigger" enterprise feel, `ngrok http 8080` (or a
Cloudflare Tunnel) gives Jenkins a temporary public URL to register as a GitHub webhook target —
optional, and something to revisit once the polling-based loop is proven, not before.

### 7.12 Bumping the GitOps repo must not re-trigger the same Jenkins job
The Jenkins job polls the **app** repo, not the GitOps repo, so this isn't a loop by
construction — but if you later add a second Jenkins job that also watches
`portfolio-gitops` for some reason, make sure it filters out commits authored by Jenkins itself
(check the commit author / a `[skip ci]`-style marker), or you'll get an infinite build loop.

### 7.13 Secrets must never land in `portfolio-gitops` as plaintext
Elaborated in §8 — called out here too because it's the most consequential mistake possible in
this plan (a public or even "private-but-someday-made-public" GitHub repo with a live
`GEMINI_API_KEY`/`RESEND_API_KEY` in its commit history).

### 7.14 Env-var naming must match exactly
The Kubernetes `Secret`'s keys must be named identically to what the app reads via
`process.env.*` — `GEMINI_API_KEY`, `RESEND_API_KEY`, `CONTACT_EMAIL`, `SITE_URL`, `SMTP_HOST`,
`SMTP_PORT`, `SMTP_USER`, `SMTP_PASS`, `NODE_ENV` — same list as `.env`/`.env.example` today.
Nothing new is needed; this is a direct port, not a redesign.

### 7.15 `output: 'standalone'` needs no changes for Kubernetes
The existing `Dockerfile` already produces a self-contained `node server.js` binding to
`0.0.0.0:3000` — it's already exactly what a Kubernetes `Deployment` wants. No Dockerfile changes
are needed for this whole plan; the same image serves docker-compose and Kubernetes identically.

---

## 8. Secrets strategy

Two tiers, pick based on how much of the "enterprise" experience you want:

**Fast path (fine for a learning cluster you fully control):**
```bash
kubectl create secret generic portfolio-secrets -n portfolio-raw \
  --from-env-file=.env
kubectl create secret generic portfolio-secrets -n portfolio-helm \
  --from-env-file=.env
```
Run once per namespace, directly against the cluster, **never committed to `portfolio-gitops`**.
ArgoCD is fine with a `Secret` existing that it doesn't manage, as long as nothing in the synced
manifests tries to *also* define that same object (reference it by name via `envFrom.secretRef`,
don't template it).

**"Do it properly" path (what a real enterprise GitOps setup uses):**
Install the [Bitnami Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) controller
(check its GitHub releases page for the current version/manifest URL at implementation time —
deliberately not pinning a version here so this plan doesn't go stale), then:
```bash
kubectl create secret generic portfolio-secrets -n portfolio-raw \
  --from-env-file=.env --dry-run=client -o yaml | kubeseal --format yaml > sealed-secret.yaml
```
The resulting `sealed-secret.yaml` is ciphertext — safe to commit to `portfolio-gitops`, decryptable
only by the Sealed Secrets controller running in *this* cluster. This is the version worth doing
if the goal is to practice the real pattern, not just make the app run.

Either way: `.env` itself is never committed anywhere (already true today, already gitignored).

---

## 9. Rollback strategy

- **GitOps repo revert:** `git revert <bad-commit>` on `portfolio-gitops`, push — ArgoCD's
  `selfHeal` picks it up and reconciles back automatically. This is the primary rollback
  mechanism for everything ArgoCD manages (both the raw and Helm apps).
- **ArgoCD UI/CLI:** the `Application`'s History & Rollback view (or `argocd app rollback
  <app> <history-id>`) re-applies a previous synced revision without needing a new git commit —
  useful for an immediate rollback while you're still writing the revert commit.
- **Image-level rollback:** since Jenkins tags images with both the git SHA and `:latest`, any
  previous SHA-tagged image is still pullable from GHCR — a manifest revert to an older SHA tag
  always has a real image behind it, nothing gets garbage collected by default.

---

## 10. Acceptance checklist for this deployment project

- [ ] `kubectl get applications -n argocd` shows both apps `Synced`/`Healthy`
- [ ] `portfolio-raw.local` and `portfolio-helm.local` both load independently
- [ ] A push to the app repo results in the new content live at both hostnames with **zero**
      manual `kubectl`/`docker`/`helm` commands
- [ ] `kubectl delete pod` on either app's pod self-heals (new pod, same result) without ArgoCD
      intervention needed
- [ ] A deliberate bad commit to `portfolio-gitops`, then `git revert`, restores the working
      state automatically
- [ ] No secret value appears anywhere in `portfolio-gitops`'s git history
- [ ] `.github/workflows/docker-publish.yml` disabled or scoped so it no longer races Jenkins
- [ ] Jenkins job triggers automatically (poll or webhook) without a human clicking "Build Now"

---

## 11. Command cheat-sheet (for quick reference during implementation)

```bash
# Cluster
minikube start --driver=docker --cpus=4 --memory=6144
minikube addons enable ingress
minikube addons enable metrics-server
minikube tunnel                      # separate, elevated, foreground terminal

# ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Jenkins
docker volume create jenkins_home
docker run -d --name jenkins --restart unless-stopped \
  -p 8080:8080 -p 50000:50000 \
  -v jenkins_home:/var/jenkins_home \
  -v /var/run/docker.sock:/var/run/docker.sock \
  <your-custom-jenkins-image>

# Helm
helm lint helm/portfolio
helm template helm/portfolio
helm install portfolio-helm helm/portfolio -n portfolio-helm --create-namespace

# Debugging
kubectl get applications -n argocd
kubectl describe application portfolio-raw -n argocd
kubectl top nodes
kubectl get events -A --sort-by=.lastTimestamp
```

---

## Next step

Review this plan. Once you're happy with the decisions in §1 (registry choice, namespace
split, secrets tier, ingress approach), we implement **Phase 1 only**, verify its "Done when," and
move to Phase 2 — same phase-gated discipline as the main build.
