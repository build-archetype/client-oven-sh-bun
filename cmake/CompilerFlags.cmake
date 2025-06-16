# clang: https://clang.llvm.org/docs/CommandGuide/clang.html
# clang-cl: https://clang.llvm.org/docs/UsersManual.html#id11

# --- Macros ---

macro(setb variable)
  if(${variable})
    set(${variable} ON)
  else()
    set(${variable} OFF)
  endif()
endmacro()

set(targets WIN32 APPLE UNIX LINUX)

foreach(target ${targets})
  setb(${target})
endforeach()

# --- CPU target ---
if(CMAKE_SYSTEM_PROCESSOR MATCHES "arm|ARM|arm64|ARM64|aarch64|AARCH64")
  if(APPLE)
    register_compiler_flags(-mcpu=apple-m1)
  else()
    register_compiler_flags(-march=armv8-a+crc -mtune=ampere1)
  endif()
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|X86_64|x64|X64|amd64|AMD64")
  if(ENABLE_BASELINE)
    register_compiler_flags(-march=nehalem)
  else()
    register_compiler_flags(-march=haswell)
  endif()
else()
  unsupported(CMAKE_SYSTEM_PROCESSOR)
endif()

# --- MSVC runtime ---
if(WIN32)
  register_compiler_flags(
    DESCRIPTION "Use static MSVC runtime"
    /MTd ${DEBUG}
    /MT ${RELEASE}
    /U_DLL
  )
endif()

if(ENABLE_ASAN)
  register_compiler_flags(
    DESCRIPTION "Enable AddressSanitizer"
    -fsanitize=address
  )
endif()

# --- Optimization level ---
if(DEBUG)
  register_compiler_flags(
    DESCRIPTION "Disable optimization"
    /Od ${WIN32}
    -O0 ${UNIX}
  )
elseif(ENABLE_SMOL)
  register_compiler_flags(
    DESCRIPTION "Optimize for size"
    /Os ${WIN32}
    -Os ${UNIX}
  )
else()
  register_compiler_flags(
    DESCRIPTION "Optimize for speed"
    /O2 ${WIN32} # TODO: change to /0t (same as -O3) to match macOS and Linux?
    -O3 ${UNIX}
  )
endif()

# --- Debug level ---
if(WIN32)
  register_compiler_flags(
    DESCRIPTION "Enable debug symbols (.pdb)"
    /Z7
  )
elseif(APPLE)
  register_compiler_flags(
    DESCRIPTION "Enable debug symbols (.dSYM)"
    -gdwarf-4
  )
endif()

if(UNIX)
  register_compiler_flags(
    DESCRIPTION "Enable debug symbols"
    -g3 -gz=zstd ${DEBUG}
    -g1 ${RELEASE}
  )

  register_compiler_flags(
    DESCRIPTION "Optimize debug symbols for LLDB"
    -glldb
  )
endif()

# TODO: consider other debug options
# -fdebug-macro # Emit debug info for macros
# -fstandalone-debug # Emit debug info for non-system libraries
# -fno-eliminate-unused-debug-types # Don't eliminate unused debug symbols

# --- C/C++ flags ---
register_compiler_flags(
  DESCRIPTION "Disable C/C++ exceptions"
  -fno-exceptions ${UNIX}
  /EHsc ${WIN32} # (s- disables C++, c- disables C)
)

register_compiler_flags(
  DESCRIPTION "Disable C++ static destructors"
  LANGUAGES CXX
  -Xclang ${WIN32}
  -fno-c++-static-destructors
)

register_compiler_flags(
  DESCRIPTION "Disable runtime type information (RTTI)"
  /GR- ${WIN32}
  -fno-rtti ${UNIX}
)

register_compiler_flags(
  DESCRIPTION "Keep frame pointers"
  /Oy- ${WIN32}
  -fno-omit-frame-pointer ${UNIX}
  -mno-omit-leaf-frame-pointer ${UNIX}
)

if(UNIX)
  register_compiler_flags(
    DESCRIPTION "Set C/C++ visibility to hidden"
    -fvisibility=hidden
    -fvisibility-inlines-hidden
  )

  register_compiler_flags(
    DESCRIPTION "Disable unwind tables"
    -fno-unwind-tables
    -fno-asynchronous-unwind-tables
  )

  # needed for libuv stubs because they use
  # C23 feature which lets you define parameter without
  # name
  # Only add this flag if clang version is 17 or higher
  if(CMAKE_CXX_COMPILER_VERSION VERSION_GREATER_EQUAL "17.0.0")
    register_compiler_flags(
      DESCRIPTION "Allow C23 extensions"
      -Wno-c23-extensions
    )
  endif()
