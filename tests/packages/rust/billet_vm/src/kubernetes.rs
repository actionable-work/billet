//! Helpers shared by the K3s qualification checkers.
use crate::guest::{succeed, wait_until_succeeds};

/// Wait for the K3s API server and every node after `k3s.service` starts.
pub fn cluster_ready() {
    wait_until_succeeds("k3s kubectl get --raw=/readyz", 900);
    wait_until_succeeds(
        "k3s kubectl wait --for=condition=Ready node --all --timeout=10s",
        180,
    );
}

/// Wait for cluster DNS, which in-cluster service names require.
pub fn dns_ready() {
    succeed("k3s kubectl -n kube-system rollout status deployment/coredns --timeout=120s");
}
