//! `billet:compose-artifact`: Docker Compose consumes Billet artifacts.
use billet_vm::guest::{
    Params, fail, items, json, keys, lacks, parse, read, read_json, section, set, single, succeed,
    text, wait_until_succeeds,
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

const HELLO_ENV: &str = r#"env BILLET_SECRET_hello__database="$(cat /tmp/file-secret)" BILLET_SECRET_hello__token="$(cat /tmp/env-secret)""#;
const INVENTORY: &str = r#"{"items":[{"inStock":true,"sku":"notebook"}]}"#;

struct Compose<'a> {
    p: &'a Params,
}

impl Compose<'_> {
    fn docker(&self, args: &str) -> String {
        format!("{} {args}", self.p.s("docker"))
    }

    fn inspect(&self, container: &str) -> Value {
        json(&self.docker(&format!("inspect {container}")))[0].clone()
    }

    fn containers(&self, command: &str, name: &str) -> Vec<String> {
        succeed(&format!("{command} ps --all --quiet {name}"))
            .split_whitespace()
            .map(str::to_owned)
            .collect()
    }

    fn exec(&self, container: &str, tool: &str, args: &str) -> String {
        self.docker(&format!(
            "exec {container} {}/bin/{tool} {args}",
            self.p.s("coreutils")
        ))
    }

    fn assert_empty(&self) {
        assert_eq!(succeed(&self.docker("ps -aq")).trim(), "");
    }

    fn hello(&self) -> String {
        format!(
            "{} --project-name billet-artifact -f {}/compose.yaml",
            self.p.s("cli"),
            self.p.s("bundle")
        )
    }

    fn hello_with_secrets(&self) -> String {
        format!("{HELLO_ENV} {}", self.hello())
    }

    fn native(&self) -> String {
        format!(
            r#"env BILLET_SECRET_db_Happ__shared="$(cat /tmp/file-secret)" BILLET_SECRET_worker__shared="$(cat /tmp/env-secret)" BILLET_SECRET_worker__optional= {} --project-name billet-native -f {}/compose.yaml"#,
            self.p.s("cli"),
            self.p.s("nativeBundle")
        )
    }

    fn project(&self) -> String {
        format!(
            "{} --project-name billet-catalog-report -f {}/compose.yaml",
            self.p.s("cli"),
            self.p.s("catalogReport")
        )
    }
}

fn secret(name: &str) -> String {
    read(&format!("/tmp/{name}")).trim().to_owned()
}

fn manifest_contract(c: &Compose) {
    let bundle = c.p.s("bundle");
    succeed(&format!(
        "cmp {} {bundle}/manifest.json",
        c.p.s("fixtureManifest")
    ));
    let manifest = read_json(&format!("{bundle}/manifest.json"));
    assert_eq!(manifest["rollout"]["minReadySeconds"], 23);
    assert_eq!(
        manifest["secrets"]["database"],
        json!({"external": "runtime/database", "mode": "file", "target": "/run/secrets/database", "required": true})
    );
}

fn rendered_contract(c: &Compose) {
    let rendered = read_json(&format!("{}/compose.yaml", c.p.s("bundle")));
    assert_eq!(keys(&rendered["services"]), set(&["hello"]));
    let hello = &rendered["services"]["hello"];
    assert_eq!(hello["image"], c.p.s("reference"));
    assert_eq!(hello["pull_policy"], "never");
    lacks(hello, &["entrypoint", "command", "user", "working_dir"]);
    assert_eq!(
        rendered["x-billet"],
        json!({"manifest": "./manifest.json", "manifestDigest": c.p.s("digest")})
    );
    assert_eq!(
        rendered["secrets"],
        json!({"hello__database": {"environment": "BILLET_SECRET_hello__database"}})
    );
    assert_eq!(
        hello["secrets"],
        json!([{"source": "hello__database", "target": "/run/secrets/database", "uid": "65534", "gid": "65534", "mode": 256}])
    );
    assert!(text(&hello["environment"]["APP_TOKEN"]).starts_with("${BILLET_SECRET_hello__token:?"));
    assert_eq!(
        hello["environment"]["APP_OPTIONAL"],
        "${BILLET_SECRET_hello__optional:-}"
    );
}

