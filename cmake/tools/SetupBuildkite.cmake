if(APPLE AND CI)
  set(DEFAULT_BUILDKITE_CACHE ON)
else()
  set(DEFAULT_BUILDKITE_CACHE ${BUILDKITE})
endif()

optionx(BUILDKITE_CACHE BOOL "If the build can use Buildkite caches, even if not running in Buildkite" DEFAULT ${DEFAULT_BUILDKITE_CACHE})

# Cache restoration should happen for all build types (cpp, zig, link)
# Only skip if BUILDKITE_CACHE is disabled
if(NOT BUILDKITE_CACHE)
  return()
endif()

optionx(BUILDKITE_ORGANIZATION_SLUG STRING "The organization slug to use on Buildkite" DEFAULT "bun")
optionx(BUILDKITE_PIPELINE_SLUG STRING "The pipeline slug to use on Buildkite" DEFAULT "bun")
optionx(BUILDKITE_BUILD_ID STRING "The build ID to use on Buildkite")
optionx(BUILDKITE_GROUP_ID STRING "The group ID to use on Buildkite")

if(ENABLE_BASELINE)
  set(DEFAULT_BUILDKITE_GROUP_KEY ${OS}-${ARCH}-baseline)
else()
  set(DEFAULT_BUILDKITE_GROUP_KEY ${OS}-${ARCH})
endif()

optionx(BUILDKITE_GROUP_KEY STRING "The group key to use on Buildkite" DEFAULT ${DEFAULT_BUILDKITE_GROUP_KEY})

if(BUILDKITE)
  optionx(BUILDKITE_BUILD_ID_OVERRIDE STRING "The build ID to use on Buildkite")
  if(BUILDKITE_BUILD_ID_OVERRIDE)
    setx(BUILDKITE_BUILD_ID ${BUILDKITE_BUILD_ID_OVERRIDE})
  endif()
endif()

set(BUILDKITE_PATH ${BUILD_PATH}/buildkite)
set(BUILDKITE_BUILDS_PATH ${BUILDKITE_PATH}/builds)

# Store the current build ID for exclusion from cache search
set(CURRENT_BUILD_ID $ENV{BUILDKITE_BUILD_ID})

# Always search for the latest successful build with cache artifacts
# Don't use the current build ID - it hasn't uploaded cache yet!
message(STATUS "Searching for latest successful build with cache artifacts...")

find_command(
  VARIABLE NODE_EXECUTABLE
  COMMAND node
  REQUIRED OFF
)

if(NODE_EXECUTABLE)
  execute_process(
    COMMAND ${NODE_EXECUTABLE} ${CWD}/scripts/get-last-build-id.mjs --branch=current
    WORKING_DIRECTORY ${CWD}
    OUTPUT_VARIABLE DETECTED_BUILD_ID
    ERROR_VARIABLE BUILD_ID_ERROR
    OUTPUT_STRIP_TRAILING_WHITESPACE
    RESULT_VARIABLE DETECTION_RESULT
  )
  
  if(DETECTION_RESULT EQUAL 0 AND DETECTED_BUILD_ID)
    setx(BUILDKITE_BUILD_ID ${DETECTED_BUILD_ID})
    message(STATUS "Found latest successful build with cache: ${BUILDKITE_BUILD_ID}")
    if(CURRENT_BUILD_ID)
      message(STATUS "Current build ID ${CURRENT_BUILD_ID} excluded from cache search")
    endif()
  else()
    message(STATUS "Could not find a suitable build for cache restoration")
    if(BUILD_ID_ERROR)
      message(STATUS "Error: ${BUILD_ID_ERROR}")
    endif()
    
    # Fallback: try manual override if provided
    if(BUILDKITE_BUILD_ID_OVERRIDE)
      setx(BUILDKITE_BUILD_ID ${BUILDKITE_BUILD_ID_OVERRIDE})
      message(STATUS "Using manual build ID override: ${BUILDKITE_BUILD_ID}")
    else()
      return()
    endif()
  endif()
else()
  message(STATUS "Node.js not found, cannot auto-detect build ID")
  
  # Fallback: try manual override if provided
  if(BUILDKITE_BUILD_ID_OVERRIDE)
    setx(BUILDKITE_BUILD_ID ${BUILDKITE_BUILD_ID_OVERRIDE})
    message(STATUS "Using manual build ID override: ${BUILDKITE_BUILD_ID}")
  else()
    return()
  endif()
