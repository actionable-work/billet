//! `billet:kubernetes-k3s` and `billet:kubernetes-catalog-bundle`: K3s applies
//! and runs Billet's Kubernetes artifacts.
use billet_vm::guest::require;
use billet_vm::guest::{
    Params, items, json, parse, section, single, succeed, text, wait_for, wait_until_succeeds,
};
use billet_vm::kubernetes::{cluster_ready, dns_ready};
use serde_json::{Value, json};

const KUBECTL: &str = "k3s kubectl -n billet-test";

fn apply(file: &str) {
    succeed(&format!(
        "k3s kubectl apply --server-side --validate=strict -f {file}"
    ));
}

fn deploy(p: &Params) {
    let bundle = p.s("bundle");
    assert_eq!(
        succeed("k3s kubectl get namespace billet-test --ignore-not-found -o name"),
        ""
    );
    succeed(&format!(
        "cmp {} {bundle}/manifest.json",
        p.s("fixtureManifest")
    ));
    succeed(&format!(
        "cmp {} {bundle}/kubernetes.json",
        p.s("kubernetesFile")
    ));
    succeed(&format!("cmp {} {bundle}/image.tar", p.s("dockerImage")));
    succeed(&format!("k3s ctr images import {bundle}/image.tar"));
    apply(&format!("{bundle}/kubernetes.json"));
    assert_eq!(
        succeed("k3s kubectl get namespace billet-test -o jsonpath='{.status.phase}'"),
        "Active"
    );
    succeed(&format!(
        "k3s kubectl apply --server-side --dry-run=server --validate=strict -f {bundle}/kubernetes.json"
    ));
    succeed(r#"printf '%s' "$(cat /proc/sys/kernel/random/uuid)" >/tmp/billet-token"#);
    succeed(&format!(
        "{KUBECTL} create secret generic runtime --from-file=token=/tmp/billet-token"
    ));
    require(
        &format!("{KUBECTL} rollout status deployment/kube-app --timeout=90s"),
        &[
            format!("{KUBECTL} describe pods"),
            format!("{KUBECTL} logs deployment/kube-app --all-containers=true"),
        ],
    );
}

fn pod_status(p: &Params) {
    let pod = single(items(&json(&format!("{KUBECTL} get pods -o json"))["items"]).clone());
    let init: Vec<&Value> = items(&pod["status"]["initContainerStatuses"])
        .iter()
        .map(|status| &status["state"]["terminated"]["exitCode"])
        .collect();
    assert_eq!(init, [&json!(0), &json!(0)]);
    let container = &pod["status"]["containerStatuses"][0];
    assert_eq!(container["ready"], true);
    assert_eq!(container["started"], true);
    assert_eq!(container["image"], p.s("imageRef"));
    assert_eq!(
        pod["spec"]["containers"][0]["startupProbe"]["tcpSocket"]["port"],
        8080
    );
    assert_eq!(pod["spec"]["terminationGracePeriodSeconds"], 7);
    assert_eq!(pod["spec"]["automountServiceAccountToken"], false);
}

fn service_ip() -> String {
    succeed(&format!(
        "{KUBECTL} get service kube-app -o jsonpath='{{.spec.clusterIP}}'"
    ))
    .trim()
    .to_owned()
}

fn mount_fields<'t>(mounts: &'t str, target: &str) -> Vec<&'t str> {
    mounts
        .lines()
        .map(|line| line.split_whitespace().collect::<Vec<_>>())
        .find(|fields| fields.get(1) == Some(&target))
        .unwrap_or_else(|| panic!("no mount at {target}"))
}

fn service_and_mounts(p: &Params) {
    let request = format!(
        "{} --fail --silent --show-error --max-time 2 http://{}:8080/index.html",
        p.s("curl"),
        service_ip()
    );
    assert_eq!(wait_until_succeeds(&request, 60), "ready\n");
    let mounts = succeed(&format!(
        "{KUBECTL} exec deployment/kube-app -- {}/cat /proc/mounts",
        p.s("core")
    ));
    let scratch = mount_fields(&mounts, "/scratch");
    assert_eq!(scratch[2], "tmpfs");
    assert!(
        scratch[3].split(',').any(|option| option == "size=4096k"),
        "{scratch:?}"
    );
    let secret = mount_fields(&mounts, p.s("tokenFile"));
    assert!(
        secret[3].split(',').any(|option| option == "ro"),
        "{secret:?}"
    );
}

fn network_policy(p: &Params) {
    let busybox = p.s("busybox");
    let ip = service_ip();
    let request = |port: u16| format!("{busybox} wget -T 2 -qO- http://{ip}:{port}/index.html");
    let denial = r#"'"$@"; test "$?" -eq 1'"#;
    let denied = |peer: &str, port: u16| {
        let command = format!(
            "{KUBECTL} exec {peer} -- {busybox} sh -c {denial} sh {}",
            request(port)
        );
        wait_until_succeeds(&command, 30);
    };
    succeed(&format!("k3s ctr images import {}", p.s("peerImage")));
    apply(p.s("peerFile"));
    let image = p.s("imageRef");
    succeed(&format!(
        "{KUBECTL} run denied --image={image} --image-pull-policy=Never --command -- {}/sleep infinity",
        p.s("core")
    ));
    succeed(&format!(
        "{KUBECTL} rollout status deployment/kube-peer --timeout=90s"
    ));
    succeed(&format!(
        "{KUBECTL} wait --for=condition=Ready pod/denied --timeout=60s"
    ));
    assert_eq!(
        wait_until_succeeds(
            &format!("{KUBECTL} exec deployment/kube-peer -- {}", request(9090)),
            60
        ),
        "ready\n"
    );
    assert_eq!(
        wait_until_succeeds(&format!("{KUBECTL} exec denied -- {}", request(8080)), 60),
        "ready\n"
    );
    denied("denied", 9090);
    denied("deployment/kube-peer", 8080);
}

