use std::{
    env,
    fs::File,
    io::BufReader,
    path::Path,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::Instant,
};

use git_internal::{
    hash::{HashKind, ObjectHash, set_hash_kind},
    internal::pack::Pack,
};

struct Config {
    pack: String,
    threads: Option<usize>,
    mem_limit_mb: Option<usize>,
    hash_kind: HashKind,
}

fn parse_args() -> Result<Config, String> {
    let mut pack = None;
    let mut threads = None;
    let mut mem_limit_mb = None;
    let mut hash_kind = HashKind::Sha1;

    let mut args = env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--pack" => {
                pack = args.next();
            }
            "--threads" => {
                let value = args
                    .next()
                    .ok_or_else(|| "missing value for --threads".to_string())?;
                let parsed = value
                    .parse::<usize>()
                    .map_err(|e| format!("invalid --threads value: {e}"))?;
                if parsed == 0 {
                    return Err("--threads must be >= 1".to_string());
                }
                threads = Some(parsed);
            }
            "--mem-limit-mb" => {
                let value = args
                    .next()
                    .ok_or_else(|| "missing value for --mem-limit-mb".to_string())?;
                let parsed = value
                    .parse::<usize>()
                    .map_err(|e| format!("invalid --mem-limit-mb value: {e}"))?;
                mem_limit_mb = Some(parsed);
            }
            "--hash" => {
                let value = args
                    .next()
                    .ok_or_else(|| "missing value for --hash".to_string())?;
                hash_kind = match value.to_ascii_lowercase().as_str() {
                    "sha1" => HashKind::Sha1,
                    "sha256" => HashKind::Sha256,
                    _ => return Err("--hash must be one of: sha1, sha256".to_string()),
                };
            }
            "--help" | "-h" => {
                return Err(
                    "usage: cargo run --release --example decode_pack_bench -- --pack <path> [--threads <n>] [--mem-limit-mb <n>] [--hash sha1|sha256]"
                        .to_string(),
                );
            }
            _ => return Err(format!("unknown argument: {arg}")),
        }
    }

    let pack = pack.ok_or_else(|| "--pack is required".to_string())?;
    Ok(Config {
        pack,
        threads,
        mem_limit_mb,
        hash_kind,
    })
}

fn main() {
    let config = match parse_args() {
        Ok(c) => c,
        Err(msg) => {
            eprintln!("{msg}");
            std::process::exit(2);
        }
    };

    if !Path::new(&config.pack).exists() {
        eprintln!("pack file not found: {}", config.pack);
        std::process::exit(2);
    }

    set_hash_kind(config.hash_kind);

    let file = File::open(&config.pack).expect("failed to open pack file");
    let mut reader = BufReader::new(file);
    let mem_limit = config.mem_limit_mb.map(|mb| mb * 1024 * 1024);
    let mut pack = Pack::new(config.threads, mem_limit, None, true);

    let callback_count = Arc::new(AtomicUsize::new(0));
    let callback_count_clone = callback_count.clone();

    let start = Instant::now();
    pack.decode(
        &mut reader,
        move |_| {
            callback_count_clone.fetch_add(1, Ordering::Relaxed);
        },
        None::<fn(ObjectHash)>,
    )
    .expect("decode failed");
    let elapsed_ms = start.elapsed().as_millis();

    let callback_seen = callback_count.load(Ordering::Relaxed);

    println!("RESULT elapsed_ms={elapsed_ms}");
    println!("RESULT objects_by_pack={}", pack.number);
    println!("RESULT objects_by_callback={callback_seen}");
    println!("RESULT signature={}", pack.signature);

    #[cfg(feature = "bench_cache_stats")]
    {
        let cache_stats = pack.caches.stats();
        let cache_hit_rate = if cache_stats.try_get_calls == 0 {
            0.0
        } else {
            cache_stats.try_get_hits as f64 / cache_stats.try_get_calls as f64
        };

        println!("RESULT cache_try_get_calls={}", cache_stats.try_get_calls);
        println!("RESULT cache_try_get_hits={}", cache_stats.try_get_hits);
        println!("RESULT cache_lookup_misses={}", cache_stats.lookup_misses);
        println!("RESULT cache_disk_fallbacks={}", cache_stats.disk_fallbacks);
        println!("RESULT cache_hit_rate={cache_hit_rate:.6}");
    }
}
