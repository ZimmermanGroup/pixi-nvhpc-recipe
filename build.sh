#!/usr/bin/env bash
set -euo pipefail

# ===========================================================================
# Fetch, extract and install the NVIDIA HPC SDK into $PREFIX.
#
# Ported from joshkamm/claude-code-config's setup-nvhpc.sh (lines 48-97), which
# solves the same problem for the Claude Code cloud environment and is the
# origin of the streaming download, the igzip pipeline and the installer patch
# below.
#
# WHY THERE IS NO `source:` SECTION IN recipe.yaml
# ------------------------------------------------
# rattler-build downloads sources with a single unsegmented GET. Measured
# against developer.download.nvidia.com that is 24-54 MB/s, i.e. 3-6 minutes for
# this 8.3 GiB archive, and there is no knob to improve it: verified at tag
# v0.72.2 that no RANGE header exists anywhere in rattler_build_source_cache,
# that `max_concurrent_downloads` is a dead field never passed to
# `SourceCache::new`, and that the list form of `url:` is strict first-success
# failover rather than parallelism. A ranged, parallel download measures
# 108 MB/s. So we do it ourselves.
#
# The archive is also never written to disk: chunks stream straight into
# `igzip | tar` and are deleted as they are consumed. That matters -- the
# extracted tree is already ~19 GB and a session disk is 30 GB.
#
# What omitting `source:` costs, and how each loss is covered here:
#   checksum verification   -> the stream is tee'd through md5sum (below)
#   single-root-dir strip   -> tar --strip-components=1 (below)
#   .source_info.json       -> url + md5 recorded in recipe.yaml's `extra:`
#   src_cache reuse         -> pixi's artifact cache keys on the pinned git rev
#                              and treats git commits as immutable, so a
#                              consumer never rebuilds this for a cache miss
# Do NOT "fix" this by adding `source:` with `file_name:` set -- with that field
# rattler-build's cache-to-workdir step falls back to plain fs::copy instead of
# reflink_or_copy, forcing a hard 8.3 GiB byte copy on every filesystem.
# ===========================================================================

NVHPC_URL="${NVHPC_URL:?recipe.yaml must pass NVHPC_URL via build.script.env}"
NVHPC_MD5="${NVHPC_MD5:?recipe.yaml must pass NVHPC_MD5 via build.script.env}"
NVHPC_RELEASE="${NVHPC_RELEASE:?recipe.yaml must pass NVHPC_RELEASE via build.script.env}"

# 32-way was the fastest of the modes measured (108 MB/s, vs 78 at 16-way).
JOBS="${NVHPC_DOWNLOAD_JOBS:-32}"
CHUNK=$((64 * 1024 * 1024))
# Ceiling on finished-but-not-yet-extracted chunks. See the producer below.
WINDOW=32

WORK="${SRC_DIR:-$PWD}"
DL="$WORK/dl"
EXTRACT="$WORK/nvhpc"

T0=$(date +%s)
stage() {
  printf '[nvhpc] %-28s t=+%-5ss  disk_avail=%s\n' \
    "$1" "$(( $(date +%s) - T0 ))" "$(df -BM --output=avail "$WORK" | tail -1 | tr -d ' ')"
}

stage "start"
echo "[nvhpc] url=$NVHPC_URL"
echo "[nvhpc] PREFIX=$PREFIX"
echo "[nvhpc] WORK=$WORK"

# The mv-based install below is only instant if the work directory and $PREFIX
# are on one filesystem; if they are not, mv degrades to a copy and the disk
# budget this whole design exists to fit no longer holds. Report it rather than
# discovering it as a mystery slowdown.
if [ "$(stat -c %d "$WORK")" != "$(stat -c %d "$(dirname "$PREFIX")")" ]; then
  echo "[nvhpc] WARNING: work dir and \$PREFIX are on different filesystems;" >&2
  echo "[nvhpc]          the install step will copy ~19 GB instead of renaming." >&2
fi

# ---------------------------------------------------------------------------
# Download and extract, in one streaming pass
# ---------------------------------------------------------------------------
SIZE=$(curl -sfI "$NVHPC_URL" | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}' | tail -1)
[ -n "${SIZE:-}" ] || { echo "[nvhpc] could not determine archive size from HEAD $NVHPC_URL" >&2; exit 1; }
N=$(( (SIZE + CHUNK - 1) / CHUNK ))
echo "[nvhpc] size=$SIZE bytes, $N chunks of $CHUNK, $JOBS-way"

