//! Documentation command qualification: a Nix stand-in and a session runner.
//!
//! Invoked as `nix`, the binary answers documented Nix commands from a table of
//! artifacts that evaluation resolved ahead of time. Invoked as
//! `billet-doctest session`, it runs a scenario script in its own process
//! group.
mod session;
mod stand_in;

use std::path::Path;

fn main() {
    let mut args = std::env::args();
    let program = args.next().unwrap_or_default();
    let args: Vec<String> = args.collect();
    let invoked_as = Path::new(&program)
        .file_name()
        .and_then(|name| name.to_str());
    let result = if invoked_as == Some("nix") {
        stand_in::run(&args)
    } else {
        match args.split_first() {
            Some((command, rest)) if command == "session" => session::run(rest),
            _ => {
                Err("usage: billet-doctest session --timeout SECONDS [--until TEXT] SCRIPT".into())
            }
        }
    };
    match result {
        Ok(code) => std::process::exit(code),
        Err(error) => {
            eprintln!("billet-doctest: {error}");
            std::process::exit(2);
        }
    }
}
