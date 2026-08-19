///|
extern "C" fn flush_stdout() = "global_mode_flush_stdout"

///|
/// Write a line to stdout, and make sure it actually gets there.
///
/// `println` buffers when stdout is a pipe or a file, and a long-running
/// server never reaches the flush at exit — so without this, `--verbose`
/// output would be invisible for the entire life of the process.
pub fn log(message : String) -> Unit {
  println(message)
  flush_stdout()
}