mkdir -p "$DL" "$EXTRACT"

# Producer: chunks are fetched $JOBS at a time; each lands under a dotted
# temporary name and is renamed into place, so the rename is atomic and the
# consumer only ever sees whole chunks.
PRODUCER_STATUS="$WORK/producer.status"
rm -f "$PRODUCER_STATUS"
export DL CHUNK NVHPC_URL WINDOW
{
  if seq 0 $((N - 1)) | xargs -P "$JOBS" -I IDX bash -c '
    set -euo pipefail
    i=IDX
    # Backpressure. Without it the producer runs the entire archive ahead of the
    # extractor and ~8 GiB of chunks pile up on a disk that has no room for them.
    # Dotted in-progress files are invisible to this ls, so it counts only
    # finished chunks; the true ceiling is (WINDOW + JOBS) * CHUNK, ~4 GiB.
    while [ "$(ls "$DL" | wc -l)" -ge "$WINDOW" ]; do sleep 0.5; done
    start=$((i * CHUNK)); end=$((start + CHUNK - 1))
    curl -sf --retry 3 --retry-delay 2 -o "$DL/.p$i" -r "${start}-${end}" "$NVHPC_URL"
    mv "$DL/.p$i" "$DL/$(printf "c%05d" "$i")"
  '; then echo ok > "$PRODUCER_STATUS"; else echo failed > "$PRODUCER_STATUS"; fi
  # The sentinel file, not the pid, is what the consumer watches. Once the
  # producer exits it stays a zombie until this shell reaps it, and `kill -0` on
  # a zombie succeeds -- so a liveness check would spin forever on a failed
  # download instead of reporting it.
} &
PRODUCER=$!

# md5 of the compressed stream, computed in flight. A FIFO rather than
# `tee >(md5sum)` so there is a pid to wait on and the result is guaranteed
# complete before it is compared.
MD5_FIFO="$WORK/md5.fifo"
rm -f "$MD5_FIFO"
mkfifo "$MD5_FIFO"
md5sum < "$MD5_FIFO" | awk '{print $1}' > "$WORK/md5.out" &
MD5PID=$!

# Consumer: concatenate chunks in order, deleting each as it is consumed, so
# download and extraction overlap and the archive never exists as a file.
#
# --strip-components=1 removes the single `nvhpc_2025_255_.../` top level that
# rattler-build's own extractor would have collapsed for us. The assertion
# after the pipeline is what makes this safe: if a future archive ever gains a
# second top-level entry, stripping would silently discard it, and the missing
# installer turns that into a loud failure instead.
for ((i = 0; i < N; i++)); do
  f="$DL/$(printf "c%05d" "$i")"
  while [ ! -f "$f" ]; do
    # If the producer has finished and this chunk still is not there, it never
    # will be. (On a clean run every chunk exists by the time the sentinel is
    # written, so this only fires on real failures.)
    if [ -f "$PRODUCER_STATUS" ] && [ ! -f "$f" ]; then
      echo "[nvhpc] download ended before chunk $i appeared ($(cat "$PRODUCER_STATUS"))" >&2
      exit 1
    fi
    sleep 0.2
  done
  cat "$f"
  rm -f "$f"
done | tee "$MD5_FIFO" | igzip -dc | tar xp --strip-components=1 -C "$EXTRACT"

wait $PRODUCER
wait $MD5PID
[ "$(cat "$PRODUCER_STATUS")" = ok ] || { echo "[nvhpc] chunk download failed" >&2; exit 1; }
rm -f "$MD5_FIFO" "$PRODUCER_STATUS"
# rmdir, not rm -rf: a leftover chunk would mean the consumer skipped one.
rmdir "$DL"

GOT_MD5=$(cat "$WORK/md5.out")
if [ "$GOT_MD5" != "$NVHPC_MD5" ]; then
  echo "[nvhpc] md5 mismatch: got $GOT_MD5, expected $NVHPC_MD5" >&2
  exit 1
fi
rm -f "$WORK/md5.out"
stage "downloaded+extracted"

SRC="$EXTRACT/install_components"
INSTALLER="$SRC/install"
[ -f "$INSTALLER" ] || {
  echo "[nvhpc] $INSTALLER missing after extraction -- archive layout changed" >&2
  exit 1
}

