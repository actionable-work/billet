{pkgs, ...}: {
  identity = {
    name = "hello";
    version = "0.1.0";
  };
  process = {
    package = pkgs.hello;
    executable = "bin/hello";
    argv = ["--greeting=Hello from Billet"];
  };
  resources = {
    cpuRequest = 100;
    cpuLimit = 1000;
    memoryRequest = 16777216;
    memoryLimit = 67108864;
  };
}
