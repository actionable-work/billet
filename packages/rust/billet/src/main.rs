fn main() {
    std::process::exit(billet_core::run(
        &std::env::args().skip(1).collect::<Vec<_>>(),
    ));
}
