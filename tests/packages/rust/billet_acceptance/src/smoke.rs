use crate::common::*;
use serde_json::Value;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

struct Outcome {
    code: Option<i32>,
    stdout: String,
    stderr: String,
}
fn execute(program: &str, args: &[&str], seconds: u64) -> Result<Outcome> {
    let temporary = Temporary::new()?;
    let stdout = temporary.0.join("stdout");
    let stderr = temporary.0.join("stderr");
    let mut child = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(std::fs::File::create(&stdout)?)
        .stderr(std::fs::File::create(&stderr)?)
        .spawn()?;
    let deadline = Instant::now() + Duration::from_secs(seconds);
    loop {
        if let Some(status) = child.try_wait()? {
            return Ok(Outcome {
                code: status.code(),
                stdout: std::fs::read_to_string(stdout)?,
                stderr: std::fs::read_to_string(stderr)?,
            });
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            return Err(format!("{program}: fixture command timed out").into());
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}
fn docker(args: &[&str]) -> Result<Outcome> {
    execute("docker", args, 30)
}
fn checked(outcome: Outcome) -> Result<Outcome> {
    check(outcome.code == Some(0), &outcome.stderr)?;
    Ok(outcome)
}

struct Fixture<'a> {
    image: &'a Path,
    id: String,
    token: String,
    tag: String,
    container: String,
    loaded: bool,
    created: bool,
}
impl Fixture<'_> {
    fn launch(&mut self) -> Result {
        if docker(&["image", "inspect", &self.id])?.code != Some(0) {
            self.loaded = true;
            checked(execute(
                "skopeo",
                &[
                    "--insecure-policy",
                    "copy",
                    &format!("oci:{}:billet", self.image.display()),
                    &format!("docker-daemon:{}", self.tag),
                ],
                120,
            )?)?;
        }
        self.created = true;
        checked(docker(&[
            "create",
            "--pull",
            "never",
            "--name",
            &self.container,
            "--label",
            &format!("org.actionable-work.billet.fixture={}", self.token),
            "--network",
            "none",
            "--read-only",
            "--cap-drop",
            "ALL",
            "--security-opt",
            "no-new-privileges",
            "--pids-limit",
            "64",
            "--memory",
            "128m",
            "--cpus",
            "1",
            &self.id,
        ])?)?;
        let result = checked(execute(
            "docker",
            &["start", "--attach", &self.container],
            15,
        )?)?;
        let state = checked(docker(&[
            "inspect",
            "--format",
            "{{json .State}}",
            &self.container,
        ])?)?;
        let state: Value = serde_json::from_str(&state.stdout)?;
        check(
            state["Running"] == false && state["ExitCode"] == 0,
            "image smoke did not exit successfully",
        )?;
        print!("{}", result.stdout);
        eprint!("{}", result.stderr);
        Ok(())
    }
    fn cleanup_container(&self) -> Result {
        if self.created {
            let labels = docker(&[
                "inspect",
                "--format",
                "{{json .Config.Labels}}",
                &self.container,
            ])?;
            if labels.code == Some(0) {
                let labels: Value = serde_json::from_str(&labels.stdout)?;
                if labels["org.actionable-work.billet.fixture"] == self.token {
                    checked(docker(&["rm", "--force", &self.container])?)?;
                }
            }
        }
        Ok(())
    }
    fn cleanup_image(&self) -> Result {
        if self.loaded {
            if docker(&["image", "inspect", &self.tag])?.code == Some(0) {
                checked(docker(&["image", "rm", &self.tag])?)?;
            } else {
                let tags = docker(&[
                    "image",
                    "inspect",
                    "--format",
                    "{{json .RepoTags}}",
                    &self.id,
                ])?;
                if tags.code == Some(0)
                    && serde_json::from_str::<Value>(&tags.stdout)?
                        .as_array()
                        .is_none_or(|a| a.is_empty())
                {
                    checked(docker(&["image", "rm", &self.id])?)?;
                }
            }
        }
        Ok(())
    }
}

pub fn run(image: &Path) -> Result {
    let image = image.canonicalize()?;
    let index = json(image.join("index.json"))?;
    let manifest = json(
        image.join("blobs/sha256").join(
            text(&index["manifests"][0]["digest"])
                .strip_prefix("sha256:")
                .ok_or("unsupported image digest")?,
        ),
    )?;
    let temporary = Temporary::new()?;
    let token = temporary
        .0
        .file_name()
        .unwrap()
        .to_string_lossy()
        .into_owned();
    let mut fixture = Fixture {
        image: &image,
        id: text(&manifest["config"]["digest"]).to_owned(),
        tag: format!("billet-smoke:{token}"),
        container: format!("billet-smoke-{token}"),
        token,
        loaded: false,
        created: false,
    };
    checked(docker(&["version", "--format", "{{.Server.Version}}"])?)?;
    let result = fixture.launch();
    let container_cleanup = fixture.cleanup_container();
    let image_cleanup = fixture.cleanup_image();
    result?;
    container_cleanup?;
    image_cleanup?;
    println!(
        "nix2container OCI image smoke passed and fixtures cleaned; Compose conformance remains separately gated"
    );
    Ok(())
}
