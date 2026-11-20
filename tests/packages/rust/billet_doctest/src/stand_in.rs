//! A `nix` stand-in for documented commands inside sandboxes and test VMs.
//!
//! `BILLET_DOCTEST_ROOT` names the scenario root directory and
//! `BILLET_DOCTEST_TABLE` a JSON file with resolved `refs` and `checks`. A
//! reference key is the flake directory relative to the root, `#`, and the
//! attribute path. Unsupported forms fail instead of guessing.
use serde_json::{Map, Value};
use std::fs;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Debug, PartialEq)]
enum Invocation {
    Build {
        reference: String,
        link: Option<String>,
    },
    Eval {
        reference: String,
        raw: bool,
    },
    Run {
        reference: String,
        args: Vec<String>,
    },
    FlakeCheck {
        flake: String,
    },
}

pub fn run(args: &[String]) -> Result<i32, String> {
    let invocation =
        parse(args).ok_or_else(|| format!("unsupported nix invocation: nix {}", args.join(" ")))?;
    let table = Table::load()?;
    match invocation {
        Invocation::Build { reference, link } => build(&table, &reference, link.as_deref()),
        Invocation::Eval { reference, raw } => eval(&table, &reference, raw),
        Invocation::Run { reference, args } => {
            let program = table.field(&reference, "program")?;
            Err(format!(
                "cannot run {program}: {}",
                Command::new(&program).args(args).exec()
            ))
        }
        Invocation::FlakeCheck { flake } => flake_check(&table, &flake),
    }
}

fn parse(args: &[String]) -> Option<Invocation> {
    let (command, rest) = args.split_first()?;
    match command.as_str() {
        "build" => parse_build(rest),
        "eval" => parse_eval(rest),
        "run" => parse_run(rest),
        "flake" => parse_flake_check(rest),
        _ => None,
    }
}

fn parse_build(args: &[String]) -> Option<Invocation> {
    let mut link = Some("result".to_owned());
    let mut references = Vec::new();
    let mut args = args.iter();
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "-o" | "--out-link" => link = Some(args.next()?.clone()),
            "--no-link" => link = None,
            "-L" | "--print-build-logs" => {}
            flag if flag.starts_with('-') => return None,
            reference => references.push(reference.to_owned()),
        }
    }
    let [reference] = <[String; 1]>::try_from(references).ok()?;
    Some(Invocation::Build { reference, link })
}

fn parse_eval(args: &[String]) -> Option<Invocation> {
    match args {
        [format, reference] if !reference.starts_with('-') => {
            let raw = match format.as_str() {
                "--raw" => true,
                "--json" => false,
                _ => return None,
            };
            Some(Invocation::Eval {
                reference: reference.clone(),
                raw,
            })
        }
        _ => None,
    }
}

fn parse_run(args: &[String]) -> Option<Invocation> {
    let (reference, rest) = args.split_first()?;
    if reference.starts_with('-') {
        return None;
    }
    let args = match rest.split_first() {
        None => Vec::new(),
        Some((separator, args)) if separator == "--" => args.to_vec(),
        Some(_) => return None,
    };
    Some(Invocation::Run {
        reference: reference.clone(),
        args,
    })
}

fn parse_flake_check(args: &[String]) -> Option<Invocation> {
    match args {
        [check] if check == "check" => Some(Invocation::FlakeCheck {
            flake: ".".to_owned(),
        }),
        [check, flake] if check == "check" && !flake.starts_with('-') => {
            Some(Invocation::FlakeCheck {
                flake: flake.clone(),
            })
        }
        _ => None,
    }
}

struct Table {
    root: PathBuf,
    refs: Map<String, Value>,
    checks: Map<String, Value>,
}

impl Table {
    fn load() -> Result<Self, String> {
        let variable = |name: &str| std::env::var(name).map_err(|_| format!("{name} is not set"));
        let root = fs::canonicalize(variable("BILLET_DOCTEST_ROOT")?)
            .map_err(|error| format!("scenario root: {error}"))?;
        let text = fs::read_to_string(variable("BILLET_DOCTEST_TABLE")?)
            .map_err(|error| format!("reference table: {error}"))?;
        let mut table: Map<String, Value> =
            serde_json::from_str(&text).map_err(|error| format!("reference table: {error}"))?;
        let mut section = |name: &str| match table.remove(name) {
            Some(Value::Object(entries)) => Ok(entries),
            _ => Err(format!("reference table has no {name} object")),
        };
        Ok(Self {
            root,
            refs: section("refs")?,
            checks: section("checks")?,
        })
    }

    fn flake(&self, flake: &str) -> Result<String, String> {
        if flake.contains(':') {
            return Err(format!("unsupported flake reference {flake}"));
        }
        let cwd = std::env::current_dir().map_err(|error| format!("working directory: {error}"))?;
        let directory = fs::canonicalize(cwd.join(flake))
            .map_err(|error| format!("flake directory {flake}: {error}"))?;
        relative_key(&self.root, &directory)
    }

    fn entry(&self, reference: &str) -> Result<&Map<String, Value>, String> {
        let (flake, attribute) = split_reference(reference)?;
        let key = format!("{}#{attribute}", self.flake(flake)?);
        match self.refs.get(&key) {
            Some(Value::Object(entry)) => Ok(entry),
            _ => Err(format!("unresolved reference {key}")),
        }
    }

