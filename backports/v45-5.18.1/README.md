# Forwardport Patches for Kernel 5.18.1

The patches allow applying the LRNG to newer(!) kernels. Perform the following
operations:

1. apply all six-digit patches providing necessary code updates to
   required before applying the LRNG patches.

2. apply all LRNG patches from upstream - note, some hunks are expected
   considering the original code base is written for a different kernel version

3. apply all two-digit patches providing code updates after the LRNG patches
   are applied.
