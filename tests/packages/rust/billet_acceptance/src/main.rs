//! Executable acceptance fixtures and the opt-in image smoke harness.
mod cli;
mod common;
mod contracts;
mod diagnostics;
mod oci;
mod smoke;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        Some("ir") => contracts::ir(),
        Some("diagnose") if (3..=4).contains(&args.len()) => {
            contracts::diagnose(&args[1], &args[2], args.get(3).map(String::as_str))
        }
        Some("closure") => contracts::closure(),
        Some("rejections") => diagnostics::rejections(),
        Some("systems") => diagnostics::systems(),
        Some("cli") => cli::verify(),
        Some("preflight") => contracts::preflight(),
        Some("oci") => oci::verify(),
        Some("smoke") if args.len() == 2 => smoke::run(std::path::Path::new(&args[1])),
        _ => Err("usage: billet-acceptance <ir|diagnose FIXTURE FIELD [REASON]|closure|rejections|systems|cli|preflight|oci|smoke OCI_LAYOUT>".into()),
    };
    if let Err(error) = result {
        eprintln!("billet acceptance: {error}");
        std::process::exit(1);
    }
}