fn required_secret(c: &Compose) {
    let compose = c.hello();
    let missing = fail(&format!(
        "env -u BILLET_SECRET_hello__token {compose} config --quiet 2>&1"
    ));
    assert!(missing.contains("BILLET_SECRET_hello__token"), "{missing}");
    let empty = fail(&format!(
        "env BILLET_SECRET_hello__token= {compose} config --quiet 2>&1"
    ));
    assert!(empty.contains("BILLET_SECRET_hello__token"), "{empty}");
}

fn hello_image(c: &Compose) {
    let bundle = c.p.s("bundle");
    succeed(&c.docker(&format!("image load --input {bundle}/image.tar")));
    let image = json(&c.docker(&format!("image inspect {}", c.p.s("reference"))));
    assert_eq!(
        image[0]["Config"]["Labels"]["org.actionable-work.billet.manifest-digest"],
        c.p.s("digest")
    );
    let config = json(&format!("{} config --format json", c.hello_with_secrets()));
    let manifest = read_json(&format!("{bundle}/manifest.json"));
    assert_eq!(
        keys(&config["services"]),
        set(&[text(&manifest["identity"]["name"])])
    );
    let hello = &config["services"]["hello"];
    assert_eq!(hello["image"], c.p.s("reference"));
    assert_eq!(hello["pull_policy"], "never");
    assert_eq!(
        hello["environment"],
        json!({"APP_TOKEN": secret("env-secret"), "APP_OPTIONAL": ""})
    );
}

fn hello_run(c: &Compose) {
    let compose = c.hello_with_secrets();
    let output = succeed(&format!(
        "{compose} up --no-build --exit-code-from hello 2>&1"
    ));
    assert!(output.contains("Hello from Billet"), "{output}");
    let id = single(c.containers(&compose, "hello"));
    let info = c.inspect(&id);
    assert_eq!(info["RestartCount"], 0);
    let env: Vec<&str> = items(&info["Config"]["Env"]).iter().map(text).collect();
    assert!(
        env.contains(&format!("APP_TOKEN={}", secret("env-secret")).as_str()),
        "{env:?}"
    );
    assert!(env.contains(&"APP_OPTIONAL="), "{env:?}");
    let copied = succeed(&c.docker(&format!("cp {id}:/run/secrets/database - | tar -xOf -")));
    assert_eq!(copied, secret("file-secret"));
    succeed(&format!("{compose} down --volumes"));
    c.assert_empty();
}

fn catalog_member(c: &Compose, rendered: &Value, parsed: &Value, name: &str) {
    let report = c.p.s("catalogReport");
    let metadata = &rendered["x-billet"]["services"][name];
    assert_eq!(metadata["manifest"], format!("./manifests/{name}.json"));
    let manifest = read(&format!("{report}/manifests/{name}.json"));
    assert_eq!(parse(&manifest)["identity"]["name"], name);
    let digest = format!("sha256:{:x}", Sha256::digest(manifest.as_bytes()));
    assert_eq!(metadata["manifestDigest"], digest);
    let image = text(&parsed["services"][name]["image"]);
    succeed(&c.docker(&format!("image load --input {report}/images/{name}.tar")));
    let inspection = json(&c.docker(&format!("image inspect {image}")));
    let config = &inspection[0]["Config"];
    assert_eq!(
        config["Labels"]["org.actionable-work.billet.manifest-digest"],
        digest
    );
    if name == "catalog" {
        assert_eq!(config["Entrypoint"], json!([c.p.s("catalogExecutable")]));
    }
}

fn catalog_network(c: &Compose) {
    section("independent Billets share the Compose network");
    let rendered = read_json(&format!("{}/compose.yaml", c.p.s("catalogReport")));
    let parsed = json(&format!("{} config --format json", c.project()));
    let services = set(&["catalog", "report"]);
    assert_eq!(keys(&parsed["services"]), services);
    assert_eq!(keys(&rendered["x-billet"]["services"]), services);
    for name in &services {
        catalog_member(c, &rendered, &parsed, name);
    }
    let report = succeed(&format!(
        "{} up --no-build --exit-code-from report 2>&1",
        c.project()
    ));
    assert!(report.contains(INVENTORY), "{report}");
    succeed(&format!("{} down --volumes", c.project()));
    c.assert_empty();
}

