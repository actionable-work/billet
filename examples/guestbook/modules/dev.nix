# Local development: verbose logs and a small footprint. Plain values here
# replace the `lib.mkDefault` values in guestbook.nix.
_: {
  process.environment.GUESTBOOK_LOG_LEVEL = "debug";
  resources = {
    cpuLimit = 250;
    memoryLimit = 67108864;
  };
  rollout.minReadySeconds = 0;
}