# The installer unpacks $arch.examples.tar.gz into the install dir at the end.
# We delete the examples immediately afterwards anyway, so drop the tarball
# first and skip both the disk and the time. The installer guards the step with
# `test -f`, so its absence is silent and supported.
rm -f "$SRC"/*.examples.tar.gz

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
# The stock installer populates the install dir with
#   tar cf - $i | ( cd $INSTALL_DIR; tar xf - )
# i.e. a full ~19 GB byte copy, even though source and destination are on the
# same filesystem. Rewrite it as a rename: instant, and it halves peak disk.
#
# The grep guard is the important half. NVIDIA can reformat this line in any
# release, and a silently non-matching sed would produce a half-installed tree
# that fails much later and much more confusingly -- a failure mode already hit
# while developing setup-nvhpc.sh. Verified present verbatim in 25.5 (line 303).
if ! grep -q 'tar  cf - \$i | ( cd \$INSTALL_DIR; tar  xf - )' "$INSTALLER"; then
  echo "[nvhpc] installer layout changed; refusing to patch. Candidate lines:" >&2
  grep -n 'tar .*cf -' "$INSTALLER" >&2 || true
  exit 1
fi
sed -e 's|^\( *\)tar  cf - \$i .*$|\1mkdir -p "$INSTALL_DIR/`dirname $i`" \&\& mv "$i" "$INSTALL_DIR/$i"|' \
  "$INSTALLER" > "$INSTALLER.fast"
chmod +x "$INSTALLER.fast"

# NVHPC_INSTALL_TYPE=auto matches SlaterGPU CI and the cloud environment, and is
# the right choice here for a second reason: `auto` is the only mode that does
# NOT run makelocalrc at install time. localrc is instead generated in the
# user's home directory on first use, so no build-machine paths get baked into
# the package.
export NVHPC_SILENT=true
export NVHPC_INSTALL_DIR="$PREFIX"
export NVHPC_INSTALL_TYPE=auto
"$INSTALLER.fast"

rm -rf "$EXTRACT"
stage "installed"

# ---------------------------------------------------------------------------
# Trim
# ---------------------------------------------------------------------------
# Everything removed here was verified unreferenced on a real install. The
# point is the disk budget: untrimmed, the package does not fit a 30 GB session.
ARCHDIR="$PREFIX/$(uname -s)_$(uname -m)"
NV="$ARCHDIR/$NVHPC_RELEASE"

# No cloud or CI machine this targets has a GPU to profile.
rm -rf "$NV/profilers"
find "$ARCHDIR" -depth -type d \( -name examples -o -name doc -o -name samples \) -exec rm -rf {} + 2>/dev/null || true

# DO NOT trim hpcx. The issue's trim table was measured on 25.1, which shipped a
# duplicate hpcx-2.20 beside `comm_libs/mpi -> 2.21`. 25.5 ships exactly one
# HPC-X (hpcx-2.22.1) and there is nothing to deduplicate. The trap is that
# `comm_libs/mpi` resolves to `comm_libs/hpcx`, a 1.6 MB directory holding only
# the wrapper binaries -- so a "keep whatever mpi points at" rule compares at the
# wrong level and deletes the actual stack under comm_libs/<cuda>/hpcx/, leaving
# an mpicc with nothing behind it.

# Unused by SlaterGPU / ZEST / XCtera, which use HPC-X and neither NCCL nor
# NVSHMEM. Note the version suffixes: the directories are nccl-2.18 / nccl-2.26,
# so a bare */nccl glob matches nothing and silently keeps 1.4 GiB.
for d in "$NV"/comm_libs/*/nccl-* "$NV"/comm_libs/*/nvshmem "$NV"/comm_libs/openmpi4; do
  [ -e "$d" ] || continue
  rm -rf "$d"
done

# The trims above orphan the aliases and REDIST entries that pointed into them
# (rattler-build reports each one as a packaging warning). Sweep them.
find "$ARCHDIR" -xtype l -delete 2>/dev/null || true

stage "trimmed"
echo "[nvhpc] installed size: $(du -sh "$PREFIX" 2>/dev/null | cut -f1)"
du -sh "$NV"/* 2>/dev/null | sort -h | tail -20 || true