/// A JSON number or numeric string, as Compose may print either.
fn number(value: &Value) -> f64 {
    value
        .as_f64()
        .or_else(|| value.as_str().and_then(|text| text.parse().ok()))
        .unwrap_or_else(|| panic!("not a number: {value}"))
}

fn native_resources(services: &Value) {
    let (server, client) = (&services["db-app"], &services["worker"]);
    let limits = &server["deploy"]["resources"]["limits"];
    let reservations = &server["deploy"]["resources"]["reservations"];
    assert!(
        (number(&limits["cpus"]) - 0.625).abs() < f64::EPSILON,
        "{limits}"
    );
    assert!(
        (number(&limits["memory"]) - 67_108_864.0).abs() < f64::EPSILON,
        "{limits}"
    );
    assert!(
        (number(&reservations["cpus"]) - 0.125).abs() < f64::EPSILON,
        "{reservations}"
    );
    assert!(
        (number(&reservations["memory"]) - 16_777_216.0).abs() < f64::EPSILON,
        "{reservations}"
    );
    let replicas =
        [server, client, &services["idle"]].map(|service| service["deploy"]["replicas"].clone());
    assert_eq!(replicas, [json!(1), json!(2), json!(0)]);
    assert_eq!(
        (&server["stop_signal"], &server["stop_grace_period"]),
        (&json!("SIGINT"), &json!("7s"))
    );
    assert_eq!(server["restart"], "on-failure:2");
    assert_eq!(client["restart"], "no");
    assert_eq!(services["idle"]["restart"], "no");
}

fn native_health(c: &Compose, project_file: &Value, services: &Value) {
    let (server, client) = (&services["db-app"], &services["worker"]);
    assert_eq!(
        project_file["services"]["db-app"]["healthcheck"]["test"][3],
        "$$HOME"
    );
    assert_eq!(
        server["healthcheck"],
        json!({"test": ["CMD", c.p.s("readiness"), "", "$$HOME", "a; b"], "interval": "2s", "timeout": "1s", "retries": 4, "start_period": "6s"})
    );
    assert_eq!(
        client["healthcheck"]["test"],
        json!(["CMD", format!("{}/bin/true", c.p.s("coreutils"))])
    );
    assert_eq!(client["healthcheck"]["start_period"], "15s");
    lacks(&services["failer"], &["healthcheck"]);
    lacks(&services["idle"], &["healthcheck"]);
    assert_eq!(keys(&client["depends_on"]), set(&["db-app"]));
    assert_eq!(
        client["depends_on"]["db-app"]["condition"],
        "service_healthy"
    );
}

fn native_network(config: &Value) {
    let services = &config["services"];
    let (server, client) = (&services["db-app"], &services["worker"]);
    assert_eq!(
        keys(&config["networks"]),
        set(&["billet-internal", "billet-egress"])
    );
    assert_eq!(config["networks"]["billet-internal"]["internal"], true);
    assert_ne!(config["networks"]["billet-egress"]["internal"], true);
    assert_eq!(
        keys(&server["networks"]),
        set(&["billet-internal", "billet-egress"])
    );
    assert_eq!(keys(&client["networks"]), set(&["billet-internal"]));
    assert_eq!(server["ports"][0]["target"], 8080);
    assert_eq!(server["ports"][0]["protocol"], "tcp");
    assert_eq!(server["expose"], json!(["9090"]));
    assert_eq!(client["expose"], json!(["8081"]));
    lacks(client, &["ports"]);
    assert_eq!(
        keys(&config["secrets"]),
        set(&["db_Happ__shared", "worker__optional", "worker__shared"])
    );
    assert_eq!(
        keys(&config["volumes"]),
        set(&["db_Happ__state", "worker__state"])
    );
    assert_eq!(keys(services).len(), 4);
}

