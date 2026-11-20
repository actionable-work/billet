# Stateful example

The `examples/guestbook` subflake shows a stateful web application deployed as a
bundle of two Billets. It complements the stateless
[catalog-report example](../../IR/design/targets.md#example-subflakes). One
example carries all the stateful concerns because they depend on each other: the
migration needs the database, readiness needs the migration, and persistence
needs both.

## Members

The primary application, `guestbook`, is a Python HTTP service from nixpkgs. Its
image is the closure of the Python interpreter, psycopg, and libpq, so it sets
`oci.maxLayers` below the closure path count and Billet groups the closure into
that budget.

The `postgres` Billet runs PostgreSQL from nixpkgs. A wrapper prepares the
persistent data directory as root, initializes the cluster on first start, and
then runs the server as an unprivileged user. It keeps the volume root as the
runtime created it and places all PostgreSQL state in a 65534-owned `pg`
subdirectory, because a changed root would make kubelet re-apply `fsGroup`
recursively on the next mount and loosen the data directory permissions. It runs
`initdb` in a staging directory and renames it into place only after success, so
an interrupted first start is retried. The password copy for `initdb` lives in
`/dev/shm` and is removed on exit, never on the volume. Because the closure-only
image has no `/bin/sh` and `initdb` needs one, the wrapper links it from the
closure into the writable container root. nss_wrapper supplies the account
entries that `initdb` and the server look up. The server is the process that
receives the stop signal. `SIGINT` selects PostgreSQL's fast shutdown. The
database is a strict singleton without public egress and exposes only a private
port. An exec readiness probe runs `pg_isready`.

The guestbook declares:

- A database password secret in `environment` mode. The PostgreSQL Billet
  declares the same external reference in `file` mode and reads it on first
  start. Both name the runtime reference `guestbook/database-password`.
- A session key secret in `file` mode. The application signs each entry with an
  HMAC of that key, so a client holding the key can verify the delivery.
- An initialization step that creates the application database if it is missing,
  applies the schema migration, and records its version. Every part is safe to
  repeat. Concurrent replicas tolerate a concurrent database creation and
  serialize the migration with an advisory lock.
- An HTTP readiness probe on `/readyz` that succeeds only after the migration
  version is present, and an HTTP liveness probe on `/healthz`.
- A public HTTP port, a private connection to the database port, and explicit
  restart, shutdown, and rollout settings.

The application rejects an incomplete entry or a negative Content-Length with
400, a non-numeric one with 411, and a body over 64 KiB with 413, without
reading an unbounded body. It answers 503 when the database is unavailable. The
modules never contain a secret value. Test fixtures generate the values at run
time and hand them to the consumer.

## Layered modules

`modules/guestbook.nix` is the shared base. It defines tunable fields with
`lib.mkDefault` and fixed fields as plain definitions. `modules/dev.nix` and
`modules/prod.nix` are environment overlays combined with the base through the
`modules` list. A plain overlay definition replaces a `mkDefault` base value. An
overlay that must replace a plain base definition uses `lib.mkForce`. The
example never merges attribute sets with `recursiveUpdate`; the module system
resolves priorities field by field.

Two definitions of a scalar field at the same priority with different values
fail evaluation with `billet: <field path>: conflicting definitions`. The
message names the field path and omits the values.

The subflake exports `billets.<system>.dev` and `billets.<system>.prod`. Each is
a bundle of the guestbook, built with that overlay, and the shared PostgreSQL
Billet. It also exports a validation check for each bundle and member.

## Qualification

Pure checks evaluate both overlays and assert the effective values that each
priority rule selects. A sandboxed evaluation of the base with two plain
overlays that define the log level as distinct sentinel values asserts the
conflict diagnostic, its field path, and that neither value appears in the
message. A build check asserts that the guestbook image has at most its runtime
layer budget plus the metadata layer although its closure has more store paths.

In an isolated Docker VM, the development bundle runs with Docker Compose. The
fixture writes random secret values on the VM and passes them through the
derived `BILLET_SECRET_*` variables. Compose does not map initialization steps,
so the capability report warns, and the fixture runs the step recorded in the
manifest with `docker compose run`. The check asserts that:

- the rendered project declares the PostgreSQL healthcheck, the startup
  dependency, the published port, the volumes, and the tuned shutdown and
  restart settings, and warns that the HTTP probes are not mapped;
- readiness reports unavailable before the migration and ready after it, and
  rerunning the step reports the recorded version without applying it again;
- the environment secret reaches the declared variable and the file secret
  reaches the declared path, shown by an entry HMAC computed with the fixture
  key;
- an entry survives restarts of the application and database containers and a
  `down` without removing volumes;
- the database volume root keeps its original owner while the `pg` subdirectory
  and data directory belong to uid 65534;
- malformed, negative, non-numeric and oversized request bodies are rejected;
- the services stop on their declared signals and timeouts and exit cleanly, and
  the guestbook restart policy allows three retries.

In an isolated K3s VM with the local-path provisioner, the production bundle is
applied with strict server-side validation. The fixture creates the Kubernetes
Secret from random values. The check asserts that:

- the Deployments render the HTTP readiness and liveness probes, the init
  container, the Secret environment and file references, the claim, and the
  rollout and termination settings;
- the database NetworkPolicy admits only guestbook pods on the database port and
  denies database egress, because both Billets declare the private connection;
- both production replicas become ready after their init containers applied or
  observed the migration, checked against each pod address rather than the
  Service;
- the environment and file secrets arrive, shown by a successful write and the
  entry HMAC; and
- an entry survives deleting the database pod and restarting the application
  rollout, and the database volume root keeps its original owner.

## User guide

`docs/guestbook.md` explains which consumers run the initialization step, how to
supply the Compose secret variables, and how to run the migration under Compose.
Its shell blocks run in the documentation Docker VM. It also documents the
PostgreSQL wrapper's root start: Billet renders `fsGroup` for persistent claims,
but host-path volumes ignore it and Docker has no equivalent, so the wrapper
changes ownership itself. The database therefore does not meet the Pod Security
`restricted` profile and needs a writable root filesystem for the `/bin/sh`
link.
