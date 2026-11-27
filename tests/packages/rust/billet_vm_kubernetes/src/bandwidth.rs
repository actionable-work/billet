//! `billet:kubernetes-bandwidth-live`: Pod bandwidth annotations cap traffic.
//!
//! `setup` runs on the server and prints the server pod CIDR and the baseline
//! and capped pod addresses. The driver passes them to `route` on the external
//! node and to `measure`, which runs on the node that originates the traffic.
use billet_vm::guest::{Params, items, json, single, succeed, text, wait_until_succeeds};
use serde_json::Value;

const KUBECTL: &str = "k3s kubectl -n default";

fn pod_ip(workload: &str) -> String {
    let pods = json(&format!(
        "{KUBECTL} get pod -l billet.actionable.work/application={workload} -o json"
    ));
    let pod = single(items(&pods["items"]).clone());
    assert_eq!(pod["spec"]["nodeName"], "server");
    let ip = text(&pod["status"]["podIP"]);
    assert!(
        ip.parse::<std::net::Ipv4Addr>().is_ok(),
        "not an IPv4 pod address: {ip}"
    );
    ip.to_owned()
}

/// Deploy the workloads and peers and print `CIDR BASELINE_IP CAPPED_IP`.
pub fn setup(p: &Params) {
    wait_until_succeeds(
        &format!("{KUBECTL} wait --for=condition=Ready node/server node/worker --timeout=10s"),
        180,
    );
    succeed(&format!(
        "{KUBECTL} apply --server-side --validate=strict -f {} -f {} -f {}",
        p.s("baselineFile"),
        p.s("cappedFile"),
        p.s("peers")
    ));
    succeed(&format!(
        "{KUBECTL} rollout status deployment/baseline --timeout=120s"
    ));
    succeed(&format!(
        "{KUBECTL} rollout status deployment/capped --timeout=120s"
    ));
    succeed(&format!(
        "{KUBECTL} wait --for=condition=Ready pod/same-peer pod/cross-peer --timeout=120s"
    ));
    let (baseline, capped) = (pod_ip("baseline"), pod_ip("capped"));
    for (peer, node) in [("same-peer", "server"), ("cross-peer", "worker")] {
        assert_eq!(
            succeed(&format!(
                "{KUBECTL} get pod {peer} -o jsonpath='{{.spec.nodeName}}'"
            )),
            node
        );
    }
    let cidr = succeed(&format!(
        "{KUBECTL} get node server -o jsonpath='{{.spec.podCIDR}}'"
    ));
    let (network, prefix) = cidr
        .split_once('/')
        .unwrap_or_else(|| panic!("not a CIDR: {cidr}"));
    assert!(
        network.parse::<std::net::Ipv4Addr>().is_ok()
            && prefix.parse::<u8>().is_ok_and(|bits| bits <= 32),
        "{cidr}"
    );
    println!("{cidr} {baseline} {capped}");
}

/// Route the server pod network through the server node.
pub fn route(cidr: &str, gateway: &str) {
    succeed(&format!("ip route add {cidr} via {gateway}"));
}

fn client(p: &Params, route: &str) -> String {
    let iperf = format!("{}/bin/iperf3", p.s("iperf3"));
    match route {
        "same-node" => format!("{KUBECTL} exec same-peer -- {iperf}"),
        "cross-node" => format!("{KUBECTL} exec cross-peer -- {iperf}"),
        "external" => iperf,
        _ => panic!("unknown route {route}"),
    }
}

/// Aggregate received bits per second over three parallel flows.
fn through(client: &str, target: &str, reverse: bool, warmup: u64, duration: u64) -> f64 {
    let direction = if reverse { "--reverse" } else { "" };
    let result: Value = json(&format!(
        "timeout 120 {client} --client {target} --parallel 3 --json --omit {warmup} --time {duration} {direction}"
    ));
    let streams = items(&result["end"]["streams"]);
    assert!(
        streams.len() == 3
            && streams
                .iter()
                .all(|stream| stream["receiver"]["bytes"].as_u64() > Some(0)),
        "{result}"
    );
    result["end"]["sum_received"]["bits_per_second"]
        .as_f64()
        .expect("bits per second")
}

/// containerd supplies up to 2^32-1 initial burst bits. Allow twice the
/// estimated drain time so the measurement covers sustained traffic.
fn warmup(uncapped: f64, limit: f64) -> u64 {
    let burst = 2.0 * f64::from(u32::MAX);
    let drain = (burst / (uncapped - limit)).ceil() as u64;
    drain.max(3)
}

/// Compare the capped workload's aggregate rate in one direction with its limit.
pub fn measure(p: &Params, route: &str, direction: &str, baseline: &str, capped: &str) {
    let (reverse, limit) = match direction {
        "ingress" => (false, p.n("ingressRate")),
        "egress" => (true, p.n("egressRate")),
        _ => panic!("unknown direction {direction}"),
    };
    let limit = limit as f64;
    let client = client(p, route);
    let uncapped = through(&client, baseline, reverse, 1, 3);
    assert!(
        uncapped > limit * 1.5,
        "baseline {uncapped:.0} cannot distinguish limit {limit}"
    );
    let warmup = warmup(uncapped, limit);
    let measured = through(&client, capped, reverse, warmup, 6);
    eprintln!("{route} {direction}: uncapped={uncapped:.0}, capped={measured:.0}, limit={limit}");
    assert!(
        (0.75 * limit..=1.12 * limit).contains(&measured),
        "uncapped={uncapped:.0}, capped={measured:.0}, limit={limit}, warmup={warmup}"
    );
}