fn native_manifests(c: &Compose) {
    let manifest =
        |name: &str| read_json(&format!("{}/manifests/{name}.json", c.p.s("nativeBundle")));
    let (worker, server, idle) = (manifest("worker"), manifest("db-app"), manifest("idle"));
    assert_eq!(worker["resources"]["replicas"]["max"], 3);
    assert_eq!(worker["resources"]["targetMetric"], "fixture-metric");
    assert_eq!(worker["resources"]["placement"], json!(["fixture-zone"]));
    assert_eq!(idle["resources"]["strictSingleton"], true);
    assert_eq!(items(&worker["network"]["privateConnections"]).len(), 2);
    assert_eq!(server["rollout"]["minReadySeconds"], 42);
    assert_eq!(
        server["network"]["egressRestrictions"],
        json!(["fixture-restriction"])
    );
    assert_eq!(server["initialization"]["steps"][0]["id"], "prepare");
    assert_eq!(server["storage"]["state"]["driverClass"], "fixture-driver");
    assert_eq!(server["storage"]["state"]["sizeBytes"], 1_048_576);
    assert_eq!(worker["storage"]["state"]["accessMode"], "readOnlyMany");
    assert_eq!(server["secrets"]["shared"]["external"], "runtime/shared");
    let restart = &server["restart"];
    assert_eq!(
        [
            &restart["initialDelaySeconds"],
            &restart["maxDelaySeconds"],
            &restart["multiplier"]
        ],
        [&json!(1), &json!(30), &json!(2)]
    );
    assert_eq!(restart["jitter"], true);
    assert_eq!(restart["continuousReadyResetSeconds"], 300);
}

fn manifest_only_intent(project_file: &Value, services: &Value) {
    lacks(&services["db-app"], &["init", "post_start", "pre_stop"]);
    lacks(
        &project_file["services"]["db-app"]["deploy"],
        &[
            "placement",
            "update_config",
            "rollback_config",
            "restart_policy",
        ],
    );
    lacks(
        &project_file["services"]["worker"]["deploy"],
        &["placement", "update_config"],
    );
}

fn capability_set(report: &Value, field: &str) -> std::collections::BTreeSet<String> {
    items(&report[field])
        .iter()
        .map(|item| text(item).to_owned())
        .collect()
}

fn native_report(c: &Compose) {
    let report = c.p.v("nativeReport");
    assert_eq!(report["canRender"], true);
    assert_eq!(
        capability_set(report, "supportedCapabilities"),
        set(&[
            "resources",
            "replicas",
            "shutdown",
            "restart",
            "probes",
            "runtime-secrets",
            "network-ports",
            "network-egress-isolation",
            "readiness-dependencies",
            "storage-ephemeral-memory",
            "storage-ephemeral-disk",
            "storage-persistent-disk"
        ])
    );
    assert!(
        !capability_set(&report["services"]["idle"], "supportedCapabilities").contains("probes")
    );
    assert_eq!(
        capability_set(&report["services"]["db-app"], "supportedCapabilities"),
        set(&[
            "resources",
            "replicas",
            "shutdown",
            "restart",
            "probes",
            "runtime-secrets",
            "network-ports",
            "storage-ephemeral-memory",
            "storage-ephemeral-disk",
            "storage-persistent-disk"
        ])
    );
    let members = report["services"].as_object().expect("member reports");
    let required: std::collections::BTreeSet<String> = members
        .values()
        .flat_map(|member| capability_set(member, "requiredCapabilities"))
        .collect();
    assert_eq!(capability_set(report, "requiredCapabilities"), required);
}