endif()

setx(BUILDKITE_BUILD_URL https://buildkite.com/${BUILDKITE_ORGANIZATION_SLUG}/${BUILDKITE_PIPELINE_SLUG}/builds/${BUILDKITE_BUILD_ID})
setx(BUILDKITE_BUILD_PATH ${BUILDKITE_BUILDS_PATH}/builds/${BUILDKITE_BUILD_ID})

# === CACHE RESTORATION ===
# Restore cache files immediately during CMake configuration
# This avoids dependency cycles and provides cache for all build steps

message(STATUS "Restoring Buildkite cache artifacts...")

if(BUILDKITE)
  set(CACHE_ARTIFACTS "ccache-cache.tar.gz" "zig-local-cache.tar.gz" "zig-global-cache.tar.gz")
  foreach(cache_artifact ${CACHE_ARTIFACTS})
    # Determine cache directory based on artifact name
    if(cache_artifact STREQUAL "ccache-cache.tar.gz")
      set(cache_dir ${CACHE_PATH}/ccache)
    elseif(cache_artifact STREQUAL "zig-local-cache.tar.gz")
      set(cache_dir ${CACHE_PATH}/zig/local)
    elseif(cache_artifact STREQUAL "zig-global-cache.tar.gz")
      set(cache_dir ${CACHE_PATH}/zig/global)
    endif()
    
    # Download cache artifact if available
    message(STATUS "  Attempting to download ${cache_artifact} from build ${BUILDKITE_BUILD_ID}")
    execute_process(
      COMMAND buildkite-agent artifact download ${cache_artifact} ${BUILD_PATH} --build ${BUILDKITE_BUILD_ID}
      WORKING_DIRECTORY ${BUILD_PATH}
      RESULT_VARIABLE download_result
      OUTPUT_VARIABLE download_output
      ERROR_VARIABLE download_error
    )
    
    if(download_result EQUAL 0 AND EXISTS ${BUILD_PATH}/${cache_artifact})
      # Extract cache to target directory
      file(MAKE_DIRECTORY ${cache_dir})
      execute_process(
        COMMAND ${CMAKE_COMMAND} -E tar xzf ${BUILD_PATH}/${cache_artifact}
        WORKING_DIRECTORY ${cache_dir}
        RESULT_VARIABLE extract_result
        OUTPUT_QUIET
        ERROR_QUIET
      )
      
      if(extract_result EQUAL 0)
        # Count files for reporting
        file(GLOB_RECURSE cache_files ${cache_dir}/*)
        list(LENGTH cache_files file_count)
        message(STATUS "  ✅ Restored ${cache_artifact}: ${file_count} files")
      else()
        message(STATUS "  ⚠️  Failed to extract ${cache_artifact}")
      endif()
      
      # Clean up downloaded archive
      file(REMOVE ${BUILD_PATH}/${cache_artifact})
    else()
      message(STATUS "  📭 No ${cache_artifact} found (exit code: ${download_result})")
      if(download_output)
        message(STATUS "    Output: ${download_output}")
      endif()
      if(download_error)
        message(STATUS "    Error: ${download_error}")
      endif()
    endif()
  endforeach()
else()
  message(STATUS "  ⚠️  Not running in Buildkite, skipping cache restoration")
endif()

# === END CACHE RESTORATION ===

# === BUILDKITE CACHE UPLOAD TARGETS ===
# Upload cache artifacts after builds complete
# These targets are created here after all BUILDKITE variables are properly set
# NOTE: This must be BEFORE the BUN_LINK_ONLY check so it runs for all build types
# HOWEVER: Only create cache upload targets for build steps that generate cache content

# Debug cache upload conditions
message(STATUS "=== CACHE UPLOAD DEBUG ===")
message(STATUS "BUILDKITE_CACHE: ${BUILDKITE_CACHE}")
message(STATUS "BUILDKITE: ${BUILDKITE}")
message(STATUS "CACHE_STRATEGY: ${CACHE_STRATEGY}")
message(STATUS "CACHE_PATH: ${CACHE_PATH}")
message(STATUS "BUILD_PATH: ${BUILD_PATH}")
message(STATUS "BUN_CPP_ONLY: ${BUN_CPP_ONLY}")
message(STATUS "BUN_LINK_ONLY: ${BUN_LINK_ONLY}")

# Determine which caches this build step should upload
set(UPLOAD_CCACHE OFF)
set(UPLOAD_ZIG_CACHES OFF)

if(BUN_CPP_ONLY)
  # C++ build step - upload ccache (generated during C++ compilation)
  set(UPLOAD_CCACHE ON)
  message(STATUS "C++ build step - will upload ccache")
elseif(NOT BUN_LINK_ONLY)
  # Zig build step - upload Zig caches (generated during Zig compilation)
  set(UPLOAD_ZIG_CACHES ON)
  message(STATUS "Zig build step - will upload Zig caches")
else()
  # Link step - no cache uploads (just links, doesn't generate new cache)
  message(STATUS "Link step - no cache uploads needed")
endif()

# Ensure cache directories exist (create them if they don't)
# This allows cache upload even when starting with empty cache
if(BUILDKITE_CACHE AND BUILDKITE)
  file(MAKE_DIRECTORY ${CACHE_PATH}/ccache)
  file(MAKE_DIRECTORY ${CACHE_PATH}/zig/local)
  file(MAKE_DIRECTORY ${CACHE_PATH}/zig/global)
  message(STATUS "Created cache directories for upload")
endif()

if(IS_DIRECTORY ${CACHE_PATH}/ccache)
  message(STATUS "ccache directory exists: ${CACHE_PATH}/ccache")
else()
  message(STATUS "ccache directory missing: ${CACHE_PATH}/ccache")
endif()
if(IS_DIRECTORY ${CACHE_PATH}/zig/local)
  message(STATUS "zig/local directory exists: ${CACHE_PATH}/zig/local")
else()
  message(STATUS "zig/local directory missing: ${CACHE_PATH}/zig/local")
endif()
if(IS_DIRECTORY ${CACHE_PATH}/zig/global)
  message(STATUS "zig/global directory exists: ${CACHE_PATH}/zig/global")
else()
  message(STATUS "zig/global directory missing: ${CACHE_PATH}/zig/global")
endif()
message(STATUS "=== END CACHE UPLOAD DEBUG ===")

# ccache upload target (only created in C++ build step)
if(UPLOAD_CCACHE AND BUILDKITE_CACHE AND BUILDKITE AND (CACHE_STRATEGY STREQUAL "read-write" OR CACHE_STRATEGY STREQUAL "write-only") AND IS_DIRECTORY ${CACHE_PATH}/ccache)
  # Cache enabled and directory exists - create real upload target
  register_command(
    TARGET upload-ccache-cache
    COMMENT "Uploading ccache cache"
    COMMAND ${CMAKE_COMMAND} -E chdir ${CACHE_PATH}/ccache ${CMAKE_COMMAND} -E tar czf ${BUILD_PATH}/ccache-cache.tar.gz .
    CWD ${BUILD_PATH}
    ARTIFACTS ${BUILD_PATH}/ccache-cache.tar.gz
  )
  message(STATUS "Created real ccache upload target")
elseif(UPLOAD_CCACHE)
  # Cache disabled or directory missing - create no-op target
  add_custom_target(upload-ccache-cache
    COMMAND ${CMAKE_COMMAND} -E echo "Skipping ccache cache upload \\(cache disabled or directory missing\\)"
    COMMENT "Skipping ccache cache upload"
  )
  message(STATUS "Created no-op ccache upload target")
endif()

# Zig local cache upload target (only created in Zig build step)
if(UPLOAD_ZIG_CACHES AND BUILDKITE_CACHE AND BUILDKITE AND (CACHE_STRATEGY STREQUAL "read-write" OR CACHE_STRATEGY STREQUAL "write-only") AND IS_DIRECTORY ${CACHE_PATH}/zig/local)
  # Cache enabled and directory exists - create real upload target
  register_command(
    TARGET upload-zig-local-cache
    COMMENT "Uploading Zig local cache"
    COMMAND ${CMAKE_COMMAND} -E chdir ${CACHE_PATH}/zig/local ${CMAKE_COMMAND} -E tar czf ${BUILD_PATH}/zig-local-cache.tar.gz .
    CWD ${BUILD_PATH}
    ARTIFACTS ${BUILD_PATH}/zig-local-cache.tar.gz
  )
  message(STATUS "Created real zig-local upload target")
elseif(UPLOAD_ZIG_CACHES)
  # Cache disabled or directory missing - create no-op target
  add_custom_target(upload-zig-local-cache
    COMMAND ${CMAKE_COMMAND} -E echo "Skipping Zig local cache upload \\(cache disabled or directory missing\\)"
    COMMENT "Skipping Zig local cache upload"
  )
  message(STATUS "Created no-op zig-local upload target")
endif()

# Zig global cache upload target (only created in Zig build step)
if(UPLOAD_ZIG_CACHES AND BUILDKITE_CACHE AND BUILDKITE AND (CACHE_STRATEGY STREQUAL "read-write" OR CACHE_STRATEGY STREQUAL "write-only") AND IS_DIRECTORY ${CACHE_PATH}/zig/global)
  # Cache enabled and directory exists - create real upload target
  register_command(
    TARGET upload-zig-global-cache
    COMMENT "Uploading Zig global cache"
    COMMAND ${CMAKE_COMMAND} -E chdir ${CACHE_PATH}/zig/global ${CMAKE_COMMAND} -E tar czf ${BUILD_PATH}/zig-global-cache.tar.gz .
    CWD ${BUILD_PATH}
    ARTIFACTS ${BUILD_PATH}/zig-global-cache.tar.gz
  )
  message(STATUS "Created real zig-global upload target")
elseif(UPLOAD_ZIG_CACHES)
  # Cache disabled or directory missing - create no-op target
  add_custom_target(upload-zig-global-cache
    COMMAND ${CMAKE_COMMAND} -E echo "Skipping Zig global cache upload \\(cache disabled or directory missing\\)"
    COMMENT "Skipping Zig global cache upload"
  )
  message(STATUS "Created no-op zig-global upload target")
endif()

# Meta target to upload all cache types (always exists for CI compatibility)
# Create appropriate dependencies based on which build step this is
set(UPLOAD_DEPENDENCIES)
if(UPLOAD_CCACHE)
  list(APPEND UPLOAD_DEPENDENCIES upload-ccache-cache)
endif()
if(UPLOAD_ZIG_CACHES)
  list(APPEND UPLOAD_DEPENDENCIES upload-zig-local-cache upload-zig-global-cache)
endif()

if(UPLOAD_DEPENDENCIES)
  add_custom_target(upload-all-caches
    COMMENT "Upload all cache artifacts"
    DEPENDS ${UPLOAD_DEPENDENCIES}
  )
  message(STATUS "Created upload-all-caches meta target with dependencies: ${UPLOAD_DEPENDENCIES}")
else()
  # Create no-op target for link step
  add_custom_target(upload-all-caches
    COMMAND ${CMAKE_COMMAND} -E echo "No caches to upload from this build step"
    COMMENT "No cache uploads needed"
  )
  message(STATUS "Created no-op upload-all-caches target")
endif()

# === BUILD ARTIFACT DOWNLOADING ===
# Only download build artifacts (libbun-*.a) for linking step
# Cache restoration above should run for all build types

if(NOT BUN_LINK_ONLY)
  message(STATUS "Skipping build artifact downloading - only needed for linking step")
  return()
endif()

file(
  DOWNLOAD ${BUILDKITE_BUILD_URL}
  HTTPHEADER "Accept: application/json"
  TIMEOUT 15
  STATUS BUILDKITE_BUILD_STATUS
  ${BUILDKITE_BUILD_PATH}/build.json
)
if(NOT BUILDKITE_BUILD_STATUS EQUAL 0)
  message(FATAL_ERROR "No build found: ${BUILDKITE_BUILD_STATUS} ${BUILDKITE_BUILD_URL}")
  return()
endif()

file(READ ${BUILDKITE_BUILD_PATH}/build.json BUILDKITE_BUILD)
string(JSON BUILDKITE_BUILD_UUID GET ${BUILDKITE_BUILD} id)
string(JSON BUILDKITE_JOBS GET ${BUILDKITE_BUILD} jobs)
string(JSON BUILDKITE_JOBS_COUNT LENGTH ${BUILDKITE_JOBS})

if(NOT BUILDKITE_JOBS_COUNT GREATER 0)
  message(FATAL_ERROR "No jobs found: ${BUILDKITE_BUILD_URL}")
  return()
endif()

set(BUILDKITE_JOBS_FAILED)
set(BUILDKITE_JOBS_NOT_FOUND)
set(BUILDKITE_JOBS_NO_ARTIFACTS)
set(BUILDKITE_JOBS_NO_MATCH)
set(BUILDKITE_JOBS_MATCH)

math(EXPR BUILDKITE_JOBS_MAX_INDEX "${BUILDKITE_JOBS_COUNT} - 1")
foreach(i RANGE ${BUILDKITE_JOBS_MAX_INDEX})
  string(JSON BUILDKITE_JOB GET ${BUILDKITE_JOBS} ${i})
  string(JSON BUILDKITE_JOB_ID GET ${BUILDKITE_JOB} id)
  string(JSON BUILDKITE_JOB_PASSED GET ${BUILDKITE_JOB} passed)
  string(JSON BUILDKITE_JOB_GROUP_ID GET ${BUILDKITE_JOB} group_uuid)
  string(JSON BUILDKITE_JOB_GROUP_KEY GET ${BUILDKITE_JOB} group_identifier)
  string(JSON BUILDKITE_JOB_NAME GET ${BUILDKITE_JOB} step_key)
  if(NOT BUILDKITE_JOB_NAME)
    string(JSON BUILDKITE_JOB_NAME GET ${BUILDKITE_JOB} name)
  endif()

  if(NOT BUILDKITE_JOB_PASSED)
    list(APPEND BUILDKITE_JOBS_FAILED ${BUILDKITE_JOB_NAME})
    continue()
  endif()

  if(NOT (BUILDKITE_GROUP_ID AND BUILDKITE_GROUP_ID STREQUAL BUILDKITE_JOB_GROUP_ID) AND
     NOT (BUILDKITE_GROUP_KEY AND BUILDKITE_GROUP_KEY STREQUAL BUILDKITE_JOB_GROUP_KEY))
    list(APPEND BUILDKITE_JOBS_NO_MATCH ${BUILDKITE_JOB_NAME})
    continue()
  endif()

  set(BUILDKITE_ARTIFACTS_URL https://buildkite.com/organizations/${BUILDKITE_ORGANIZATION_SLUG}/pipelines/${BUILDKITE_PIPELINE_SLUG}/builds/${BUILDKITE_BUILD_UUID}/jobs/${BUILDKITE_JOB_ID}/artifacts)
  set(BUILDKITE_ARTIFACTS_PATH ${BUILDKITE_BUILD_PATH}/artifacts/${BUILDKITE_JOB_ID}.json)

  file(
    DOWNLOAD ${BUILDKITE_ARTIFACTS_URL}
    HTTPHEADER "Accept: application/json"
    TIMEOUT 15
    STATUS BUILDKITE_ARTIFACTS_STATUS
    ${BUILDKITE_ARTIFACTS_PATH}
  )

  if(NOT BUILDKITE_ARTIFACTS_STATUS EQUAL 0)
    list(APPEND BUILDKITE_JOBS_NOT_FOUND ${BUILDKITE_JOB_NAME})
    continue()
  endif()
  
  file(READ ${BUILDKITE_ARTIFACTS_PATH} BUILDKITE_ARTIFACTS)
  string(JSON BUILDKITE_ARTIFACTS_LENGTH LENGTH ${BUILDKITE_ARTIFACTS})
  if(NOT BUILDKITE_ARTIFACTS_LENGTH GREATER 0)
    list(APPEND BUILDKITE_JOBS_NO_ARTIFACTS ${BUILDKITE_JOB_NAME})
    continue()
  endif()

  math(EXPR BUILDKITE_ARTIFACTS_MAX_INDEX "${BUILDKITE_ARTIFACTS_LENGTH} - 1")
  foreach(i RANGE 0 ${BUILDKITE_ARTIFACTS_MAX_INDEX})
    string(JSON BUILDKITE_ARTIFACT GET ${BUILDKITE_ARTIFACTS} ${i})
    string(JSON BUILDKITE_ARTIFACT_ID GET ${BUILDKITE_ARTIFACT} id)
    string(JSON BUILDKITE_ARTIFACT_PATH GET ${BUILDKITE_ARTIFACT} path)

    if(NOT BUILDKITE_ARTIFACT_PATH MATCHES "\\.(o|a|lib|zip|tar|gz)")
      continue()
    endif()

    if(BUILDKITE)
      if(BUILDKITE_ARTIFACT_PATH STREQUAL "libbun-profile.a")
        set(BUILDKITE_ARTIFACT_PATH libbun-profile.a.gz)
      elseif(BUILDKITE_ARTIFACT_PATH STREQUAL "libbun-asan.a")
        set(BUILDKITE_ARTIFACT_PATH libbun-asan.a.gz)
      endif()
      set(BUILDKITE_DOWNLOAD_COMMAND buildkite-agent artifact download ${BUILDKITE_ARTIFACT_PATH} . --build ${BUILDKITE_BUILD_UUID} --step ${BUILDKITE_JOB_ID})
    else()
      set(BUILDKITE_DOWNLOAD_COMMAND curl -L -o ${BUILDKITE_ARTIFACT_PATH} ${BUILDKITE_ARTIFACTS_URL}/${BUILDKITE_ARTIFACT_ID})
    endif()

    add_custom_command(
      COMMENT
        "Downloading ${BUILDKITE_ARTIFACT_PATH}"
      VERBATIM COMMAND
        ${BUILDKITE_DOWNLOAD_COMMAND}
      WORKING_DIRECTORY
        ${BUILD_PATH}
      OUTPUT
        ${BUILD_PATH}/${BUILDKITE_ARTIFACT_PATH}
    )
    if(BUILDKITE_ARTIFACT_PATH STREQUAL "libbun-profile.a.gz")
      add_custom_command(
        COMMENT
          "Unpacking libbun-profile.a.gz"
        VERBATIM COMMAND
          gunzip libbun-profile.a.gz
        WORKING_DIRECTORY
          ${BUILD_PATH}
        OUTPUT
          ${BUILD_PATH}/libbun-profile.a
        DEPENDS
          ${BUILD_PATH}/libbun-profile.a.gz
      )
    elseif(BUILDKITE_ARTIFACT_PATH STREQUAL "libbun-asan.a.gz")
      add_custom_command(
        COMMENT
          "Unpacking libbun-asan.a.gz"
        VERBATIM COMMAND
          gunzip libbun-asan.a.gz
        WORKING_DIRECTORY
          ${BUILD_PATH}
        OUTPUT
          ${BUILD_PATH}/libbun-asan.a
        DEPENDS
          ${BUILD_PATH}/libbun-asan.a.gz
      )
    endif()
  endforeach()

  list(APPEND BUILDKITE_JOBS_MATCH ${BUILDKITE_JOB_NAME})
endforeach()

if(BUILDKITE_JOBS_FAILED)
  list(SORT BUILDKITE_JOBS_FAILED COMPARE STRING)
  list(JOIN BUILDKITE_JOBS_FAILED " " BUILDKITE_JOBS_FAILED)
  message(WARNING "The following jobs were found, but failed: ${BUILDKITE_JOBS_FAILED}")
endif()

if(BUILDKITE_JOBS_NOT_FOUND)
  list(SORT BUILDKITE_JOBS_NOT_FOUND COMPARE STRING)
  list(JOIN BUILDKITE_JOBS_NOT_FOUND " " BUILDKITE_JOBS_NOT_FOUND)
  message(WARNING "The following jobs were found, but could not fetch their data: ${BUILDKITE_JOBS_NOT_FOUND}")
endif()

if(BUILDKITE_JOBS_NO_MATCH)
  list(SORT BUILDKITE_JOBS_NO_MATCH COMPARE STRING)
  list(JOIN BUILDKITE_JOBS_NO_MATCH " " BUILDKITE_JOBS_NO_MATCH)
  message(WARNING "The following jobs were found, but did not match the group ID: ${BUILDKITE_JOBS_NO_MATCH}")
endif()

if(BUILDKITE_JOBS_NO_ARTIFACTS)
  list(SORT BUILDKITE_JOBS_NO_ARTIFACTS COMPARE STRING)
  list(JOIN BUILDKITE_JOBS_NO_ARTIFACTS " " BUILDKITE_JOBS_NO_ARTIFACTS)
  message(WARNING "The following jobs were found, but had no artifacts: ${BUILDKITE_JOBS_NO_ARTIFACTS}")
endif()

if(BUILDKITE_JOBS_MATCH)
  list(SORT BUILDKITE_JOBS_MATCH COMPARE STRING)
  list(JOIN BUILDKITE_JOBS_MATCH " " BUILDKITE_JOBS_MATCH)
  message(STATUS "The following jobs were found, and matched the group ID: ${BUILDKITE_JOBS_MATCH}")
endif()

if(NOT BUILDKITE_JOBS_FAILED AND NOT BUILDKITE_JOBS_NOT_FOUND AND NOT BUILDKITE_JOBS_NO_MATCH AND NOT BUILDKITE_JOBS_NO_ARTIFACTS AND NOT BUILDKITE_JOBS_MATCH)
  message(FATAL_ERROR "Something went wrong with Buildkite?")
endif()