endif()

register_compiler_flags(
  DESCRIPTION "Place each function in its own section"
  -ffunction-sections ${UNIX}
  /Gy ${WIN32}
)

register_compiler_flags(
  DESCRIPTION "Place each data item in its own section"
  -fdata-sections ${UNIX}
  /Gw ${WIN32}
)

# having this enabled in debug mode on macOS >=14 causes libarchive to fail to configure with the error:
# > pid_t doesn't exist on this platform?
if((DEBUG AND LINUX) OR((NOT DEBUG) AND UNIX))
  register_compiler_flags(
    DESCRIPTION "Emit an address-significance table"
    -faddrsig
  )
endif()

if(WIN32)
  register_compiler_flags(
    DESCRIPTION "Enable string pooling"
    /GF
  )

  register_compiler_flags(
    DESCRIPTION "Assume thread-local variables are defined in the executable"
    /GA
  )
endif()

# --- Linker flags ---
if(LINUX)
  register_linker_flags(
    DESCRIPTION "Disable relocation read-only (RELRO)"
    -Wl,-z,norelro
  )
  register_compiler_flags(
    DESCRIPTION "Disable semantic interposition"
    -fno-semantic-interposition
  )
endif()

# --- Assertions ---

# Note: This is a helpful guide about assertions:
# https://best.openssf.org/Compiler-Hardening-Guides/Compiler-Options-Hardening-Guide-for-C-and-C++
if(ENABLE_ASSERTIONS)
  register_compiler_flags(
    DESCRIPTION "Do not eliminate null-pointer checks"
    -fno-delete-null-pointer-checks
  )

  register_compiler_definitions(
    DESCRIPTION "Enable libc++ assertions"
    _LIBCPP_ENABLE_ASSERTIONS=1
    _LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_EXTENSIVE ${RELEASE}
    _LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_DEBUG ${DEBUG}
  )

  register_compiler_definitions(
    DESCRIPTION "Enable fortified sources"
    _FORTIFY_SOURCE=3
  )

  if(LINUX)
    register_compiler_definitions(
      DESCRIPTION "Enable glibc++ assertions"
      _GLIBCXX_ASSERTIONS=1
    )
  endif()
else()
  register_compiler_definitions(
    DESCRIPTION "Disable debug assertions"
    NDEBUG=1
  )

  register_compiler_definitions(
    DESCRIPTION "Disable libc++ assertions"
    _LIBCPP_ENABLE_ASSERTIONS=0
    _LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_NONE
  )

  if(LINUX)
    register_compiler_definitions(
      DESCRIPTION "Disable glibc++ assertions"
      _GLIBCXX_ASSERTIONS=0
    )
  endif()
endif()

# --- Diagnostics ---
if(UNIX)
  register_compiler_flags(
    DESCRIPTION "Enable color diagnostics"
    -fdiagnostics-color=always
  )
endif()

register_compiler_flags(
  DESCRIPTION "Set C/C++ error limit"
  -ferror-limit=${ERROR_LIMIT}
)

# --- LTO ---
if(ENABLE_LTO)
  register_compiler_flags(
    DESCRIPTION "Enable link-time optimization (LTO)"
    -flto=full ${UNIX}
    -flto ${WIN32}
  )

  if(UNIX)
    register_compiler_flags(
      DESCRIPTION "Enable virtual tables"
      LANGUAGES CXX
      -fforce-emit-vtables
      -fwhole-program-vtables
    )

    register_linker_flags(
      DESCRIPTION "Enable link-time optimization (LTO)"
      -flto=full
      -fwhole-program-vtables
      -fforce-emit-vtables
    )
  endif()
endif()