fn native_warnings(c: &Compose) {
    let report = c.p.v("nativeReport");
    let diagnostics: Vec<(&str, &str, &str)> = items(&report["diagnostics"])
        .iter()
        .map(|d| (text(&d["code"]), text(&d["field"]), text(&d["severity"])))
        .collect();
    for (code, field) in [
        ("ComposeCPUReservation", "db-app.resources.cpuRequest"),
        ("ComposeReplicaRange", "worker.resources.replicas.max"),
        (
            "UnsupportedComposeNetworkProbe",
            "worker.probes.readiness.type",
        ),
        (
            "UnsupportedComposeNetworkProbe",
            "failer.probes.liveness.type",
        ),
        (
            "UnsupportedComposeNetworkProbe",
            "idle.probes.readiness.type",
        ),
        (
            "UnsupportedComposeInitialization",
            "db-app.initialization.steps",
        ),
        ("ComposeInternalPort", "worker.network.ports.http.exposure"),
        (
            "ComposeOptionalFileSecret",
            "worker.secrets.optional.required",
        ),
        ("ComposeDiskQuota", "db-app.storage.work.sizeBytes"),
        ("ComposeDiskQuota", "db-app.storage.state.sizeBytes"),
    ] {
        let field = format!("services.{field}");
        assert!(
            diagnostics.contains(&(code, field.as_str(), "warning")),
            "missing {code} at {field}"
        );
    }
}

fn isolated_and_cyclic(c: &Compose) {
    let cli = c.p.s("cli");
    let isolated = json(&format!(
        "{cli} -p billet-isolated -f {} config --format json",
        c.p.s("isolatedFile")
    ));
    assert_eq!(isolated["services"]["isolated"]["restart"], "no");
    assert_eq!(
        keys(&isolated["services"]["isolated"]["networks"]),
        set(&["billet-internal"])
    );
    assert_eq!(keys(&isolated["networks"]), set(&["billet-internal"]));
    assert_eq!(isolated["networks"]["billet-internal"]["internal"], true);
    let cyclic = json(&format!(
        "{cli} -p billet-cycle -f {} config --format json",
        c.p.s("cyclicFile")
    ));
    for member in cyclic["services"].as_object().expect("services").values() {
        lacks(member, &["depends_on"]);
    }
    let report = c.p.v("cyclicReport");
    assert_eq!(report["canRender"], true);
    let fields: std::collections::BTreeSet<String> = items(&report["diagnostics"])
        .iter()
        .filter(|d| d["code"] == "ComposeReadinessCycle")
        .map(|d| text(&d["field"]).to_owned())
        .collect();
    assert_eq!(
        fields,
        set(&[
            "services.left.network.privateConnections",
            "services.right.network.privateConnections"
        ])
    );
}

fn native_directives(c: &Compose) {
    section("Compose parses native directives and preserves manifest-only intent");
    let project_file = read_json(&format!("{}/compose.yaml", c.p.s("nativeBundle")));
    let config = json(&format!("{} config --format json", c.native()));
    let services = &config["services"];
    native_resources(services);
    native_health(c, &project_file, services);
    native_network(&config);
    native_manifests(c);
    manifest_only_intent(&project_file, services);
    native_report(c);
    native_warnings(c);
    isolated_and_cyclic(c);
}

fn has_default_route(route: &str) -> bool {
    route
        .lines()
        .skip(1)
        .any(|line| line.split_whitespace().nth(1) == Some("00000000"))
}

fn db_limits(info: &Value) {
    let host = &info["HostConfig"];
    assert_eq!(host["NanoCpus"], 625_000_000);
    assert_eq!(host["Memory"], 67_108_864);
    assert_eq!(host["MemoryReservation"], 16_777_216);
    assert_eq!(info["Config"]["StopSignal"], "SIGINT");
    assert_eq!(info["Config"]["StopTimeout"], 7);
    assert!(items(&info["Config"]["Env"]).contains(&json!("MARKER=from-image")));
}

fn db_health(c: &Compose, info: &Value) {
    assert_eq!(info["State"]["Health"]["Status"], "healthy");
    let health = &info["Config"]["Healthcheck"];
    assert_eq!(
        health["Test"],
        json!(["CMD", c.p.s("readiness"), "", "$HOME", "a; b"])
    );
    let timing = [
        &health["Interval"],
        &health["Timeout"],
        &health["Retries"],
        &health["StartPeriod"],
    ];
    assert_eq!(
        timing,
        [
            &json!(2_000_000_000_i64),
            &json!(1_000_000_000_i64),
            &json!(4),
            &json!(6_000_000_000_i64)
        ]
    );
}

