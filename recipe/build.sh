#!/usr/bin/env bash
set -euxo pipefail

# ==============================================================================
# MENHIR BUILD SCRIPT (Standalone Recipe)
# ==============================================================================
# Build the Menhir parser generator for OCaml using Dune.
# Standalone version - source extracts to ${SRC_DIR} directly.
#
# CRITICAL: For cross-compilation, menhir is a BUILD TOOL that runs on the
# BUILD machine, not the TARGET. It generates .ml/.mli from .mly grammars.
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
  export MENHIR_INSTALL_PREFIX="${_PREFIX_}/Library"
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
  echo "CRITICAL: menhir is a BUILD-TIME tool - building for BUILD arch (${build_platform})"

  # menhir runs on BUILD machine to generate .ml/.mli from .mly grammars
  # It does NOT need to be cross-compiled to TARGET arch

  # ===========================================================================
  # FIX: Override AS to use BUILD platform assembler
  # ===========================================================================
  # The activation scripts set AS to the cross-assembler (aarch64), but menhir
  # is a build-time tool that needs the native assembler.
  #
  # Available variables:
  #   CONDA_TOOLCHAIN_BUILD = x86_64-conda-linux-gnu (BUILD platform toolchain)
  #   CONDA_OCAML_AS = x86_64-conda-linux-gnu-as (OCaml's native assembler)
  #   CC_FOR_BUILD = native C compiler for BUILD platform
  #
  # OCaml's ocamlopt.opt uses AS environment variable for assembly.
  # ===========================================================================

  echo "=== Fixing toolchain for build-time tool ==="
  echo "  Current AS: ${AS:-not set}"
  echo "  Current CC: ${CC:-not set}"
  echo "  CONDA_TOOLCHAIN_BUILD: ${CONDA_TOOLCHAIN_BUILD:-not set}"
  echo "  CONDA_OCAML_AS: ${CONDA_OCAML_AS:-not set}"
  echo "  CC_FOR_BUILD: ${CC_FOR_BUILD:-not set}"

  # ===========================================================================
  # FIX: Ensure BUILD platform tools are found first in PATH
  # ===========================================================================
  # OCaml's ocamlopt does NOT honor the AS environment variable.
  # It invokes 'as' from PATH. During cross-compilation, the activation scripts
  # put the cross-toolchain first in PATH, so 'as' resolves to the TARGET assembler.
  #
  # Solution: Create a temporary directory with symlinks to BUILD platform tools
  # and prepend it to PATH. This ensures 'as', 'ld', etc. resolve to x86_64 versions.
  # ===========================================================================

  BUILD_TOOLS_DIR=$(mktemp -d)
  echo "  Creating BUILD platform tools directory: ${BUILD_TOOLS_DIR}"

  # Create symlinks for assembler, linker, and common tools
  if [[ -n "${CONDA_TOOLCHAIN_BUILD:-}" ]]; then
    if is_macos; then
      # macOS: Use LLVM tools (llvm-ar, llvm-ranlib, lld) - same as OCaml build
      for tool in as; do
        BUILD_TOOL="${BUILD_PREFIX}/bin/${CONDA_TOOLCHAIN_BUILD}-${tool}"
        if [[ -x "${BUILD_TOOL}" ]]; then
          ln -sf "${BUILD_TOOL}" "${BUILD_TOOLS_DIR}/${tool}"
        fi
      done
      # LLVM tools for archiving and linking
      if [[ -x "${BUILD_PREFIX}/bin/llvm-ar" ]]; then
        ln -sf "${BUILD_PREFIX}/bin/llvm-ar" "${BUILD_TOOLS_DIR}/ar"
      fi
      if [[ -x "${BUILD_PREFIX}/bin/llvm-ranlib" ]]; then
        ln -sf "${BUILD_PREFIX}/bin/llvm-ranlib" "${BUILD_TOOLS_DIR}/ranlib"
      fi
      if [[ -x "${BUILD_PREFIX}/bin/llvm-nm" ]]; then
        ln -sf "${BUILD_PREFIX}/bin/llvm-nm" "${BUILD_TOOLS_DIR}/nm"
      fi
      if [[ -x "${BUILD_PREFIX}/bin/ld64.lld" ]]; then
        ln -sf "${BUILD_PREFIX}/bin/ld64.lld" "${BUILD_TOOLS_DIR}/ld"
      elif [[ -x "${BUILD_PREFIX}/bin/lld" ]]; then
        ln -sf "${BUILD_PREFIX}/bin/lld" "${BUILD_TOOLS_DIR}/ld"
      fi
    else
      # Linux: Override all tools including ar/ranlib
      for tool in as ld ar nm ranlib objcopy objdump strip; do
        BUILD_TOOL="${BUILD_PREFIX}/bin/${CONDA_TOOLCHAIN_BUILD}-${tool}"
        if [[ -x "${BUILD_TOOL}" ]]; then
          ln -sf "${BUILD_TOOL}" "${BUILD_TOOLS_DIR}/${tool}"
        fi
      done
    fi
  fi

  # Prepend to PATH so BUILD tools are found first
  export PATH="${BUILD_TOOLS_DIR}:${PATH}"

  # Set environment variables for tools that DO honor them
  if [[ -n "${CONDA_TOOLCHAIN_BUILD:-}" ]]; then
    export AS="${CONDA_TOOLCHAIN_BUILD}-as"
    if is_macos; then
      # macOS: Use LLVM tools - same as OCaml build
      export LD="ld64.lld"
      export AR="llvm-ar"
      export RANLIB="llvm-ranlib"
      export NM="llvm-nm"
    else
      # Linux: Use conda toolchain
      export LD="${CONDA_TOOLCHAIN_BUILD}-ld"
      export AR="${CONDA_TOOLCHAIN_BUILD}-ar"
      export RANLIB="${CONDA_TOOLCHAIN_BUILD}-ranlib"
    fi
  fi

  # Override CC to use build platform compiler for any C code
  if [[ -n "${CC_FOR_BUILD:-}" ]]; then
    export CC="${CC_FOR_BUILD}"
  elif [[ -n "${CONDA_TOOLCHAIN_BUILD:-}" ]]; then
    if is_macos; then
      export CC="${BUILD_PREFIX}/bin/${CONDA_TOOLCHAIN_BUILD}-clang"
    else
      export CC="${BUILD_PREFIX}/bin/${CONDA_TOOLCHAIN_BUILD}-gcc"
    fi
  fi

  # ===========================================================================
  # CRITICAL: Override CONDA_OCAML_* environment variables
  # ===========================================================================
  # The OCaml activation scripts set these to TARGET tools during cross-compilation.
  # OCaml's native code compiler uses these when assembling and linking.
  # We MUST override them to use BUILD platform tools for build-time tools like menhir.
  # ===========================================================================
  if [[ -n "${CONDA_TOOLCHAIN_BUILD:-}" ]]; then
    export CONDA_OCAML_AS="${CONDA_TOOLCHAIN_BUILD}-as"

    # Platform-specific toolchain selection
    if is_macos; then
      # macOS: Use LLVM tools - consistent with OCaml build
      export CONDA_OCAML_LD="ld64.lld"
      export CONDA_OCAML_AR="llvm-ar"
      export CONDA_OCAML_RANLIB="llvm-ranlib"
      # macOS: Use clang and -dynamiclib for shared libraries
      export CONDA_OCAML_CC="${BUILD_PREFIX}/bin/${CONDA_TOOLCHAIN_BUILD}-clang"
      export CONDA_OCAML_MKEXE="${BUILD_PREFIX}/bin/${CONDA_TOOLCHAIN_BUILD}-clang"
      export CONDA_OCAML_MKDLL="${BUILD_PREFIX}/bin/${CONDA_TOOLCHAIN_BUILD}-clang -dynamiclib"
    else
      # Linux: Use conda toolchain
      export CONDA_OCAML_LD="${CONDA_TOOLCHAIN_BUILD}-ld"
      export CONDA_OCAML_AR="${CONDA_TOOLCHAIN_BUILD}-ar"
      export CONDA_OCAML_RANLIB="${CONDA_TOOLCHAIN_BUILD}-ranlib"
      export CONDA_OCAML_CC="${BUILD_PREFIX}/bin/${CONDA_TOOLCHAIN_BUILD}-gcc"
      export CONDA_OCAML_MKEXE="${BUILD_PREFIX}/bin/${CONDA_TOOLCHAIN_BUILD}-gcc -Wl,-E -ldl"
      export CONDA_OCAML_MKDLL="${BUILD_PREFIX}/bin/${CONDA_TOOLCHAIN_BUILD}-gcc -shared"
    fi
  fi

  # Clear cross-compilation flags that would interfere with build-time tool
  unset CFLAGS CXXFLAGS LDFLAGS 2>/dev/null || true

  echo "  Overridden AS: ${AS:-not set}"
  echo "  Overridden CC: ${CC:-not set}"
  echo "  Overridden LD: ${LD:-not set}"
  echo "  Overridden AR: ${AR:-not set}"
  echo "  Overridden CONDA_OCAML_AS: ${CONDA_OCAML_AS:-not set}"
  echo "  Overridden CONDA_OCAML_CC: ${CONDA_OCAML_CC:-not set}"
  echo "  Overridden CONDA_OCAML_AR: ${CONDA_OCAML_AR:-not set}"
  echo "  which as: $(which as)"
  echo "  which ld: $(which ld)"
  echo "  which ar: $(which ar)"

  # Ensure we use BUILD compiler (not cross-compiler)
  # The native OCaml compiler should already be in PATH from build deps

  echo "Using native OCaml compiler for menhir (BUILD arch)..."
  echo "  ocamlc: $(which ocamlc)"
  ocamlc -version

  # Verify it's native arch (not cross-arch)
  DETECTED_ARCH=$(ocamlc -config | grep "^architecture:" | awk '{print $2}')
  echo "  Detected architecture: ${DETECTED_ARCH}"

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
  export PATH="${BUILD_PREFIX}/Library/mingw-w64/bin:${BUILD_PREFIX}/Library/bin:${BUILD_PREFIX}/bin:${PATH}"

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

  # For cross-compilation, verify it's BUILD arch (NOT target arch)
  # menhir runs on build machine, so it must be native to build platform
  if is_cross_compile; then
    file "${ACTUAL_BIN}"
    # Expected BUILD arch patterns
    if file "${ACTUAL_BIN}" | grep -qE "(x86-64|x86_64)"; then
      echo "✓ Binary is correctly built for BUILD architecture (x86_64)"
    else
      echo "⚠ WARNING: menhir should be BUILD arch (x86_64), not TARGET arch"
      echo "  This is a BUILD-TIME tool that runs on the build machine!"
      file "${ACTUAL_BIN}"
      exit 1
    fi
  elif ! is_non_unix; then
    # Native Unix build - show file info (optional)
    file "${ACTUAL_BIN}" || true
  fi

  # Windows: file command unavailable, just verify binary exists and is non-empty
  if is_non_unix; then
    if [[ -s "${ACTUAL_BIN}" ]]; then
      echo "✓ Binary exists and is non-empty"
    else
      echo "⚠ WARNING: Binary is empty or missing"
      exit 1
    fi
  fi
else
  echo "ERROR: Menhir binary not found at ${MENHIR_BIN} or ${ALT_MENHIR_BIN}"
  exit 1
fi

echo "=== Menhir build complete ==="
