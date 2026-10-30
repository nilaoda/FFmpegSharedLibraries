# AArch64 davs2 primitives

This directory contains the GPL-3.0 AArch64 NEON primitive patch series for davs2.
The numbered filenames preserve the patch application order. The macOS arm64
runtime applies them after the common 10-bit and x86 compatibility patches and
before sequence-display metadata support.

The patches enable AArch64 NEON detection and compiler vectorization, then add
10-bit pixel copy/add/average, motion-compensation interpolation, luma/chroma
deblocking and intra-prediction primitives. Architecture and bit-depth guards
keep these implementations out of other targets. Linux and Windows builds do
not apply this patch directory.

The scalar implementation remains the reference for decoded pixel comparisons.
Keep the full primitive patch set in order when updating it; several patches
extend code introduced by an earlier patch.