fn db_network(c: &Compose, db: &str, info: &Value) {
    let ports = succeed(&format!("{} port db-app 8080", c.native()));
    let port = ports
        .lines()
        .next()
        .and_then(|line| line.rsplit_once(':'))
        .expect("published port")
        .1;
    let served = succeed(&format!(
        "{} -fsS http://127.0.0.1:{port}/items.json",
        c.p.s("curl")
    ));
    assert!(served.contains(INVENTORY), "{served}");
    assert!(info["NetworkSettings"]["Ports"]["9090/tcp"].is_null());
    assert_eq!(
        keys(&info["NetworkSettings"]["Networks"]),
        set(&[
            "billet-native_billet-egress",
            "billet-native_billet-internal"
        ])
    );
    assert!(has_default_route(&succeed(&c.exec(
        db,
        "cat",
        "/proc/net/route"
    ))));
    let image = text(&info["Config"]["Image"]);
    succeed(&c.docker(&format!("run --detach --name internal-port-probe --network billet-native_billet-internal --publish 8080 {image}")));
    let probe = c.inspect("internal-port-probe");
    assert!(
        probe["NetworkSettings"]["Ports"]["8080/tcp"].is_null()
            || probe["NetworkSettings"]["Ports"]["8080/tcp"] == json!([])
    );
    succeed(&c.docker("rm --force internal-port-probe"));
}

fn mount<'v>(mounts: &'v Value, key: &str, target: &str) -> &'v Value {
    items(mounts)
        .iter()
        .find(|mount| mount[key] == target)
        .unwrap_or_else(|| panic!("no mount at {target}"))
}

fn db_storage(c: &Compose, db: &str, info: &Value) {
    let scratch = mount(&info["HostConfig"]["Mounts"], "Target", "/scratch");
    assert_eq!(scratch["Type"], "tmpfs");
    assert_eq!(scratch["TmpfsOptions"]["SizeBytes"], 1_048_576);
    let work = mount(&info["Mounts"], "Destination", "/work");
    assert_eq!(work["Type"], "volume");
    assert!(
        ![
            json!("billet-native_db_Happ__state"),
            json!("billet-native_worker__state")
        ]
        .contains(&work["Name"])
    );
    assert_eq!(
        mount(&info["Mounts"], "Destination", "/state")["Name"],
        "billet-native_db_Happ__state"
    );
    assert_eq!(
        succeed(&c.exec(db, "cat", "/etc/billet-test/shared")),
        secret("file-secret")
    );
    let mode = succeed(&c.exec(db, "stat", "-c '%u:%g:%a' /etc/billet-test/shared"));
    assert_eq!(mode.trim(), "65534:65534:400");
}

fn worker_container(c: &Compose, worker: &str) {
    let info = c.inspect(worker);
    assert_eq!(info["State"]["Running"], true);
    assert!(succeed(&c.docker(&format!("logs {worker}"))).contains(INVENTORY));
    assert_eq!(info["HostConfig"]["RestartPolicy"]["Name"], "no");
    assert_eq!(
        keys(&info["NetworkSettings"]["Networks"]),
        set(&["billet-native_billet-internal"])
    );
    assert!(info["NetworkSettings"]["Ports"]["8081/tcp"].is_null());
    assert!(!has_default_route(&succeed(&c.exec(
        worker,
        "cat",
        "/proc/net/route"
    ))));
    assert_eq!(
        succeed(&c.exec(worker, "cat", "/etc/billet-test/shared")),
        secret("env-secret")
    );
    fail(&c.exec(worker, "test", "-e /etc/billet-test/optional"));
    let volume = mount(&info["Mounts"], "Destination", "/state");
    assert_eq!(volume["Name"], "billet-native_worker__state");
    assert_eq!(volume["RW"], false);
}

