//! Assertions for Billet's K3s qualification VMs.
//!
//! The NixOS test driver runs `billet-vm-kubernetes TEST PARAMS.json [ARGS...]`
//! in a guest after K3s starts. Each test reads its Nix-written parameters,
//! runs the cluster consumer and asserts its behavior.
mod bandwidth;
mod guestbook;
mod k3s;

const USAGE: &str = "usage: billet-vm-kubernetes TEST PARAMS.json [ARGS...]
  kubernetes-k3s | kubernetes-catalog-bundle | guestbook-kubernetes
  kubernetes-bandwidth-setup
  kubernetes-bandwidth-route CIDR GATEWAY
  kubernetes-bandwidth-measure ROUTE DIRECTION BASELINE_IP CAPPED_IP";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let arg = |index: usize| {
        args.get(index)
            .map_or_else(|| panic!("{USAGE}"), String::as_str)
    };
    let params = || billet_vm::guest::Params::load(arg(1));
    match arg(0) {
        "kubernetes-k3s" => k3s::k3s(&params()),
        "kubernetes-catalog-bundle" => k3s::catalog_bundle(&params()),
        "guestbook-kubernetes" => guestbook::kubernetes(&params()),
        "kubernetes-bandwidth-setup" => bandwidth::setup(&params()),
        "kubernetes-bandwidth-route" => bandwidth::route(arg(1), arg(2)),
        "kubernetes-bandwidth-measure" => {
            bandwidth::measure(&params(), arg(2), arg(3), arg(4), arg(5));
        }
        _ => panic!("{USAGE}"),
    }
}
