# The PostgreSQL Billet that stores the guestbook entries.
{pkgs, ...}: let
  postgresql = pkgs.postgresql_18;
  dataRoot = "/var/lib/postgresql";
  # The image has no account database. initdb and the server look up their
  # own user, so nss_wrapper supplies one from the store.
  passwd = pkgs.writeText "guestbook-postgres-passwd" ''
    root:x:0:0:root:/:/bin/false
    postgres:x:65534:65534:PostgreSQL:${dataRoot}:/bin/false
  '';
  group = pkgs.writeText "guestbook-postgres-group" ''
    root:x:0:
    postgres:x:65534:
  '';
  hba = pkgs.writeText "guestbook-pg_hba.conf" ''
    host all all 0.0.0.0/0 scram-sha-256
    host all all ::/0 scram-sha-256
  '';
  # Volume roots usually belong to root. The wrapper starts as root, prepares
  # a PostgreSQL-owned directory below the volume root, initializes it once,
  # and then runs PostgreSQL as 65534 so the server receives the stop signal
  # directly. The guestbook's migration step creates the application
  # database, so every start of the application repeats that check.
  entrypoint = pkgs.writeShellApplication {
    name = "guestbook-postgres";
    runtimeInputs = [postgresql pkgs.coreutils pkgs.util-linux];
    text = ''
      # Keep the volume root as the runtime created it. Changing its owner
      # makes kubelet re-group the whole volume on the next mount when it
      # applies fsGroup, which loosens the data directory permissions that
      # PostgreSQL insists on. Everything PostgreSQL owns lives below it.
      base=${dataRoot}/pg
      data="$base/data"
      staging="$base/initdb"
      export LD_PRELOAD=${pkgs.nss_wrapper}/lib/libnss_wrapper.so
      export NSS_WRAPPER_PASSWD=${passwd} NSS_WRAPPER_GROUP=${group}
      as_postgres() { setpriv --reuid=65534 --regid=65534 --clear-groups -- "$@"; }

      # initdb checks the server version through popen(3), which runs
      # /bin/sh. The closure-only image has no /bin, so link one from the
      # closure into the writable container root.
      if [ ! -e /bin/sh ]; then
        mkdir -p /bin
        ln -s ${pkgs.bash}/bin/sh /bin/sh
      fi
      mkdir -p "$base"
      chown 65534:65534 "$base"
      if [ ! -d "$data" ]; then
        # Initialize beside the data directory and rename it into place only
        # when initdb succeeds, so an interrupted first start is retried.
        rm -rf "$staging"
        # The password copy lives in memory, never on the volume.
        password=$(mktemp -p /dev/shm)
        trap 'rm -f "$password"' EXIT
        install -m 0600 -o 65534 -g 65534 "$POSTGRES_PASSWORD_FILE" "$password"
        as_postgres initdb --pgdata="$staging" --username="$POSTGRES_USER" --pwfile="$password" \
          --auth=scram-sha-256 --encoding=UTF8 --locale=C
        rm -f "$password"
        mv "$staging" "$data"
      fi
      exec setpriv --reuid=65534 --regid=65534 --clear-groups -- postgres -D "$data" \
        -c listen_addresses='*' -c port=5432 -c hba_file=${hba} -c unix_socket_directories=""
    '';
  };
  ready = {
    package = postgresql;
    executable = "bin/pg_isready";
    argv = ["--host=127.0.0.1" "--port=5432" "--username=guestbook" "--dbname=guestbook" "--quiet"];
  };
in {
  identity = {
    name = "postgres";
    version = postgresql.version;
  };
  process = {
    package = entrypoint;
    executable = "bin/guestbook-postgres";
    # The wrapper needs root for the volume; PostgreSQL itself runs as 65534.
    user = "0:0";
    environment = {
      POSTGRES_USER = "guestbook";
      POSTGRES_PASSWORD_FILE = "/run/secrets/postgres/password";
    };
  };
  resources = {
    cpuRequest = 250;
    cpuLimit = 1000;
    memoryRequest = 134217728;
    memoryLimit = 536870912;
    strictSingleton = true;
  };
  secrets.password = {
    external = "guestbook/database-password";
    target = "/run/secrets/postgres/password";
  };
  storage.data = {
    mountPoint = dataRoot;
    lifecycle = "persistent";
    sizeBytes = 1073741824;
    driverClass = "local-path";
  };
  network = {
    ports.postgres.port = 5432;
    # Both ends declare the link: the guestbook may connect out, and the
    # database admits only the guestbook. It needs no egress of its own.
    privateConnections = [
      {
        sourceService = "guestbook";
        destinationService = "postgres";
        destinationPort = "postgres";
      }
    ];
    publicEgress = false;
  };
  probes = {
    readiness = {
      command = ready;
      intervalSeconds = 2;
      timeoutSeconds = 2;
      failureThreshold = 15;
    };
    liveness = {
      command = ready;
      intervalSeconds = 10;
      timeoutSeconds = 5;
      failureThreshold = 6;
    };
  };
  # PostgreSQL treats SIGINT as a fast shutdown: it rolls back open
  # transactions and writes a checkpoint before exiting.
  shutdown = {
    stopSignal = "SIGINT";
    stopGracePeriodSeconds = 60;
  };
  # A singleton holding a ReadWriteOnce volume replaces its pod instead of
  # surging a second one.
  rollout = {
    maxSurge = 0;
    maxUnavailable = 1;
    minReadySeconds = 0;
    progressDeadlineSeconds = 300;
  };
}