fn native_enforcement(c: &Compose) {
    section("Docker enforces the native Compose directives");
    let command = c.native();
    succeed(&format!(
        r#"for archive in {}/images/*.tar; do {} image load --input "$archive"; done"#,
        c.p.s("nativeBundle"),
        c.p.s("docker")
    ));
    succeed(&format!("{command} up --no-build --detach"));
    let db = single(c.containers(&command, "db-app"));
    let workers = c.containers(&command, "worker");
    let failer = single(c.containers(&command, "failer"));
    assert_eq!(workers.len(), 2);
    assert!(c.containers(&command, "idle").is_empty());
    let info = c.inspect(&db);
    db_limits(&info);
    db_health(c, &info);
    db_network(c, &db, &info);
    db_storage(c, &db, &info);
    for worker in &workers {
        worker_container(c, worker);
    }
    let state = c.docker(&format!("inspect --format '{{{{.State.Status}}}}:{{{{.RestartCount}}}}:{{{{.State.ExitCode}}}}' {failer}"));
    wait_until_succeeds(&format!("{state} | grep -qx exited:2:7"), 900);
    assert_eq!(
        c.inspect(&failer)["HostConfig"]["RestartPolicy"],
        json!({"Name": "on-failure", "MaximumRetryCount": 2})
    );
    succeed(&format!("{command} down"));
    succeed(&c.docker("volume inspect billet-native_db_Happ__state billet-native_worker__state"));
    succeed(&format!("{command} down --volumes"));
    c.assert_empty();
}

fn upgrade_logs(c: &Compose, container: &str, version: &str) {
    let line = format!("BILLET_UPGRADE {version}");
    wait_until_succeeds(
        &format!(
            "{} | grep -qx '{line}'",
            c.docker(&format!("logs {container}"))
        ),
        30,
    );
    std::thread::sleep(std::time::Duration::from_secs(2));
    assert_eq!(
        succeed(&c.docker(&format!("logs {container} 2>&1"))),
        format!("{line}\n")
    );
}

fn upgrade(c: &Compose) {
    section("Compose accepts a second Billet version");
    let first_command = format!(
        "{} --project-name billet-upgrade -f {}",
        c.p.s("cli"),
        c.p.s("upgradeV1File")
    );
    let second_command = format!(
        "{} --project-name billet-upgrade -f {}",
        c.p.s("cli"),
        c.p.s("upgradeV2File")
    );
    for image in ["upgradeV1Image", "upgradeV2Image"] {
        succeed(&c.docker(&format!("image load --input {}", c.p.s(image))));
    }
    succeed(&format!("{first_command} up --no-build --detach"));
    let first = single(c.containers(&first_command, "upgrade"));
    upgrade_logs(c, &first, "v1");
    assert_eq!(c.inspect(&first)["Config"]["Image"], c.p.s("upgradeV1Ref"));
    let parsed =
        json(&format!("{second_command} config --format json"))["services"]["upgrade"].clone();
    assert_eq!(parsed["image"], c.p.s("upgradeV2Ref"));
    assert_eq!(
        (&parsed["stop_signal"], &parsed["stop_grace_period"]),
        (&json!("SIGINT"), &json!("5s"))
    );
    succeed(&format!("{second_command} up --no-build --detach"));
    let second = single(c.containers(&second_command, "upgrade"));
    assert_ne!(second, first);
    fail(&c.docker(&format!("inspect {first}")));
    let info = c.inspect(&second);
    assert_eq!(info["State"]["Running"], true);
    assert_eq!(info["Config"]["Image"], c.p.s("upgradeV2Ref"));
    assert_eq!(info["Config"]["Cmd"], json!(["v2"]));
    assert_eq!(
        (
            &info["Config"]["StopSignal"],
            &info["Config"]["StopTimeout"]
        ),
        (&json!("SIGINT"), &json!(5))
    );
    upgrade_logs(c, &second, "v2");
    succeed(&format!("{second_command} down --volumes"));
    c.assert_empty();
}

pub fn run(p: &Params) {
    let c = Compose { p };
    succeed(
        "cat /proc/sys/kernel/random/uuid >/tmp/file-secret; cat /proc/sys/kernel/random/uuid >/tmp/env-secret",
    );
    manifest_contract(&c);
    rendered_contract(&c);
    required_secret(&c);
    hello_image(&c);
    hello_run(&c);
    catalog_network(&c);
    native_directives(&c);
    native_enforcement(&c);
    upgrade(&c);
}
