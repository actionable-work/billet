# Guestbook example

[`examples/guestbook`](../examples/guestbook) is a stateful web application: a
Python guestbook and the PostgreSQL database that stores its entries. It shows
persistent storage, secret references, a schema migration, HTTP probes, a public
port, and restart, shutdown and rollout tuning, with `dev` and `prod` overlays
on one shared base module.

The flake exports two bundles, `billets.<system>.dev` and
`billets.<system>.prod`. Each contains the `guestbook` Billet, built with that
environment's overlay, and the shared `postgres` Billet. See
[Layering modules](modules.md#layering-modules) for how the overlays combine.

## What each runtime does

The definition declares the migration as an
[initialization step](modules.md#initialization). The guestbook reports ready on
`/readyz` only after the step has recorded the schema version, so the step must
run before the service takes traffic.

| Consumer       | Migration step                                              | Probes                                                     |
| -------------- | ----------------------------------------------------------- | ---------------------------------------------------------- |
| Kubernetes     | Runs as an init container before each pod starts.           | HTTP readiness and liveness probes, exec probe for the DB. |
| Docker Compose | Not mapped. The report warns. Run the step yourself, below. | DB healthcheck only. The HTTP probes stay in the manifest. |
| Other runtimes | Read `initialization.steps` from the manifest and run it.   | Read `probes` from the manifest.                           |

The step is safe to repeat: it creates the database if it is missing and applies
the schema only once.

## Run the development bundle with Docker Compose

Run these commands from the repository root. You need Nix with the `nix-command`
and `flakes` features, Docker Engine with the Compose plugin, `curl`, `jq`, and
the coreutils `head`, `base64` and `cut`. The commands name `x86_64-linux`; on
an `aarch64-linux` host, replace it with `aarch64-linux`.

The Billets declare three secret references and Billet never sees their values.
Compose reads each value from a host variable named after the service and the
logical secret. Both services must receive the same database password:

<!-- doctest: guestbook-secrets -->

```sh
password="$(head -c 24 /dev/urandom | base64 -w0)"
export BILLET_SECRET_postgres__password="$password"
export BILLET_SECRET_guestbook__databasePassword="$password"
export BILLET_SECRET_guestbook__sessionKey="$(head -c 32 /dev/urandom | base64 -w0)"
```

PostgreSQL uses the password when it first initializes its volume. Keep using
the same value for later starts with that volume.

Build the bundle, load both images, and start the project:

<!-- doctest: guestbook-up -->

```sh
nix build ./examples/guestbook#billets.x86_64-linux.dev.dockerCompose.bundle -o result
for image in result/images/*.tar; do docker load --input "$image"; done
docker compose -f result/compose.yaml up --no-build --detach
```

Compose waits for the PostgreSQL healthcheck before it starts the guestbook. The
guestbook answers on a published port but reports `503` on `/readyz` until the
migration runs. Run the step recorded in the manifest with the guestbook's
configuration and secrets:

<!-- doctest: guestbook-migrate -->

```sh
docker compose -f result/compose.yaml run --rm --no-deps --no-tty --interactive=false \
  --entrypoint "$(jq -r '.initialization.steps[0].executable' result/manifests/guestbook.json)" \
  guestbook migrate
```

Run it again after you replace the guestbook containers with a newer version.
Then add and list entries:

<!-- doctest: guestbook-request -->

```sh
port="$(docker compose -f result/compose.yaml port guestbook 8080 | head -n 1 | cut -d: -f2)"
curl -fsS "http://127.0.0.1:$port/readyz"
curl -fsS -H 'Content-Type: application/json' \
  --data '{"author":"ada","message":"hello"}' "http://127.0.0.1:$port/entries"
curl -fsS "http://127.0.0.1:$port/entries"
```

Each entry carries an HMAC-SHA256 signature of `[id, author, message]`, encoded
as compact JSON, made with the session key. The entries live in the
`postgres__data` volume, so they survive `docker compose down` unless you add
`--volumes`.

## Run the production bundle on Kubernetes

The `prod` bundle runs two guestbook replicas. Its database claim requests the
`local-path` storage class, which K3s provides. Create a Secret named
`guestbook` with the keys `database-password` and `session-key` in the target
namespace, then apply `kubernetes.json` from
`.#billets.x86_64-linux.prod.kubernetes.bundle` and import its images as in the
[Kubernetes guide](runtimes/kubernetes.md). Each pod runs the migration in an
init container, so no manual step is needed.

## PostgreSQL runs its wrapper as root

The image contains only the runtime closure, so the PostgreSQL Billet sets
`process.user = "0:0"` and its wrapper does three things before it runs the
server as uid 65534:

- It creates `/var/lib/postgresql/pg` below the volume root and gives it to
  uid 65534. Docker and most volume provisioners create the volume root as root.
  Kubernetes `fsGroup`, which Billet renders for persistent claims, is not
  applied to host-path volumes such as `local-path`, and Docker has no
  equivalent. The wrapper never changes the volume root itself: on storage that
  applies `fsGroup`, a changed root would make kubelet re-group the whole volume
  on the next mount and loosen the data directory permissions that PostgreSQL
  requires.
- It links `/bin/sh` into the container root, because `initdb` runs a shell.
- It initializes the cluster in a staging directory and renames it into place
  only when `initdb` succeeds, with the password copy in `/dev/shm`.

As a result the database pod does not meet the Pod Security `restricted`
profile, which requires a non-root user, and it needs a writable root
filesystem. To run under those policies, provide a volume owned by uid 65534 and
a base layer with `/bin/sh`, or use a managed database and remove the `postgres`
Billet from the bundle.
