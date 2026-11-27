//! `billet:guestbook-compose`: the stateful guestbook example runs under Docker
//! Compose.
use billet_vm::guest::require;
use billet_vm::guest::{
    Params, items, json, keys, read_json, section, set, single, succeed, text, wait_until_succeeds,
};
use billet_vm::guestbook::{Secrets, create, entries, pair, quote, request, secrets, settle};
use serde_json::{Value, json};

struct Compose<'a> {
    p: &'a Params,
    s: Secrets,
}

impl Compose<'_> {
    fn compose(&self, args: &str) -> String {
        format!("{} {args}", self.p.s("compose"))
    }

    fn docker(&self, args: &str) -> String {
        format!("{} {args}", self.p.s("docker"))
    }

    fn inspect(&self, service: &str) -> Value {
        let container = single(
            succeed(&self.compose(&format!("ps --all --quiet {service}")))
                .split_whitespace()
                .map(str::to_owned)
                .collect(),
        );
        json(&self.docker(&format!("inspect {container}")))[0].clone()
    }

    fn url(&self) -> String {
        let address = succeed(&self.compose("port guestbook 8080"));
        let port = address
            .lines()
            .next()
            .and_then(|line| line.rsplit_once(':'))
            .expect("published port")
            .1;
        format!("http://127.0.0.1:{port}")
    }

    fn ready(&self) {
        settle(&[self.url()]);
    }

    fn manifest(&self) -> Value {
        read_json(&format!("{}/manifests/guestbook.json", self.p.s("bundle")))
    }

    fn copy(&self, container: &Value, path: &str) -> String {
        succeed(&self.docker(&format!(
            "cp {}:{path} - | tar -xOf -",
            text(&container["Id"])
        )))
    }
}

fn compose_report(c: &Compose) {
    let report = c.p.v("report");
    assert_eq!(report["canRender"], true);
    let warnings: Vec<(&str, &str)> = items(&report["diagnostics"])
        .iter()
        .filter(|d| d["severity"] == "warning")
        .map(|d| (text(&d["code"]), text(&d["field"])))
        .collect();
    for warning in [
        (
            "UnsupportedComposeNetworkProbe",
            "services.guestbook.probes.readiness.type",
        ),
        (
            "UnsupportedComposeNetworkProbe",
            "services.guestbook.probes.liveness.type",
        ),
        (
            "UnsupportedComposeInitialization",
            "services.guestbook.initialization.steps",
        ),
    ] {
        assert!(warnings.contains(&warning), "{warnings:?}");
    }
    let manifest = c.manifest();
    let probe = |role: &str| {
        let probe = &manifest["probes"][role];
        [
            probe["type"].clone(),
            probe["path"].clone(),
            probe["port"].clone(),
        ]
    };
    assert_eq!(
        probe("readiness"),
        [json!("http"), json!("/readyz"), json!("http")]
    );
    assert_eq!(
        probe("liveness"),
        [json!("http"), json!("/healthz"), json!("http")]
    );
    let step = single(items(&manifest["initialization"]["steps"]).clone());
    assert_eq!(step["id"], "migrate");
    assert_eq!(step["argv"], json!(["migrate"]));
}

fn compose_config(c: &Compose) {
    let config = json(&c.compose("config --format json"));
    let (app, db) = (
        &config["services"]["guestbook"],
        &config["services"]["postgres"],
    );
    assert_eq!(
        app["depends_on"]["postgres"]["condition"],
        "service_healthy"
    );
    assert!(app.get("healthcheck").is_none());
    assert!(text(&db["healthcheck"]["test"][1]).ends_with("/bin/pg_isready"));
    assert_eq!(app["ports"][0]["target"], 8080);
    assert!(db.get("ports").is_none());
    assert_eq!(keys(&db["networks"]), set(&["billet-internal"]));
    assert_eq!(
        keys(&app["networks"]),
        set(&["billet-internal", "billet-egress"])
    );
    assert_eq!(
        [&app["stop_signal"], &app["restart"], &db["stop_signal"]],
        [&json!("SIGTERM"), &json!("on-failure:3"), &json!("SIGINT")]
    );
    assert_eq!(
        app["environment"]["GUESTBOOK_DATABASE_PASSWORD"],
        c.s.password
    );
    let targets = |service: &Value| {
        items(&service["secrets"])
            .iter()
            .map(|secret| secret["target"].clone())
            .collect::<Vec<_>>()
    };
    assert_eq!(targets(app), [json!("/run/secrets/guestbook/session-key")]);
    assert_eq!(targets(db), [json!("/run/secrets/postgres/password")]);
    let volume = single(items(&db["volumes"]).clone());
    assert_eq!(
        (&volume["type"], &volume["target"]),
        (&json!("volume"), &json!("/var/lib/postgresql"))
    );
}

fn migration(c: &Compose) -> String {
    let step = single(items(&c.manifest()["initialization"]["steps"]).clone());
    let argv: Vec<String> = items(&step["argv"])
        .iter()
        .map(|arg| quote(text(arg)))
        .collect();
    c.compose(&format!(
        "run --rm --no-deps --entrypoint {} guestbook {} 2>&1",
        text(&step["executable"]),
        argv.join(" ")
    ))
}

