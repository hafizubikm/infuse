// Tiny RPU generator for Reel's synthetic Dolby Vision test clips.
// Usage: dvgen <config.json> <out.bin>; writes each RPU NAL (0x7C01 header) as 4-byte BE length + bytes.
use dolby_vision::rpu::generate::GenerateConfig;
use std::io::Write;
fn main() {
    let args: Vec<String> = std::env::args().collect();
    let cfg: GenerateConfig = serde_json::from_str(&std::fs::read_to_string(&args[1]).unwrap()).unwrap();
    let rpus = cfg.generate_rpu_list().unwrap();
    let mut out = std::fs::File::create(&args[2]).unwrap();
    for rpu in &rpus {
        let nal = rpu.write_hevc_unspec62_nalu().unwrap();
        out.write_all(&(nal.len() as u32).to_be_bytes()).unwrap();
        out.write_all(&nal).unwrap();
    }
    eprintln!("wrote {} RPUs", rpus.len());
}
