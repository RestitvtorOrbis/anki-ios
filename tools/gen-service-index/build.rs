use std::env;
use std::path::PathBuf;

fn main() {
    // anki_proto's build script has already written the descriptor pool to
    // this shared path (OUT_DIR/../../anki_descriptors.bin); copy it into our
    // own OUT_DIR so main.rs can include_bytes! it.
    let src = anki_proto_gen::descriptors_path();
    println!("cargo:rerun-if-changed={}", src.display());
    let dst = PathBuf::from(env::var("OUT_DIR").unwrap()).join("descriptors.bin");
    std::fs::copy(&src, &dst).expect("descriptor pool not found; build anki_proto first");
}
