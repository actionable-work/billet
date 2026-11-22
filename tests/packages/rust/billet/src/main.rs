fn main() {
    std::process::exit(billet_core::run(
        &std::env::args_os().skip(1).collect::<Vec<_>>(),
    ));
}