# --- Remapping ---
if(UNIX AND CI)
  # Check if we're in a Tart mounted directory (paths containing "My Shared Files")
  # If so, skip file prefix mapping to avoid compiler flag parsing issues with spaces
  string(FIND "${CWD}" "My Shared Files" TART_MOUNT_FOUND)
  
  if(TART_MOUNT_FOUND EQUAL -1)
    # Normal environment - use file prefix mapping
    register_compiler_flags(
      DESCRIPTION "Remap source files"
      -ffile-prefix-map=${CWD}=.
      -ffile-prefix-map=${VENDOR_PATH}=vendor
      -ffile-prefix-map=${CACHE_PATH}=cache
    )
  else()
    # Tart mounted directory - skip remapping to avoid space-in-path issues
    message(STATUS "Detected Tart mounted directory - skipping file prefix remapping")
  endif()
endif()

# --- Tart mounted filesystem header fixes ---
if(UNIX AND CI)
  # Check multiple variables to detect Tart mounted directories more reliably
  set(TART_MOUNT_FOUND -1)
  string(FIND "${CWD}" "My Shared Files" TART_MOUNT_FOUND_CWD)
  string(FIND "${CMAKE_SOURCE_DIR}" "My Shared Files" TART_MOUNT_FOUND_SRC)
  string(FIND "${CMAKE_BUILD_ROOT}" "My Shared Files" TART_MOUNT_FOUND_BUILD)
  
  if(TART_MOUNT_FOUND_CWD GREATER -1 OR TART_MOUNT_FOUND_SRC GREATER -1 OR TART_MOUNT_FOUND_BUILD GREATER -1)
    set(TART_MOUNT_FOUND 1)
    message(STATUS "Detected Tart mounted directory - applying header duplication fixes")
    message(STATUS "  CWD: ${CWD}")
    message(STATUS "  CMAKE_SOURCE_DIR: ${CMAKE_SOURCE_DIR}")
    message(STATUS "  CMAKE_BUILD_ROOT: ${CMAKE_BUILD_ROOT}")
    
    # Primary fix: Create symlinks without spaces for problematic directories
    set(TART_BINDINGS_LINK "/tmp/bun-bindings")
    set(TART_MODULES_LINK "/tmp/bun-modules") 
    set(TART_BUNJS_LINK "/tmp/bun-js")
    
    # Clean up any existing symlinks
    execute_process(COMMAND rm -f "${TART_BINDINGS_LINK}" "${TART_MODULES_LINK}" "${TART_BUNJS_LINK}")
    
    # Create new symlinks
    execute_process(COMMAND ln -sf "${CWD}/src/bun.js/bindings" "${TART_BINDINGS_LINK}")
    execute_process(COMMAND ln -sf "${CWD}/src/bun.js/modules" "${TART_MODULES_LINK}")
    execute_process(COMMAND ln -sf "${CWD}/src/bun.js" "${TART_BUNJS_LINK}")
    
    message(STATUS "Created symlinks: ${TART_BINDINGS_LINK}, ${TART_MODULES_LINK}, ${TART_BUNJS_LINK}")
    
    # Use symlinks for include directories 
    register_compiler_flags(
      DESCRIPTION "Fix header path resolution using space-free symlinks on mounted filesystems"
      LANGUAGES C CXX
      -isystem "${TART_BINDINGS_LINK}"
      -isystem "${TART_MODULES_LINK}"
      -isystem "${TART_BUNJS_LINK}"
      -fno-working-directory
      -fmodules-cache-path=/tmp/clang-modules-cache
      -fcanonicalize-system-headers
    )
    
    message(STATUS "Applied Tart header duplication fixes")
  endif()
endif()

# --- Features ---

# Valgrind cannot handle SSE4.2 instructions
# This is needed for picohttpparser
if(ENABLE_VALGRIND AND ARCH STREQUAL "x64")
  register_compiler_definitions(__SSE4_2__=0)
endif()

# --- Other ---

# Workaround for CMake and clang-cl bug.
# https://github.com/ninja-build/ninja/issues/2280
if(WIN32 AND NOT CMAKE_CL_SHOWINCLUDES_PREFIX)
  set(CMAKE_CL_SHOWINCLUDES_PREFIX "Note: including file:")
endif()

# WebKit uses -std=gnu++20 on non-macOS non-Windows.
# If we do not set this, it will crash at startup on the first memory allocation.
if(NOT WIN32 AND NOT APPLE)
  set(CMAKE_CXX_EXTENSIONS ON)
  set(CMAKE_POSITION_INDEPENDENT_CODE OFF)
endif()
