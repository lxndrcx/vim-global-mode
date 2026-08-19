#include <stdio.h>

/* MoonBit's `println` buffers, and a server that never exits never flushes,
   so `--verbose` output would sit invisible in a pipe or log file forever. */
void global_mode_flush_stdout(void) { fflush(stdout); }