const UPGRADE: &str = "k3s kubectl -n billet-upgrade";
const VERSION: &str = "billet.actionable.work/identity-version";

fn upgrade_rollout(p: &Params) -> (Value, Value) {
    succeed(&format!("k3s ctr images import {}", p.s("upgradeV1Image")));
    succeed(&format!("k3s ctr images import {}", p.s("upgradeV2Image")));
    apply(p.s("upgradeV1File"));
    succeed(&format!(
        "{UPGRADE} rollout status deployment/kube-upgrade --timeout=90s"
    ));
    let first = json(&format!("{UPGRADE} get deployment kube-upgrade -o json"));
    apply(p.s("upgradeV2File"));
    succeed(&format!(
        "{UPGRADE} rollout status deployment/kube-upgrade --timeout=120s"
    ));
    (
        first,
        json(&format!("{UPGRADE} get deployment kube-upgrade -o json")),
    )
}

fn upgrade_deployment(first: &Value, deployment: &Value) {
    let spec = &deployment["spec"];
    let generation = |value: &Value| {
        value["metadata"]["generation"]
            .as_i64()
            .expect("generation")
    };
    assert!(generation(deployment) > generation(first));
    assert_eq!(
        spec["strategy"],
        json!({"type": "RollingUpdate", "rollingUpdate": {"maxSurge": 1, "maxUnavailable": 0}})
    );
    assert_eq!(
        (&spec["minReadySeconds"], &spec["progressDeadlineSeconds"]),
        (&json!(2), &json!(120))
    );
    assert_eq!(
        spec["template"]["metadata"]["annotations"][VERSION],
        "2.0.0"
    );
    assert_eq!(
        first["spec"]["template"]["metadata"]["annotations"][VERSION],
        "1.0.0"
    );
}

/// The upgraded pods once exactly one ready container runs the second image.
fn second_version_pods(image: &str) -> Option<Vec<Value>> {
    let pods = items(&json(&format!("{UPGRADE} get pods -o json"))["items"]).clone();
    let statuses: Vec<&Value> = pods
        .iter()
        .flat_map(|pod| {
            pod["status"]["containerStatuses"]
                .as_array()
                .into_iter()
                .flatten()
        })
        .collect();
    let ready = pods.len() == 1
        && statuses.len() == 1
        && statuses
            .iter()
            .all(|status| status["ready"] == true && status["image"] == image);
    ready.then_some(pods)
}

fn upgrade(p: &Params) {
    section("the consumer accepts a second Billet version");
    let (first, deployment) = upgrade_rollout(p);
    upgrade_deployment(&first, &deployment);
    let image = p.s("upgradeV2Ref");
    assert_ne!(p.s("upgradeV1Ref"), image);
    let pods = wait_for(
        60,
        "the second version",
        &[format!("{UPGRADE} get pods -o wide")],
        || second_version_pods(image),
    );
    for pod in &pods {
        assert_eq!(pod["metadata"]["annotations"][VERSION], "2.0.0");
        // The container inherits the second image's argv; its output reports it.
        billet_vm::guest::lacks(&pod["spec"]["containers"][0], &["command", "args"]);
        let logs = succeed(&format!(
            "{UPGRADE} logs {}",
            text(&pod["metadata"]["name"])
        ));
        assert_eq!(logs, "BILLET_UPGRADE v2\n");
    }
}

pub fn k3s(p: &Params) {
    cluster_ready();
    deploy(p);
    pod_status(p);
    service_and_mounts(p);
    network_policy(p);
    upgrade(p);
}

pub fn catalog_bundle(p: &Params) {
    cluster_ready();
    let bundle = p.s("bundle");
    succeed(&format!(
        "cmp {} {bundle}/kubernetes.json",
        p.s("kubernetesFile")
    ));
    for name in ["catalog", "report"] {
        succeed(&format!(
            "cmp {} {bundle}/manifests/{name}.json",
            p.v("manifests")[name].as_str().expect("manifest")
        ));
        succeed(&format!(
            "cmp {} {bundle}/images/{name}.tar",
            p.v("images")[name].as_str().expect("image")
        ));
        succeed(&format!("k3s ctr images import {bundle}/images/{name}.tar"));
    }
    dns_ready();
    succeed("k3s kubectl create namespace catalog-report");
    let kubectl = "k3s kubectl -n catalog-report";
    succeed(&format!(
        "{kubectl} apply --server-side --validate=strict -f {bundle}/kubernetes.json"
    ));
    let report = "-l billet.actionable.work/application=report";
    require(
        &format!("{kubectl} wait --for=condition=Complete job {report} --timeout=120s"),
        &[
            format!("{kubectl} describe pods"),
            format!("{kubectl} logs {report} --all-containers=true"),
        ],
    );
    let completed = json(&format!(
        "{kubectl} get pods {report} --field-selector=status.phase=Succeeded -o json"
    ));
    let pod = single(items(&completed["items"]).clone());
    let logs = succeed(&format!(
        "{kubectl} logs {}",
        text(&pod["metadata"]["name"])
    ));
    let last = logs
        .lines()
        .last()
        .unwrap_or_else(|| panic!("no report output"));
    assert_eq!(
        parse(last),
        json!({"items": [{"inStock": true, "sku": "notebook"}]}),
        "{logs}"
    );
}
