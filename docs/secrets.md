# Secrets

Billet never handles secret values. A definition declares which secrets the
service needs and where it expects them. The target determines how values reach
the service at startup.

```nix
secrets.database = {
  external = "environment/database"; # reference recorded in the manifest
  mode = "file";                     # or "environment"
  target = "/run/secrets/database";  # file path, or variable name
  required = true;
};
```

| Field      | Default  | Description                                                        |
| ---------- | -------- | ------------------------------------------------------------------ |
| `external` | required | Reference for a consumer that resolves secrets from the manifest.  |
| `mode`     | `"file"` | Deliver as a file or as an environment variable.                   |
| `target`   | required | An absolute path for `file`, or a variable name for `environment`. |
| `required` | `true`   | Whether the declaration requires delivery at startup.              |

Validation rejects duplicate targets and targets that collide with
`process.environment` or storage mounts.

Docker Compose reads host environment variables derived from the service name
and the logical secret name. If a service named `hello` uses the example
`database` declaration above, set `BILLET_SECRET_hello__database` at startup.
The `external` field stays in the manifest. See the
[Compose secret naming and delivery rules](runtimes/docker-compose.md#provide-secrets-at-startup).

For a direct `docker run`, supply the file or environment value yourself.
[Run the Docker container](runtimes/docker.md#run-the-container)

## Keep secrets out of Nix

Nix modules, environment values, and arguments are public build inputs. They are
copied into the Nix store, the canonical manifest, and the image. Never read
credentials in a module or place a secret value in `process.environment` or
`process.argv`. Declare a secret reference instead.