fn compose_readiness(c: &Compose) {
    section("readiness waits for the migration");
    for name in ["guestbook", "postgres"] {
        succeed(&c.docker(&format!(
            "image load --input {}/images/{name}.tar",
            c.p.s("bundle")
        )));
    }
    require(
        &c.compose("up --no-build --detach 2>&1"),
        &[c.compose("logs")],
    );
    assert_eq!(
        c.inspect("postgres")["State"]["Health"]["Status"],
        "healthy"
    );
    wait_until_succeeds(&format!("curl -fsS {}/healthz", c.url()), 60);
    let (status, body) = request(&format!("{}/readyz", c.url()), None);
    assert!(status == 503 && body["ready"] == false, "{body}");
    // Compose does not map initialization; the fixture runs the manifest's
    // step the way a consumer would before each start.
    assert!(succeed(&migration(c)).contains("applied migration 1"));
    assert!(succeed(&migration(c)).contains("schema already at version 1"));
    c.ready();
    assert_eq!(
        request(&format!("{}/readyz", c.url()), None),
        (200, json!({"ready": true, "schema": 1}))
    );
}

fn compose_secrets(c: &Compose) {
    section("secrets arrive at their declared targets");
    let app = c.inspect("guestbook");
    let env = format!("GUESTBOOK_DATABASE_PASSWORD={}", c.s.password);
    assert!(items(&app["Config"]["Env"]).contains(&json!(env)));
    assert_eq!(c.copy(&app, "/run/secrets/guestbook/session-key"), c.s.key);
    assert_eq!(
        c.copy(&c.inspect("postgres"), "/run/secrets/postgres/password"),
        c.s.password
    );
    create(&c.url(), &c.s.key, "ada", "hello from compose");
}

fn compose_bodies(c: &Compose) {
    section("malformed and oversized bodies are rejected");
    let url = c.url();
    assert_eq!(
        request(&format!("{url}/entries"), Some(&json!({"author": "ada"}))).0,
        400
    );
    // Only headers are sent; the server answers without reading a body.
    for (length, expected) in [("70000", "413"), ("-1", "400"), ("many", "411")] {
        let status = succeed(&format!(
            "curl -sS -o /dev/null -w '%{{http_code}}' -X POST -H 'Content-Length: {length}' {url}/entries"
        ));
        assert_eq!(status, expected, "Content-Length {length}");
    }
}

fn compose_restarts(c: &Compose) {
    section("entries survive restarts");
    let expected = pair("ada", "hello from compose");
    for service in ["guestbook", "postgres"] {
        succeed(&c.compose(&format!("restart {service}")));
        c.ready();
        assert_eq!(entries(&c.url(), &c.s.key), expected);
    }
    succeed(&c.compose("down"));
    succeed(&c.docker("volume inspect guestbook_postgres__data"));
    succeed(&c.compose("up --no-build --detach"));
    c.ready();
    assert_eq!(entries(&c.url(), &c.s.key), expected);
}

fn compose_volume_root(c: &Compose) {
    section("the database leaves its volume root unchanged");
    let id = text(&c.inspect("postgres")["Id"]).to_owned();
    let stat = |path: &str| {
        succeed(&c.docker(&format!(
            "exec {id} {}/bin/stat -c '%u:%g %a' {path}",
            c.p.s("coreutils")
        )))
    };
    assert!(stat("/var/lib/postgresql").starts_with("0:0 "));
    assert!(
        stat("/var/lib/postgresql/pg")
            .trim()
            .starts_with("65534:65534 ")
    );
    assert_eq!(
        stat("/var/lib/postgresql/pg/data").trim(),
        "65534:65534 700"
    );
}

fn compose_signals(c: &Compose) {
    section("services stop on their declared signals");
    let (app, db) = (c.inspect("guestbook"), c.inspect("postgres"));
    let stop = |info: &Value| {
        (
            info["Config"]["StopSignal"].clone(),
            info["Config"]["StopTimeout"].clone(),
        )
    };
    assert_eq!(stop(&app), (json!("SIGTERM"), json!(15)));
    assert_eq!(stop(&db), (json!("SIGINT"), json!(60)));
    assert_eq!(
        app["HostConfig"]["RestartPolicy"],
        json!({"Name": "on-failure", "MaximumRetryCount": 3})
    );
    succeed(&c.compose("stop guestbook postgres"));
    assert_eq!(c.inspect("guestbook")["State"]["ExitCode"], 0);
    assert_eq!(c.inspect("postgres")["State"]["ExitCode"], 0);
    let logs = succeed(&c.compose("logs guestbook postgres 2>&1"));
    assert!(logs.contains("received SIGTERM; shutting down"), "{logs}");
    assert!(logs.contains("received fast shutdown request"), "{logs}");
    succeed(&c.compose("down --volumes"));
    assert_eq!(succeed(&c.docker("ps -aq")).trim(), "");
}

pub fn compose(p: &Params) {
    let c = Compose { p, s: secrets() };
    section("the project renders the stateful settings");
    compose_report(&c);
    compose_config(&c);
    compose_readiness(&c);
    compose_secrets(&c);
    compose_bodies(&c);
    compose_restarts(&c);
    compose_volume_root(&c);
    compose_signals(&c);
}
