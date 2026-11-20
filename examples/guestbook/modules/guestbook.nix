# The shared guestbook definition. Environment overlays in dev.nix and
# prod.nix refine it: a plain overlay value replaces a `lib.mkDefault` value
# here, and an overlay uses `lib.mkForce` to replace a plain value.
{
  pkgs,
  lib,
  ...
}: let
  guestbook = pkgs.callPackage ../app {};
in {
  identity = {
    name = "guestbook";
    version = "0.1.0";
  };
  # Python, psycopg and libpq make a closure of about forty store paths.
  # Group them into fewer layers so pulls and layer caches stay manageable.
  oci.maxLayers = 16;
  process = {
    package = guestbook;
    executable = "bin/guestbook";
    argv = ["serve"];
    environment = {
      GUESTBOOK_PORT = "8080";
      GUESTBOOK_DATABASE_HOST = "postgres";
      GUESTBOOK_DATABASE_NAME = "guestbook";
      GUESTBOOK_DATABASE_USER = "guestbook";
      GUESTBOOK_SESSION_KEY_FILE = "/run/secrets/guestbook/session-key";
      GUESTBOOK_LOG_LEVEL = lib.mkDefault "warning";
    };
  };
  resources = {
    cpuRequest = lib.mkDefault 100;
    cpuLimit = lib.mkDefault 500;
    memoryRequest = lib.mkDefault 33554432;
    memoryLimit = lib.mkDefault 134217728;
  };
  # References only: the runtime resolves and delivers the values.
  secrets = {
    databasePassword = {
      external = "guestbook/database-password";
      mode = "environment";
      target = "GUESTBOOK_DATABASE_PASSWORD";
    };
    sessionKey = {
      external = "guestbook/session-key";
      target = "/run/secrets/guestbook/session-key";
    };
  };
  # The migration creates the database if needed and applies the schema. A
  # consumer that maps initialization, such as Kubernetes init containers,
  # runs it before every start. Docker Compose has no mapping: run it yourself
  # (see docs/guestbook.md) before the server reports ready.
  initialization = {
    steps = [
      {
        id = "migrate";
        package = guestbook;
        executable = "bin/guestbook";
        argv = ["migrate"];
        timeoutSeconds = 20;
      }
    ];
    budgetSeconds = 20;
  };
  network = {
    ports.http = {
      port = 8080;
      protocol = "http";
      exposure = "public";
    };
    privateConnections = [
      {
        sourceService = "guestbook";
        destinationService = "postgres";
        destinationPort = "postgres";
      }
    ];
  };
  probes = {
    # Ready once the database answers and the migration is recorded.
    readiness = {
      type = "http";
      port = "http";
      path = "/readyz";
      intervalSeconds = 5;
      timeoutSeconds = 2;
      failureThreshold = 3;
    };
    liveness = {
      type = "http";
      port = "http";
      path = "/healthz";
      intervalSeconds = 10;
      timeoutSeconds = 2;
      failureThreshold = 3;
    };
  };
  restart = {
    maxRetries = 3;
    initialDelaySeconds = 2;
    maxDelaySeconds = 20;
  };
  # The server finishes in-flight requests after SIGTERM.
  shutdown = {
    stopSignal = "SIGTERM";
    stopGracePeriodSeconds = 15;
  };
  rollout = {
    maxSurge = 1;
    maxUnavailable = 0;
    minReadySeconds = lib.mkDefault 5;
    progressDeadlineSeconds = 180;
  };
}
