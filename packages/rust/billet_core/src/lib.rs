//! Thin, shell-free tooling for the Nix-owned Billet contract.

use std::process::Command;

/// A validated Nix command. Arguments are never interpreted by a shell.
#[derive(Debug, PartialEq, Eq)]
pub struct Invocation {
    /// Arguments to the `nix` executable.
    pub args: Vec<String>,
}

/// Build a Nix invocation from exactly one action and one installable.
pub fn invocation(args: &[String]) -> Result<Invocation, &'static str> {
    if args.len() != 2 || args[1].is_empty() || args[1].starts_with('-') {
        return Err(
            "usage: billet <validate|manifest|closure|image|layout|capabilities> INSTALLABLE",
        );
    }
    let (prefix, attribute): (&[&str], &str) = match args[0].as_str() {
        "validate" => (&["eval", "--json"], "ir"),
        "manifest" => (&["eval", "--raw"], "canonicalJSON"),
        "capabilities" => (&["eval", "--json"], "dockerCompose.capabilityReport"),
        "layout" => (&["build", "--no-link", "--print-out-paths"], "ociLayout"),
        "image" => (&["build", "--no-link", "--print-out-paths"], "ociImage"),
        "closure" => (
            &["build", "--no-link", "--print-out-paths"],
            "closureDescriptor",
        ),
        _ => {
            return Err(
                "usage: billet <validate|manifest|closure|image|layout|capabilities> INSTALLABLE",
            );
        }
    };
    let mut result: Vec<String> = prefix.iter().map(|arg| (*arg).to_owned()).collect();
    result.push(format!("{}.{attribute}", args[1]));
    Ok(Invocation { args: result })
}

/// Execute Nix, inheriting its diagnostics and output, and preserve its exit code.
pub fn run(args: &[String]) -> i32 {
    let invocation = match invocation(args) {
        Ok(invocation) => invocation,
        Err(message) => {
            eprintln!("{message}");
            return 2;
        }
    };
    match Command::new("nix").args(invocation.args).status() {
        Ok(status) => status.code().unwrap_or(1),
        Err(_) => {
            eprintln!("billet: could not execute nix");
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::invocation;

    #[test]
    #[cfg_attr(any(), bloomery("BILLET-CLI-INVOCATION-001"))]
    fn preserves_an_installable_as_one_argument() {
        let request = vec![
            "manifest".to_owned(),
            "path:/tmp/a b#billets.x.hello;echo nope".to_owned(),
        ];
        assert_eq!(
            invocation(&request).unwrap().args,
            vec![
                "eval",
                "--raw",
                "path:/tmp/a b#billets.x.hello;echo nope.canonicalJSON"
            ]
        );
    }

    #[test]
    #[cfg_attr(any(), bloomery("BILLET-CLI-INVOCATION-001"))]
    fn selects_outputs_and_rejects_ambiguous_requests() {
        for (action, expected) in [("validate", "ir"), ("closure", "closureDescriptor")] {
            let request = vec![action.to_owned(), ".#billets.x.hello".to_owned()];
            let args = invocation(&request).unwrap().args;
            assert!(args.last().unwrap().ends_with(expected));
        }
        for args in [
            vec![],
            vec!["unknown", ".#x"],
            vec!["validate", "--impure"],
            vec!["validate", ".#x", "extra"],
        ] {
            assert!(invocation(&args.into_iter().map(str::to_owned).collect::<Vec<_>>()).is_err());
        }
    }
}
