#!/usr/bin/env bash
set -euxo pipefail

# ==============================================================================
# MENHIR BUILD SCRIPT (Standalone Recipe)
# ==============================================================================
# Build the Menhir parser generator for OCaml using Dune.
# Standalone version - source extracts to ${SRC_DIR} directly.
#
# NOTE: menhir is published to the TARGET subdir. Its menhirLib/menhirSdk/
# menhirCST/coq-menhirlib .cmxa and .cmi files are linked into generated
# parsers on the target, so the built binary and libraries MUST be
# TARGET-arch, not BUILD-arch.
# ==============================================================================

source "${RECIPE_DIR}/building/build_functions.sh"

# ==============================================================================
# ENVIRONMENT SETUP
# ==============================================================================

cd "${SRC_DIR}"

# macOS: Set library path for zstd
if is_macos; then
  export DYLD_FALLBACK_LIBRARY_PATH="${BUILD_PREFIX}/lib:${PREFIX}/lib:${DYLD_FALLBACK_LIBRARY_PATH:-}"
fi

# Set install prefix
if is_non_unix; then
  export MENHIR_INSTALL_PREFIX="${PREFIX}/Library"
  export PATH="${BUILD_PREFIX}/bin:${BUILD_PREFIX}/Library/bin:${PATH}"
else
  export MENHIR_INSTALL_PREFIX="${PREFIX}"
fi

# ==============================================================================
# BUILD
# ==============================================================================

echo "=== Cross-compilation detection ==="
echo "  CONDA_BUILD_CROSS_COMPILATION: ${CONDA_BUILD_CROSS_COMPILATION:-not set}"
echo "  is_cross_compile: $(is_cross_compile && echo 'true' || echo 'false')"

if is_cross_compile; then
  # ===========================================================================
  # CROSS-COMPILATION PATH
  # ===========================================================================
  echo "=== Cross-compilation build ==="
  # menhir is published to the TARGET subdir: its menhirLib/menhirSdk/
  # menhirCST/coq-menhirlib .cmxa and .cmi files are linked into generated
  # parsers on the target, so the menhir binary and libraries built here
  # MUST be TARGET-arch (build_platform=${build_platform}, target_platform=${target_platform}).

  swap_ocaml_compilers
  setup_cross_c_compilers
  configure_cross_environment
  if is_macos; then
    create_macos_ocamlmklib_wrapper
  fi

  echo "  ocamlc: $(which ocamlc)"
  ocamlc -version
  DETECTED_ARCH=$(ocamlc -config | grep "^architecture:" | awk '{print $2}')
  echo "  Detected OCaml target architecture: ${DETECTED_ARCH:-(undetermined)}"
  echo "  OCAMLLIB: ${OCAMLLIB:-not set}"

  # Build menhir using dune
  if command -v dune &>/dev/null; then
    echo "Building menhir with dune..."
    dune build @install
  else
    echo "ERROR: dune not found - menhir requires dune build system"
    exit 1
  fi

  dune install --prefix="${MENHIR_INSTALL_PREFIX}" --libdir="${MENHIR_INSTALL_PREFIX}/lib" --mandir="${MENHIR_INSTALL_PREFIX}/share/man"

elif is_non_unix; then
  echo "=== Windows build ==="
  # OCaml reports its own C toolchain: msvc on the MSVC port, cc on mingw.
  # grep -a: ocamlc -config output can trip grep's binary detection.
  ocaml_ccomp_type="$(ocamlc -config 2>/dev/null | grep -a '^ccomp_type:' | awk '{print $2}')"
  if [[ "${ocaml_ccomp_type}" != "msvc" ]]; then
    export PATH="${BUILD_PREFIX}/Library/mingw-w64/bin:${BUILD_PREFIX}/Library/bin:${BUILD_PREFIX}/bin:${PATH}"
  else
    export PATH="${BUILD_PREFIX}/Library/bin:${BUILD_PREFIX}/bin:${PATH}"
  fi
  echo "  ocamlc ccomp_type: ${ocaml_ccomp_type:-(undetermined)}"
  echo "  ml64: $(command -v ml64 || echo 'NOT FOUND')"
  echo "  cygpath: $(command -v cygpath || echo 'NOT FOUND')"

  # dune's windows cache layout mis-handles mixed path separators and dies in
  # mkdir_p on $SRC_DIR/dune/db. The cache buys nothing in a one-shot CI build.
  export DUNE_CACHE=disabled

  dune build @install
  dune install --prefix="${MENHIR_INSTALL_PREFIX}" --libdir="${MENHIR_INSTALL_PREFIX}/lib" --mandir="${MENHIR_INSTALL_PREFIX}/share/man"

