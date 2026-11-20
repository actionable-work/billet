//! Runs a scenario script in its own process group.
//!
//! The script's standard output is forwarded. With `--until`, the session
//! succeeds once that text appears and the runner stops the process group.
//! The runner always stops the group when it finishes, so commands that a
//! documented block starts in the background do not outlive the scenario.
use std::io::{Read, Write};
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

#[derive(Debug, PartialEq)]
struct Options {
    timeout: Duration,
    until: Option<String>,
    script: String,
}

#[derive(Default)]
struct Output {
    text: Mutex<String>,
    closed: AtomicBool,
}

pub fn run(args: &[String]) -> Result<i32, String> {
    let options = parse(args)
        .ok_or("usage: billet-doctest session --timeout SECONDS [--until TEXT] SCRIPT")?;
    let mut child = Command::new("bash")
        .arg(&options.script)
        .process_group(0)
        .stdout(Stdio::piped())
        .spawn()
        .map_err(|error| format!("cannot start bash: {error}"))?;
    let output = Arc::new(Output::default());
    forward(&mut child, Arc::clone(&output))?;
    let result = supervise(&mut child, &options, &output);
    stop_group(child.id());
    result
}

fn parse(args: &[String]) -> Option<Options> {
    let mut timeout = None;
    let mut until = None;
    let mut script = None;
    let mut args = args.iter();
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--timeout" => timeout = Some(Duration::from_secs(args.next()?.parse().ok()?)),
            "--until" => until = Some(args.next()?.clone()),
            flag if flag.starts_with('-') => return None,
            path if script.is_none() => script = Some(path.to_owned()),
            _ => return None,
        }
    }
    Some(Options {
        timeout: timeout?,
        until,
        script: script?,
    })
}

fn forward(child: &mut Child, output: Arc<Output>) -> Result<(), String> {
    let mut stdout = child.stdout.take().ok_or("session has no output pipe")?;
    thread::spawn(move || {
        let mut buffer = [0_u8; 8192];
        while let Ok(count @ 1..) = stdout.read(&mut buffer) {
            let chunk = &buffer[..count];
            let mut console = std::io::stdout().lock();
            let _ = console.write_all(chunk).and_then(|()| console.flush());
            let text = String::from_utf8_lossy(chunk).replace('\r', "");
            if let Ok(mut all) = output.text.lock() {
                all.push_str(&text);
            }
        }
        output.closed.store(true, Ordering::SeqCst);
    });
    Ok(())
}

fn matched(output: &Output, until: Option<&str>) -> bool {
    match (until, output.text.lock()) {
        (Some(until), Ok(text)) => text.contains(until),
        _ => false,
    }
}

fn supervise(child: &mut Child, options: &Options, output: &Output) -> Result<i32, String> {
    let until = options.until.as_deref();
    let deadline = Instant::now() + options.timeout;
    loop {
        if matched(output, until) {
            return Ok(0);
        }
        let status = child
            .try_wait()
            .map_err(|error| format!("session: {error}"))?;
        if let Some(status) = status {
            return finished(status.code().unwrap_or(1), output, until);
        }
        if Instant::now() >= deadline {
            return Err(format!(
                "session timed out after {}s",
                options.timeout.as_secs()
            ));
        }
        thread::sleep(Duration::from_millis(200));
    }
}

fn finished(code: i32, output: &Output, until: Option<&str>) -> Result<i32, String> {
    // Background commands can keep the pipe open, so wait briefly for output.
    let drain = Instant::now() + Duration::from_secs(2);
    while !output.closed.load(Ordering::SeqCst) && Instant::now() < drain {
        thread::sleep(Duration::from_millis(50));
    }
    match until {
        Some(_) if matched(output, until) => Ok(0),
        Some(until) => Err(format!(
            "session exited with {code} before printing {until:?}"
        )),
        None => Ok(code),
    }
}

fn signal(group: u32, name: &str) -> bool {
    Command::new("kill")
        .args([name, "--", &format!("-{group}")])
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|status| status.success())
}

fn stop_group(group: u32) {
    if !signal(group, "-TERM") {
        return;
    }
    let deadline = Instant::now() + Duration::from_secs(15);
    while Instant::now() < deadline {
        if !signal(group, "-0") {
            return;
        }
        thread::sleep(Duration::from_millis(200));
    }
    signal(group, "-KILL");
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(text: &str) -> Vec<String> {
        text.split_whitespace().map(str::to_owned).collect()
    }

    #[test]
    fn parses_timeout_until_and_script() {
        let options = Options {
            timeout: Duration::from_secs(30),
            until: Some("ready".into()),
            script: "s.sh".into(),
        };
        assert_eq!(
            parse(&args("--timeout 30 --until ready s.sh")),
            Some(options)
        );
        let plain = Options {
            timeout: Duration::from_secs(5),
            until: None,
            script: "s.sh".into(),
        };
        assert_eq!(parse(&args("s.sh --timeout 5")), Some(plain));
    }

    #[test]
    fn rejects_incomplete_options() {
        for text in [
            "s.sh",
            "--timeout 5",
            "--timeout x s.sh",
            "--timeout 5 a.sh b.sh",
            "--x 5 s.sh",
        ] {
            assert_eq!(parse(&args(text)), None, "{text}");
        }
    }

    #[test]
    fn until_matches_accumulated_output() {
        let output = Output::default();
        output.text.lock().unwrap().push_str("first\nready now\n");
        assert!(matched(&output, Some("ready")));
        assert!(!matched(&output, Some("absent")));
        assert!(!matched(&output, None));
    }
}
