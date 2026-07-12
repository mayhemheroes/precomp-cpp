// In-process file-input harness for Precomp's recompression (the `precomp -r` code path).
//
// The raw `precomp -r <file>` CLI is unfuzzable as-is: read_header() rejects anything
// without the exact 6-byte "PCF\0\4\8" magic+version (exit(1)) so a byte fuzzer never
// reaches the recompressor, and the CLI both prompts before overwriting an existing
// output and writes its restored file / scratch (~temp*.dat) files into the current
// directory — which fails under Mayhem's read-only image mount. This harness drives the
// SAME reconstruction code (recompress_file -> decompress_file) directly: it fixes the
// PCF header (so the fuzzer's bytes become the recompressible stream body) and runs each
// input once in a private writable /tmp workdir. One process per input => the tool's
// allocate-and-exit memory model needs no leak suppression.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <unistd.h>
#include "precomp_dll.h"

int main(int argc, char** argv) {
  if (argc < 2) return 0;

  FILE* in = fopen(argv[1], "rb");
  if (!in) return 0;

  // Private, writable working directory: Precomp writes its output and ~temp*.dat scratch
  // files relative to CWD, and the Mayhem image is mounted read-only.
  char workdir[] = "/tmp/precomp-harness-XXXXXX";
  if (mkdtemp(workdir) == NULL) { fclose(in); return 0; }
  if (chdir(workdir) != 0) { fclose(in); return 0; }

  // Compose a valid PCF container: "PCF" + version{V_MAJOR,V_MINOR,V_MINOR2} +
  // otf-compression-method(0 = OTF_NONE, so the body is read raw) + empty header filename
  // (NUL). The fuzzer-controlled bytes follow as the recompressible stream body.
  FILE* pcf = fopen("in.pcf", "wb");
  if (!pcf) { fclose(in); return 0; }
  static const unsigned char header[8] = { 'P', 'C', 'F', 0, 4, 8, 0, 0 };
  fwrite(header, 1, sizeof(header), pcf);
  unsigned char buf[65536];
  size_t n;
  while ((n = fread(buf, 1, sizeof(buf), in)) > 0) fwrite(buf, 1, n, pcf);
  fclose(in);
  fclose(pcf);

  char msg[256];
  Switches switches;                 // upstream defaults (all stream types enabled)
  recompress_file((char*)"in.pcf", (char*)"out.bin", msg, switches);
  return 0;
}