else
  echo "=== Native build ==="
  dune build @install
  dune install --prefix="${MENHIR_INSTALL_PREFIX}" --libdir="${MENHIR_INSTALL_PREFIX}/lib" --mandir="${MENHIR_INSTALL_PREFIX}/share/man"
fi

# ==============================================================================
# WRITE OCAML BUILD VERSION FOR TESTS
# ==============================================================================
# Tests need to know the OCaml version used during build to distinguish
# between known bugs (OCaml <= 5.3.0) and real failures (OCaml >= 5.4.0)

TEST_FILES_DIR="${PREFIX}/etc/conda/test-files"
mkdir -p "${TEST_FILES_DIR}"
OCAML_BUILD_VERSION=$(ocamlc -version)
echo "${OCAML_BUILD_VERSION}" > "${TEST_FILES_DIR}/ocaml-build-version"
echo "Wrote OCaml build version ${OCAML_BUILD_VERSION} to ${TEST_FILES_DIR}/ocaml-build-version"

echo "${target_platform}" > "${TEST_FILES_DIR}/target-platform"
echo "Wrote target platform ${target_platform} to ${TEST_FILES_DIR}/target-platform"

# ==============================================================================
# VERIFY INSTALLATION
# ==============================================================================

if is_non_unix; then
  MENHIR_BIN="${MENHIR_INSTALL_PREFIX}/bin/menhir.exe"
  ALT_MENHIR_BIN="${MENHIR_INSTALL_PREFIX}/bin/menhir"
else
  MENHIR_BIN="${MENHIR_INSTALL_PREFIX}/bin/menhir"
  ALT_MENHIR_BIN="${MENHIR_INSTALL_PREFIX}/bin/menhir.exe"
fi

if [[ -f "${MENHIR_BIN}" ]] || [[ -f "${ALT_MENHIR_BIN}" ]]; then
  # Use whichever exists
  [[ -f "${MENHIR_BIN}" ]] && ACTUAL_BIN="${MENHIR_BIN}" || ACTUAL_BIN="${ALT_MENHIR_BIN}"

  echo "=== Menhir installed successfully ==="
  echo "Binary: ${ACTUAL_BIN}"

  # For cross-compilation, verify the installed binary matches the TARGET
  # architecture: menhir is published to the TARGET subdir and its
  # menhirLib/menhirSdk/menhirCST/coq-menhirlib .cmxa and .cmi files are
  # linked into generated parsers on the target, so it must be TARGET-arch.
  if is_cross_compile; then
    case "${target_platform}" in
      linux-64) EXPECTED_ARCH_TOKEN="x86-64" ;;
      osx-64) EXPECTED_ARCH_TOKEN="x86_64" ;;
      linux-aarch64) EXPECTED_ARCH_TOKEN="aarch64" ;;
      osx-arm64) EXPECTED_ARCH_TOKEN="arm64" ;;
      linux-ppc64le) EXPECTED_ARCH_TOKEN="PowerPC" ;;
      *)
        echo "ERROR: unrecognised target_platform '${target_platform}' - no known 'file' architecture token to assert against"
        exit 1
        ;;
    esac
    FILE_OUTPUT=$(file "${ACTUAL_BIN}")
    echo "${FILE_OUTPUT}"
    if echo "${FILE_OUTPUT}" | grep -q "${EXPECTED_ARCH_TOKEN}"; then
      echo "[OK] Binary is correctly built for TARGET architecture (${target_platform}, expected '${EXPECTED_ARCH_TOKEN}')"
    else
      echo "ERROR: menhir binary architecture mismatch"
      echo "  target_platform: ${target_platform}"
      echo "  expected 'file' token: ${EXPECTED_ARCH_TOKEN}"
      echo "  actual 'file' output: ${FILE_OUTPUT}"
      exit 1
    fi
  elif ! is_non_unix; then
    # Native Unix build - show file info (optional)
    file "${ACTUAL_BIN}" || true
  fi

  # Windows: file command unavailable, just verify binary exists and is non-empty
  if is_non_unix; then
    if [[ -s "${ACTUAL_BIN}" ]]; then
      echo "[OK] Binary exists and is non-empty"
    else
      echo "WARNING: Binary is empty or missing"
      exit 1
    fi
  fi
else
  echo "ERROR: Menhir binary not found at ${MENHIR_BIN} or ${ALT_MENHIR_BIN}"
  exit 1
fi

echo "=== Menhir build complete ==="
