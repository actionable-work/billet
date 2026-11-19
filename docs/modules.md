# Application modules

A Billet module declares one application. Modules are evaluated with
`lib.evalModules` and receive `pkgs` as an argument. Several modules can
contribute to the same application.

Unknown fields and wrong types fail with the field path. CPU values are in
millicores, sizes in bytes, and durations in seconds.

These fields describe application intent. See the
[IR contract](../tests/.bloomery/specs/BILLET/IR/design/contract.md) for
validation and the [runtime guides](runtimes.md) for how each target applies the
declarations.

## `identity`

| Field       | Default          | Description                                                                                                                                             |
| ----------- | ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `name`      | required         | The application name.                                                                                                                                   |
| `version`   | required         | The application version.                                                                                                                                |
| `imageName` | lowercase `name` | Image repository, optionally with a registry such as `registry.example.com/team/hello`. Set it when the lowercase name is invalid as a repository name. |

## `process`

The single primary process. Additional workers run as its children.

| Field              | Default         | Description                                       |
| ------------------ | --------------- | ------------------------------------------------- |
| `package`          | required        | The derivation that contains the executable.      |
| `executable`       | required        | Path relative to `package`, such as `bin/hello`.  |
| `argv`             | `[]`            | Arguments, passed without a shell.                |
| `environment`      | `{}`            | Non-secret environment variables.                 |
| `workingDirectory` | `"/"`           | Absolute working directory.                       |
| `user`             | `"65534:65534"` | User and group. Images require numeric `uid:gid`. |

## `resources`

| Field             | Default  | Description                                           |
| ----------------- | -------- | ----------------------------------------------------- |
| `cpuRequest`      | required | Requested CPU, in millicores.                         |
| `cpuLimit`        | required | CPU limit. Must be at least `cpuRequest`.             |
| `memoryRequest`   | required | Requested memory, in bytes.                           |
| `memoryLimit`     | required | Memory limit. Must be at least `memoryRequest`.       |
| `replicas.min`    | `1`      | Minimum replica count.                                |
| `replicas.max`    | `1`      | Maximum replica count.                                |
| `targetMetric`    | `null`   | Metric used for scaling.                              |
| `placement`       | `[]`     | Placement constraints.                                |
| `strictSingleton` | `false`  | Never run more than one replica, even during rollout. |

## `initialization`

Steps the definition requests before the primary process on every start.

| Field                     | Default | Description                                                                   |
| ------------------------- | ------- | ----------------------------------------------------------------------------- |
| `steps`                   | `[]`    | Each step has an `id`, `package`, `executable`, `argv`, and `timeoutSeconds`. |
| `budgetSeconds`           | `0`     | Total time for all steps. Required when there are steps.                      |
| `startupAllowanceSeconds` | `30`    | Upper bound for `budgetSeconds`.                                              |

## `probes`

`startup`, `readiness`, and `liveness` are each `null` or a probe:

| Field              | Default  | Description                                            |
| ------------------ | -------- | ------------------------------------------------------ |
| `type`             | `"exec"` | `exec`, `tcp`, `http`, or `grpc`.                      |
| `command`          | `null`   | `{ package, executable, argv }` for `exec` probes.     |
| `port`             | `null`   | Name of a `network.ports` entry for other probe types. |
| `path`             | `"/"`    | Path for `http` probes.                                |
| `intervalSeconds`  | `10`     | Time between probes.                                   |
| `timeoutSeconds`   | `1`      | Probe timeout. Must not exceed the interval.           |
| `failureThreshold` | `3`      | Consecutive failures before the probe fails.           |

## `restart`

| Field                         | Default   | Description                                               |
| ----------------------------- | --------- | --------------------------------------------------------- |
| `enabled`                     | `true`    | Restart the process when a trigger occurs.                |
| `triggers`                    | all three | `unexpected-exit`, `liveness-failure`, `startup-failure`. |
| `maxRetries`                  | `5`       | Restarts before giving up.                                |
| `initialDelaySeconds`         | `1`       | Delay before the first restart.                           |
| `maxDelaySeconds`             | `30`      | Upper bound for the backoff delay.                        |
| `multiplier`                  | `2`       | Backoff multiplier.                                       |
| `jitter`                      | `true`    | Randomize backoff delays.                                 |
| `continuousReadyResetSeconds` | `300`     | Ready time that resets the retry count.                   |

## `shutdown`

| Field                    | Default     | Description                                  |
| ------------------------ | ----------- | -------------------------------------------- |
| `stopSignal`             | `"SIGTERM"` | `SIGTERM`, `SIGINT`, `SIGQUIT`, or `SIGHUP`. |
| `stopGracePeriodSeconds` | `30`        | Time between the stop signal and `SIGKILL`.  |

## `rollout`

| Field                     | Default     | Description                                        |
| ------------------------- | ----------- | -------------------------------------------------- |
| `strategy`                | `"rolling"` | Rollout strategy.                                  |
| `maxSurge`                | `1`         | Extra replicas allowed during rollout.             |
| `maxUnavailable`          | `0`         | Replicas allowed to be unavailable during rollout. |
| `minReadySeconds`         | `10`        | Ready time before a replica counts as available.   |
| `progressDeadlineSeconds` | `600`       | Time before a stalled rollout fails.               |
| `automaticRollback`       | `true`      | Roll back once when a rollout fails.               |

## `network`

| Field                | Default | Description                                                                                                |
| -------------------- | ------- | ---------------------------------------------------------------------------------------------------------- |
| `ports`              | `{}`    | Named ports. Each entry sets `port`, with `protocol` defaulting to `"tcp"` and `exposure` to `"private"`.  |
| `privateConnections` | `[]`    | Requested connections, each with `sourceService`, `destinationService`, `destinationPort`, and `protocol`. |
| `publicEgress`       | `true`  | Allow outbound internet access.                                                                            |
| `egressRestrictions` | `[]`    | Egress restrictions.                                                                                       |

## `secrets`

A named map of secret references. See [Secrets](secrets.md).

## `storage.<name>`

| Field         | Default           | Description                                           |
| ------------- | ----------------- | ----------------------------------------------------- |
| `mountPoint`  | required          | Absolute mount path.                                  |
| `lifecycle`   | `"ephemeral"`     | `ephemeral` or `persistent`.                          |
| `medium`      | `"disk"`          | `disk` or `memory`. Memory storage must be ephemeral. |
| `sizeBytes`   | required          | Requested size limit.                                 |
| `accessMode`  | `"readWriteOnce"` | `readWriteOnce`, `readOnlyMany`, or `readWriteMany`.  |
| `driverClass` | required          | Storage class requested from the runtime.             |

## Other fields

| Field                  | Default        | Description                                                                        |
| ---------------------- | -------------- | ---------------------------------------------------------------------------------- |
| `schemaVersion`        | `1`            | IR schema version.                                                                 |
| `systems`              | `[ <system> ]` | Systems the application supports. Must include the `pkgs` system.                  |
| `requiredCapabilities` | `[]`           | Extra runtime capabilities to require, added to those derived from the definition. |
