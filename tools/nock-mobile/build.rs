// Generates the explorer messages (NockchainBlockService: tx details, block details) from the
// official protos in proto/ (copied from zorp-corp/nockchain, MIT). The wallet messages
// (balance, send, accepted) come from iris-grpc-proto, whose conversions we reuse.
fn main() {
    println!("cargo:rerun-if-changed=proto");
    prost_build::Config::new()
        .compile_protos(&["proto/nockchain/public/v2/nockchain.proto"], &["proto"])
        .expect("compile nockchain protos (needs protoc on PATH or PROTOC set)");
}
