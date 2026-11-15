/* Spike #120: an LD_PRELOAD library standing in for an attacker's code injected into the prompt.
   If the process loads it, the constructor leaves a marker. */
#include <stdio.h>
#include <unistd.h>
__attribute__((constructor)) static void evil(void) {
    FILE *f = fopen("/tmp/lh-preload-ran", "w");
    if (f) { fprintf(f, "%d\n", getpid()); fclose(f); }
}
