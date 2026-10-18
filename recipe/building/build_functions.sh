# ==============================================================================
# Build Helper Functions (Standalone Recipe Version)
# ==============================================================================
# Simplified helper functions for standalone conda-forge recipes.
# ==============================================================================

# ==============================================================================
# PLATFORM DETECTION
# ==============================================================================

is_macos() { [[ "${target_platform}" == "osx-"* ]]; }
is_linux() { [[ "${target_platform}" == "linux-"* ]]; }
is_non_unix() { [[ "${target_platform}" != "linux-"* ]] && [[ "${target_platform}" != "osx-"* ]]; }
is_cross_compile() {
  # 1. conda-build's own flag, when it survives activation ordering.
  [[ "${CONDA_BUILD_CROSS_COMPILATION:-}" == "1" ]] && return 0
  # 2. explicit platform pair, when both reach the shell.
  [[ -n "${build_platform:-}" && -n "${target_platform:-}" \
     && "${build_platform}" != "${target_platform}" ]] && return 0
  # 3. target subdir vs the machine we are actually running on.
  #    target_platform is reliably exported (build.sh writes it to
  #    etc/conda/test-files/target-platform).
  if [[ -n "${target_platform:-}" ]]; then
    case "$(uname -s):$(uname -m):${target_platform}" in
      Linux:x86_64:linux-64|Linux:aarch64:linux-aarch64|Linux:ppc64le:linux-ppc64le) ;;
      Linux:riscv64:linux-riscv64|Linux:s390x:linux-s390x) ;;
      Darwin:x86_64:osx-64|Darwin:arm64:osx-arm64) ;;
      *NT*:*:win-64|MSYS*:*:win-64|MINGW*:*:win-64|CYGWIN*:*:win-64) ;;
      *NT*:*:win-arm64|MSYS*:*:win-arm64|MINGW*:*:win-arm64|CYGWIN*:*:win-arm64) ;;
      *) return 0 ;;
    esac
  fi
  return 1
}

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

warn() {
  echo "WARNING: $*" >&2
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

# ==============================================================================
# MACOS HELPERS
# ==============================================================================

create_macos_ocamlmklib_wrapper() {
  echo "  Creating macOS ocamlmklib wrapper..."
  local real_ocamlmklib="${BUILD_PREFIX}/bin/ocamlmklib"

  if [[ -f "${real_ocamlmklib}" ]] && [[ ! -f "${real_ocamlmklib}.real" ]]; then
    mv "${real_ocamlmklib}" "${real_ocamlmklib}.real"
    cat > "${real_ocamlmklib}" << 'WRAPPER_EOF'
#!/bin/bash
exec "${0}.real" -ldopt "-Wl,-undefined,dynamic_lookup" "$@"
WRAPPER_EOF
    chmod +x "${real_ocamlmklib}"
  fi
}
