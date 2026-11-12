use crate::common::*;
use std::os::unix::fs::PermissionsExt;
use std::process::Command;

pub fn verify() -> Result {
    let temporary = Temporary::new()?;
    let fake = temporary.0.join("nix");
    let captured = temporary.0.join("arguments");
    std::fs::write(
        &fake,
        format!(
            "#!{}\nprintf '%s\\0' \"$@\" > \"$NIX_ARGUMENTS\"\nexit 37\n",
            env("testShell")
        ),
    )?;
    std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755))?;
    let installable = "path:/tmp/space here#billets.x.hello;$(no-shell)";
    let cases: [(&str, &[&str], &str); 6] = [
        ("validate", &["eval", "--json"], "ir"),
        ("manifest", &["eval", "--raw"], "canonicalJSON"),
        (
            "closure",
            &["build", "--no-link", "--print-out-paths"],
            "closureDescriptor",
        ),
        (
            "image",
            &["build", "--no-link", "--print-out-paths"],
            "ociImage",
        ),
        (
            "layout",
            &["build", "--no-link", "--print-out-paths"],
            "ociLayout",
        ),
        (
            "capabilities",
            &["eval", "--json"],
            "dockerCompose.capabilityReport",
        ),
    ];
    for (action, prefix, suffix) in cases {
        let result = Command::new(env("cli"))
            .args([action, installable])
            .env("PATH", &temporary.0)
            .env("NIX_ARGUMENTS", &captured)
            .output()?;
        check(
            result.status.code() == Some(37),
            "CLI did not preserve child exit",
        )?;
        let bytes = std::fs::read(&captured)?;
        let actual: Vec<&[u8]> = bytes
            .strip_suffix(&[0])
            .unwrap()
            .split(|byte| *byte == 0)
            .collect();
        let mut expected: Vec<Vec<u8>> = prefix.iter().map(|s| s.as_bytes().to_vec()).collect();
        expected.push(format!("{installable}.{suffix}").into_bytes());
        check(
            actual == expected.iter().map(Vec::as_slice).collect::<Vec<_>>(),
            "CLI argv changed",
        )?;
    }
    std::fs::remove_file(&captured)?;
    let invalid = Command::new(env("cli"))
        .args(["validate", "--impure"])
        .env("PATH", &temporary.0)
        .output()?;
    check(
        invalid.status.code() == Some(2) && !captured.exists(),
        "invalid CLI request invoked Nix",
    )?;
    std::fs::remove_file(&fake)?;
    let missing = Command::new(env("cli"))
        .args(["validate", installable])
        .env("PATH", &temporary.0)
        .output()?;
    check(missing.status.code() == Some(1), "missing Nix did not fail")?;
    println!("CLI argv, child exits, invalid usage and spawn failure verified");
    Ok(())
}
