// Test fixture for scripts/vm-test-uhid.sh (linux-hello#121): a minimal stand-in for the uhid helper,
// and for a compromised one. Not product code. Standard library only; build static with
//   rustc --edition 2021 -O --target x86_64-unknown-linux-musl -o uhid-probe uhid-probe.rs
//
//   uhid-probe fido <seconds>       create a FIDO security-key HID device, keep it that long
//   uhid-probe keyboard <seconds>   create a keyboard HID device (what a compromised helper could do)
//   uhid-probe swap <seconds>       create the FIDO device, destroy it, create a keyboard on the same fd
//   uhid-probe open <path>          try to open a file for reading and say whether it worked
//   uhid-probe net                  try to bind a UDP socket on loopback and say whether it worked
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::net::UdpSocket;
use std::time::Duration;

const UHID_DESTROY: u32 = 1;
const UHID_CREATE2: u32 = 11;

/// FIDO HID report descriptor: usage page 0xF1D0, one 64-byte input and one 64-byte output report.
const FIDO: &[u8] = &[
    0x06, 0xD0, 0xF1, 0x09, 0x01, 0xA1, 0x01, 0x09, 0x20, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08,
    0x95, 0x40, 0x81, 0x02, 0x09, 0x21, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x40, 0x91,
    0x02, 0xC0,
];

/// A boot-protocol keyboard report descriptor.
const KEYBOARD: &[u8] = &[
    0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01,
    0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0x95, 0x01, 0x75, 0x08, 0x81, 0x01, 0x95, 0x06, 0x75, 0x08,
    0x15, 0x00, 0x25, 0x65, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00, 0xC0,
];

/// A UHID_CREATE2 event (struct uhid_event, 4380 bytes) for the given name, descriptor and ids.
fn create2(name: &str, desc: &[u8], vendor: u32, product: u32) -> Vec<u8> {
    let mut e = vec![0u8; 4380];
    e[0..4].copy_from_slice(&UHID_CREATE2.to_le_bytes());
    e[4..4 + name.len()].copy_from_slice(name.as_bytes());
    // name[128], phys[64], uniq[64] end at 4+256; then rd_size u16, bus u16, vendor, product, version, country
    let o = 4 + 128 + 64 + 64;
    e[o..o + 2].copy_from_slice(&(desc.len() as u16).to_le_bytes());
    e[o + 2..o + 4].copy_from_slice(&3u16.to_le_bytes()); // BUS_USB
    e[o + 4..o + 8].copy_from_slice(&vendor.to_le_bytes());
    e[o + 8..o + 12].copy_from_slice(&product.to_le_bytes());
    e[o + 12..o + 16].copy_from_slice(&1u32.to_le_bytes());
    e[o + 20..o + 20 + desc.len()].copy_from_slice(desc);
    e
}

fn uhid() -> File {
    OpenOptions::new().read(true).write(true).open("/dev/uhid").unwrap_or_else(|e| {
        println!("uhid: cannot open /dev/uhid: {e}");
        std::process::exit(2);
    })
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let secs = |i: usize| args.get(i).and_then(|s| s.parse().ok()).unwrap_or(5u64);
    match args.get(1).map(String::as_str) {
        Some("fido") => {
            let mut f = uhid();
            f.write_all(&create2("Linux Hello probe key", FIDO, 0x1209, 0xF1D0)).expect("create");
            println!("created fido");
            std::thread::sleep(Duration::from_secs(secs(2)));
        }
        Some("keyboard") => {
            let mut f = uhid();
            f.write_all(&create2("Probe keyboard", KEYBOARD, 0x1234, 0x5678)).expect("create");
            println!("created keyboard");
            std::thread::sleep(Duration::from_secs(secs(2)));
        }
        Some("swap") => {
            let mut f = uhid();
            f.write_all(&create2("Linux Hello probe key", FIDO, 0x1209, 0xF1D0)).expect("create");
            let second = f.write_all(&create2("Probe keyboard", KEYBOARD, 0x1234, 0x5678));
            println!("second create while the first is alive: {}", if second.is_err() { "refused" } else { "allowed" });
            f.write_all(&UHID_DESTROY.to_le_bytes()).expect("destroy");
            let third = f.write_all(&create2("Probe keyboard", KEYBOARD, 0x1234, 0x5678));
            println!("create after destroy on the same fd: {}", if third.is_err() { "refused" } else { "allowed" });
            std::thread::sleep(Duration::from_secs(secs(2)));
        }
        Some("open") => match File::open(args.get(2).map(String::as_str).unwrap_or("/")) {
            Ok(_) => println!("opened"),
            Err(e) => println!("denied: {e}"),
        },
        Some("net") => match UdpSocket::bind("127.0.0.1:0") {
            Ok(_) => println!("bound"),
            Err(e) => println!("denied: {e}"),
        },
        _ => {
            eprintln!("usage: uhid-probe fido|keyboard|swap <seconds> | open <path> | net");
            std::process::exit(64);
        }
    }
}
