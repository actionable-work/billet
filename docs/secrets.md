# Secrets

Billet never handles secret values. A definition declares which secrets the
service needs and where it expects them. The runtime resolves each reference and
delivers the value when the service starts.

```nix
secrets.database = {
  external = "environment/database"; # reference resolved by the runtime
  mode = "file";                     # or "environment"
  target = "/run/secrets/database";  # file path, or variable name
  required = true;
};
```

| Field      | Default  | Description                                                        |
| ---------- | -------- | ------------------------------------------------------------------ |
| `external` | required | The runtime's name for the secret.                                 |
| `mode`     | `"file"` | Deliver as a file or as an environment variable.                   |
| `target`   | required | An absolute path for `file`, or a variable name for `environment`. |
| `required` | `true`   | Whether the service needs the secret to start.                     |

Validation rejects duplicate targets and targets that collide with
`process.environment` or storage mounts.

## Keep secrets out of Nix

Nix modules, environment values, and arguments are public build inputs. They are
copied into the Nix store, the canonical manifest, and the image. Never read
credentials in a module or place a secret value in `environment` or `argv`.
Declare a secret reference instead.
