# Production: two replicas with more headroom and a longer drain.
{lib, ...}: {
  process.environment.GUESTBOOK_LOG_LEVEL = "info";
  resources = {
    cpuRequest = 250;
    cpuLimit = 1000;
    memoryRequest = 67108864;
    memoryLimit = 268435456;
    replicas = {
      min = 2;
      max = 2;
    };
  };
  rollout.minReadySeconds = 10;
  # guestbook.nix sets a plain 15 seconds; replace it rather than conflict.
  shutdown.stopGracePeriodSeconds = lib.mkForce 30;
}
