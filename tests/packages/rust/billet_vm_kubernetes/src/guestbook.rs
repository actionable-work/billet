//! `billet:guestbook-kubernetes`: the stateful guestbook example runs under K3s.
use billet_vm::guest::require;
use billet_vm::guest::{Params, items, json, read_json, section, single, succeed, text};
use billet_vm::guestbook::{create, entries, pair, request, secrets, settle};
use billet_vm::kubernetes::{cluster_ready, dns_ready};
use serde_json::{Value, json};

const KUBECTL: &str = "k3s kubectl -n guestbook";
const SELECTOR: &str = "-l billet.actionable.work/application";

fn resource<'v>(resources: &'v [Value], kind: &str, name: &str) -> &'v Value {
    resources
        .iter()
        .find(|item| item["kind"] == kind && item["metadata"]["name"] == name)
        .unwrap_or_else(|| panic!("no {kind} {name}"))
}

fn kubernetes_app(resources: &[Value]) {
    let app = &resource(resources, "Deployment", "guestbook")["spec"];
    let pod = &app["template"]["spec"];
    let container = single(items(&pod["containers"]).clone());
    assert_eq!(app["replicas"], 2);
    assert_eq!(
        app["strategy"],
        json!({"type": "RollingUpdate", "rollingUpdate": {"maxSurge": 1, "maxUnavailable": 0}})
    );
    let timing = [
        &app["minReadySeconds"],
        &app["progressDeadlineSeconds"],
        &pod["terminationGracePeriodSeconds"],
    ];
    assert_eq!(timing, [&json!(10), &json!(180), &json!(30)]);
    let probe = |path: &str, period: u8| json!({"httpGet": {"path": path, "port": 8080}, "periodSeconds": period, "timeoutSeconds": 2, "failureThreshold": 3});
    assert_eq!(container["readinessProbe"], probe("/readyz", 5));
    assert_eq!(container["livenessProbe"], probe("/healthz", 10));
    let init = single(items(&pod["initContainers"]).clone());
    assert!(text(&init["command"][0]).ends_with("/bin/guestbook"));
    assert_eq!(init["args"], json!(["migrate"]));
    let password = items(&container["env"])
        .iter()
        .find(|item| item["name"] == "GUESTBOOK_DATABASE_PASSWORD")
        .expect("password variable");
    assert_eq!(
        password["valueFrom"]["secretKeyRef"],
        json!({"name": "guestbook", "key": "database-password", "optional": false})
    );
    let mounts = items(&container["volumeMounts"]);
    assert!(
        mounts
            .iter()
            .any(|mount| mount["mountPath"] == "/run/secrets/guestbook/session-key")
    );
}

fn kubernetes_db(resources: &[Value]) {
    let db = &resource(resources, "Deployment", "postgres")["spec"];
    assert_eq!(db["strategy"], json!({"type": "Recreate"}));
    assert_eq!(db["template"]["spec"]["terminationGracePeriodSeconds"], 60);
    assert!(
        text(&db["template"]["spec"]["containers"][0]["readinessProbe"]["exec"]["command"][0])
            .ends_with("/bin/pg_isready")
    );
    let claim = single(
        resources
            .iter()
            .filter(|item| item["kind"] == "PersistentVolumeClaim")
            .collect(),
    );
    assert_eq!(claim["spec"]["storageClassName"], "local-path");
    assert_eq!(claim["spec"]["accessModes"], json!(["ReadWriteOnce"]));
    let policy = &resource(resources, "NetworkPolicy", "postgres")["spec"];
    assert_eq!(policy["policyTypes"], json!(["Ingress", "Egress"]));
    assert_eq!(policy["egress"], json!([]));
    assert_eq!(
        policy["ingress"],
        json!([{"from": [{"podSelector": {"matchLabels": {"billet.actionable.work/application": "guestbook"}}}], "ports": [{"port": 5432, "protocol": "TCP"}]}])
    );
}

fn running_pods() -> Vec<Value> {
    let pods = json(&format!("{KUBECTL} get pods {SELECTOR}=guestbook -o json"));
    items(&pods["items"])
        .iter()
        .filter(|pod| {
            pod["status"]["phase"] == "Running"
                && pod["metadata"].get("deletionTimestamp").is_none()
        })
        .cloned()
        .collect()
}

