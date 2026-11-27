//! Assertions for Billet's Docker Compose qualification VMs.
//!
//! The NixOS test driver runs `billet-vm-compose TEST PARAMS.json` in the guest
//! after Docker starts. Each test reads its Nix-written parameters, runs the
//! pinned Compose consumer and asserts its behavior.
mod compose;
mod guestbook;

const USAGE: &str = "usage: billet-vm-compose <compose-artifact|guestbook-compose> PARAMS.json";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let [test, params] = args.as_slice() else {
        panic!("{USAGE}")
    };
    let params = billet_vm::guest::Params::load(params);
    match test.as_str() {
        "compose-artifact" => compose::run(&params),
        "guestbook-compose" => guestbook::compose(&params),
        _ => panic!("{USAGE}"),
    }
}