    fn field(&self, reference: &str, name: &str) -> Result<String, String> {
        match self.entry(reference)?.get(name) {
            Some(Value::String(value)) => Ok(value.clone()),
            _ => Err(format!("{reference} has no {name}")),
        }
    }
}

fn split_reference(reference: &str) -> Result<(&str, &str), String> {
    match reference.split_once('#') {
        Some((flake, attribute)) if !flake.is_empty() && !attribute.is_empty() => {
            Ok((flake, attribute))
        }
        _ => Err(format!("unsupported reference {reference}")),
    }
}

fn relative_key(root: &Path, directory: &Path) -> Result<String, String> {
    let relative = directory
        .strip_prefix(root)
        .map_err(|_| format!("{} is outside the scenario root", directory.display()))?;
    match relative.to_str() {
        Some("") => Ok(".".to_owned()),
        Some(relative) => Ok(relative.to_owned()),
        None => Err(format!("{} is not UTF-8", relative.display())),
    }
}

fn build(table: &Table, reference: &str, link: Option<&str>) -> Result<i32, String> {
    let path = table.field(reference, "path")?;
    if let Some(link) = link {
        match fs::symlink_metadata(link) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                fs::remove_file(link).map_err(|error| format!("{link}: {error}"))?;
            }
            Ok(_) => return Err(format!("{link} exists and is not a symbolic link")),
            Err(_) => {}
        }
        std::os::unix::fs::symlink(&path, link).map_err(|error| format!("{link}: {error}"))?;
    }
    Ok(0)
}

fn eval(table: &Table, reference: &str, raw: bool) -> Result<i32, String> {
    let entry = table.entry(reference)?;
    let value = entry.get("path").or_else(|| entry.get("value"));
    match (value, raw) {
        (Some(Value::String(text)), true) => print!("{text}"),
        (Some(value), false) => println!("{value}"),
        (Some(_), true) => return Err(format!("{reference} is not a string")),
        (None, _) => return Err(format!("{reference} has no value")),
    }
    Ok(0)
}

fn flake_check(table: &Table, flake: &str) -> Result<i32, String> {
    let key = table.flake(flake)?;
    let Some(Value::Array(paths)) = table.checks.get(&key) else {
        return Err(format!("no checks resolved for {key}"));
    };
    for path in paths {
        let path = path.as_str().ok_or("check paths must be strings")?;
        fs::metadata(path).map_err(|error| format!("check {path}: {error}"))?;
    }
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(text: &str) -> Vec<String> {
        text.split_whitespace().map(str::to_owned).collect()
    }

    #[test]
    fn build_links_result_by_default() {
        assert_eq!(
            parse(&args("build .#a.b")),
            Some(Invocation::Build {
                reference: ".#a.b".into(),
                link: Some("result".into())
            })
        );
    }

    #[test]
    fn build_accepts_documented_link_options() {
        let named = Invocation::Build {
            reference: ".#a".into(),
            link: Some("out".into()),
        };
        assert_eq!(parse(&args("build .#a -o out")), Some(named));
        let none = Invocation::Build {
            reference: ".#a".into(),
            link: None,
        };
        assert_eq!(parse(&args("build --no-link -L .#a")), Some(none));
    }

    #[test]
    fn build_rejects_other_forms() {
        for text in [
            "build",
            "build .#a .#b",
            "build --impure .#a",
            "build .#a -o",
        ] {
            assert_eq!(parse(&args(text)), None, "{text}");
        }
    }

    #[test]
    fn eval_requires_one_output_format() {
        let raw = Invocation::Eval {
            reference: ".#a".into(),
            raw: true,
        };
        assert_eq!(parse(&args("eval --raw .#a")), Some(raw));
        let json = Invocation::Eval {
            reference: ".#a".into(),
            raw: false,
        };
        assert_eq!(parse(&args("eval --json .#a")), Some(json));
        for text in ["eval .#a", "eval --json", "eval --apply f .#a"] {
            assert_eq!(parse(&args(text)), None, "{text}");
        }
    }

    #[test]
    fn run_passes_arguments_after_separator() {
        let run = Invocation::Run {
            reference: ".#a".into(),
            args: vec!["x".into(), "-y".into()],
        };
        assert_eq!(parse(&args("run .#a -- x -y")), Some(run));
        assert_eq!(parse(&args("run .#a x")), None);
    }

    #[test]
    fn flake_check_defaults_to_working_directory() {
        let check = Invocation::FlakeCheck { flake: ".".into() };
        assert_eq!(parse(&args("flake check")), Some(check));
        assert_eq!(parse(&args("flake show")), None);
        assert_eq!(parse(&args("develop --command true")), None);
    }

    #[test]
    fn references_need_a_flake_and_attribute() {
        assert_eq!(
            split_reference("./examples/hello#billets"),
            Ok(("./examples/hello", "billets"))
        );
        for reference in ["#billets", ".#", "billets"] {
            assert!(split_reference(reference).is_err(), "{reference}");
        }
    }

    #[test]
    fn keys_are_relative_to_the_scenario_root() {
        let root = Path::new("/scenario");
        assert_eq!(relative_key(root, root), Ok(".".into()));
        assert_eq!(
            relative_key(root, Path::new("/scenario/examples/hello")),
            Ok("examples/hello".into())
        );
        assert!(relative_key(root, Path::new("/elsewhere")).is_err());
    }
}