fn migrations() -> Vec<String> {
    let mut logs: Vec<String> = running_pods()
        .iter()
        .map(|pod| {
            succeed(&format!(
                "{KUBECTL} logs {} -c init-0",
                text(&pod["metadata"]["name"])
            ))
        })
        .collect();
    logs.sort();
    logs
}

/// Address each replica directly rather than through the Service.
fn replicas() -> Vec<String> {
    let pods = running_pods();
    assert_eq!(pods.len(), 2, "{pods:?}");
    pods.iter()
        .map(|pod| format!("http://{}:8080", text(&pod["status"]["podIP"])))
        .collect()
}

fn kubernetes_rollout(bundle: &str) -> String {
    section("both replicas become ready after the migration");
    succeed("k3s kubectl create namespace guestbook");
    succeed(&format!(
        "{KUBECTL} create secret generic guestbook --from-file=database-password=/tmp/db-password --from-file=session-key=/tmp/session-key"
    ));
    succeed(&format!(
        "{KUBECTL} apply --server-side --validate=strict -f {bundle}/kubernetes.json"
    ));
    for name in ["postgres", "guestbook"] {
        require(
            &format!("{KUBECTL} rollout status deployment/{name} --timeout=420s"),
            &[
                format!("{KUBECTL} describe pods"),
                format!("{KUBECTL} logs {SELECTOR}={name} --all-containers=true"),
            ],
        );
    }
    let outcomes = migrations();
    assert_eq!(outcomes.len(), 2, "{outcomes:?}");
    assert_eq!(
        outcomes
            .iter()
            .filter(|log| log.contains("applied migration 1"))
            .count(),
        1,
        "{outcomes:?}"
    );
    assert_eq!(
        outcomes
            .iter()
            .filter(|log| log.contains("schema already at version 1"))
            .count(),
        1,
        "{outcomes:?}"
    );
    let url = format!(
        "http://{}:8080",
        succeed(&format!(
            "{KUBECTL} get service guestbook -o jsonpath='{{.spec.clusterIP}}'"
        ))
    );
    settle(&replicas());
    for replica in replicas() {
        assert_eq!(
            request(&format!("{replica}/readyz"), None),
            (200, json!({"ready": true, "schema": 1}))
        );
    }
    url
}

fn all_replicas_hold(key: &str, expected: &[(String, String)]) {
    settle(&replicas());
    for replica in replicas() {
        assert_eq!(entries(&replica, key), expected);
    }
}

fn kubernetes_replacement(p: &Params, key: &str) {
    section("entries survive pod replacement");
    let expected = pair("grace", "hello from k3s");
    succeed(&format!(
        "{KUBECTL} delete pod {SELECTOR}=postgres --wait=true --timeout=120s"
    ));
    succeed(&format!(
        "{KUBECTL} rollout status deployment/postgres --timeout=300s"
    ));
    all_replicas_hold(key, &expected);
    succeed(&format!("{KUBECTL} rollout restart deployment/guestbook"));
    succeed(&format!(
        "{KUBECTL} rollout status deployment/guestbook --timeout=300s"
    ));
    all_replicas_hold(key, &expected);
    assert!(
        migrations()
            .iter()
            .all(|log| log.contains("schema already at version 1"))
    );
    let owners = succeed(&format!(
        "{KUBECTL} exec deployment/postgres -- {}/bin/stat -c %u:%g /var/lib/postgresql /var/lib/postgresql/pg",
        p.s("coreutils")
    ));
    assert_eq!(
        owners.split_whitespace().collect::<Vec<_>>(),
        ["0:0", "65534:65534"],
        "{owners}"
    );
}

pub fn kubernetes(p: &Params) {
    let s = secrets();
    cluster_ready();
    let bundle = p.s("bundle");
    for name in ["guestbook", "postgres"] {
        succeed(&format!(
            "cmp {} {bundle}/manifests/{name}.json",
            text(&p.v("manifests")[name])
        ));
        succeed(&format!("k3s ctr images import {bundle}/images/{name}.tar"));
    }
    dns_ready();
    section("the manifests render probes, initialization, secrets and rollout");
    let resources = read_json(&format!("{bundle}/kubernetes.json"))["items"].clone();
    kubernetes_app(items(&resources));
    kubernetes_db(items(&resources));
    let url = kubernetes_rollout(bundle);
    section("secrets arrive through the Kubernetes Secret");
    create(&url, &s.key, "grace", "hello from k3s");
    kubernetes_replacement(p, &s.key);
}
