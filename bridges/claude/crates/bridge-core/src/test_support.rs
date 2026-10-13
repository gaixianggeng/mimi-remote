//! Helpers shared by this crate's unit tests.

use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};

/// Writes an executable script that a test is about to run.
///
/// Tests run on parallel threads and many of them spawn children. If this
/// process held a writable descriptor to the script while another thread
/// forked, the child would keep it until its own `exec`, and Linux would refuse
/// to run the script with ETXTBSY ("Text file busy"). Renaming into place does
/// not help because the inherited descriptor still points at the same inode.
/// Letting `/bin/sh` write the file means this process never opens it for
/// writing, and once `sh` has exited nothing does.
pub(crate) fn write_executable_script(path: &Path, contents: &str) {
    let mut child = Command::new("/bin/sh")
        .arg("-c")
        .arg(r#"cat > "$1" && chmod 755 "$1""#)
        .arg("sh")
        .arg(path)
        .stdin(Stdio::piped())
        .spawn()
        .expect("spawn script writer");
    child
        .stdin
        .take()
        .expect("script writer stdin")
        .write_all(contents.as_bytes())
        .expect("write script");
    let status = child.wait().expect("wait for script writer");
    assert!(status.success(), "script writer failed: {status}");
}
