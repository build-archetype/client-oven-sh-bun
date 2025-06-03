optionx(BUILDKITE_CACHE BOOL "If the build can use Buildkite caches, even if not running in Buildkite" DEFAULT ${BUILDKITE})

if(NOT BUILDKITE_CACHE OR NOT BUN_LINK_ONLY)
  return()
endif()

# Add timing function
function(get_timestamp VAR)
  string(TIMESTAMP ${VAR} "%Y-%m-%d %H:%M:%S")
  set(${VAR} ${${VAR}} PARENT_SCOPE)
endfunction()

# Add build environment logging
message(STATUS "=== Build Environment ===")
message(STATUS "OS: ${OS}")
message(STATUS "Architecture: ${ARCH}")
message(STATUS "Build Type: ${CMAKE_BUILD_TYPE}")
message(STATUS "Build Path: ${BUILD_PATH}")
message(STATUS "CMake Version: ${CMAKE_VERSION}")
message(STATUS "=======================")

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

if(NOT BUILDKITE_BUILD_ID)
  # TODO: find the latest build on the main branch that passed
  return()
endif()

setx(BUILDKITE_BUILD_URL https://buildkite.com/${BUILDKITE_ORGANIZATION_SLUG}/${BUILDKITE_PIPELINE_SLUG}/builds/${BUILDKITE_BUILD_ID})
setx(BUILDKITE_BUILD_PATH ${BUILDKITE_BUILDS_PATH}/builds/${BUILDKITE_BUILD_ID})

# Log request details with timing
get_timestamp(START_TIME)
message(STATUS "Making request to Buildkite API:")
message(STATUS "Start Time: ${START_TIME}")
message(STATUS "URL: ${BUILDKITE_BUILD_URL}")
message(STATUS "Headers: Accept: application/json")
message(STATUS "Output path: ${BUILDKITE_BUILD_PATH}/build.json")

file(
  DOWNLOAD ${BUILDKITE_BUILD_URL}
  HTTPHEADER "Accept: application/json"
  TIMEOUT 15
  STATUS BUILDKITE_BUILD_STATUS
  ${BUILDKITE_BUILD_PATH}/build.json
)

get_timestamp(END_TIME)
message(STATUS "End Time: ${END_TIME}")

if(NOT BUILDKITE_BUILD_STATUS EQUAL 0)
  message(FATAL_ERROR "No build found: ${BUILDKITE_BUILD_STATUS} ${BUILDKITE_BUILD_URL}")
  return()
endif()

# Add debugging information with JSON validation
message(STATUS "Buildkite API Response Status: ${BUILDKITE_BUILD_STATUS}")
file(READ ${BUILDKITE_BUILD_PATH}/build.json BUILDKITE_BUILD)

# Validate JSON structure
if(NOT BUILDKITE_BUILD MATCHES ".*\"id\".*")
  message(FATAL_ERROR "Invalid build.json: Missing 'id' field")
endif()

if(NOT BUILDKITE_BUILD MATCHES ".*\"jobs\".*")
  message(FATAL_ERROR "Invalid build.json: Missing 'jobs' field")
endif()

message(STATUS "Buildkite API Response Content: ${BUILDKITE_BUILD}")
message(STATUS "Content length: ${BUILDKITE_BUILD_LENGTH} bytes")

string(JSON BUILDKITE_BUILD_UUID GET ${BUILDKITE_BUILD} id)
string(JSON BUILDKITE_JOBS GET ${BUILDKITE_BUILD} jobs)
string(JSON BUILDKITE_JOBS_COUNT LENGTH ${BUILDKITE_JOBS})

if(NOT BUILDKITE_JOBS_COUNT GREATER 0)
  message(FATAL_ERROR "No jobs found: ${BUILDKITE_BUILD_URL}")
  return()
endif()

# Initialize job tracking with timing
get_timestamp(JOBS_START_TIME)
message(STATUS "=== Processing Jobs ===")
message(STATUS "Start Time: ${JOBS_START_TIME}")
message(STATUS "Total Jobs: ${BUILDKITE_JOBS_COUNT}")

set(BUILDKITE_JOBS_FAILED)
set(BUILDKITE_JOBS_NOT_FOUND)
set(BUILDKITE_JOBS_NO_ARTIFACTS)
set(BUILDKITE_JOBS_NO_MATCH)
set(BUILDKITE_JOBS_MATCH)

math(EXPR BUILDKITE_JOBS_MAX_INDEX "${BUILDKITE_JOBS_COUNT} - 1")
foreach(i RANGE ${BUILDKITE_JOBS_MAX_INDEX})
  get_timestamp(JOB_START_TIME)
  message(STATUS "Processing Job ${i}/${BUILDKITE_JOBS_MAX_INDEX} at ${JOB_START_TIME}")
  
  # Add debug logging for the jobs array
  message(STATUS "Raw jobs array: ${BUILDKITE_JOBS}")
  
  string(JSON BUILDKITE_JOB GET ${BUILDKITE_JOBS} ${i})
  message(STATUS "Raw job data for index ${i}: ${BUILDKITE_JOB}")
  
  string(JSON BUILDKITE_JOB_ID GET ${BUILDKITE_JOB} id)
  string(JSON BUILDKITE_JOB_PASSED GET ${BUILDKITE_JOB} passed)
  string(JSON BUILDKITE_JOB_GROUP_ID GET ${BUILDKITE_JOB} group_uuid)
  string(JSON BUILDKITE_JOB_GROUP_KEY GET ${BUILDKITE_JOB} group_identifier)
  string(JSON BUILDKITE_JOB_NAME GET ${BUILDKITE_JOB} step_key)
  if(NOT BUILDKITE_JOB_NAME)
    string(JSON BUILDKITE_JOB_NAME GET ${BUILDKITE_JOB} name)
  endif()

  message(STATUS "Job Details:")
  message(STATUS "  ID: ${BUILDKITE_JOB_ID}")
  message(STATUS "  Name: ${BUILDKITE_JOB_NAME}")
  message(STATUS "  Passed: ${BUILDKITE_JOB_PASSED}")
  message(STATUS "  Group ID: ${BUILDKITE_JOB_GROUP_ID}")
  message(STATUS "  Group Key: ${BUILDKITE_JOB_GROUP_KEY}")

  if(NOT BUILDKITE_JOB_PASSED)
    list(APPEND BUILDKITE_JOBS_FAILED ${BUILDKITE_JOB_NAME})
    message(STATUS "  Status: Failed")
    continue()
  endif()

  if(NOT (BUILDKITE_GROUP_ID AND BUILDKITE_GROUP_ID STREQUAL BUILDKITE_JOB_GROUP_ID) AND
     NOT (BUILDKITE_GROUP_KEY AND BUILDKITE_GROUP_KEY STREQUAL BUILDKITE_JOB_GROUP_KEY))
    list(APPEND BUILDKITE_JOBS_NO_MATCH ${BUILDKITE_JOB_NAME})
    message(STATUS "  Status: No Group Match")
    continue()
  endif()

  set(BUILDKITE_ARTIFACTS_URL https://buildkite.com/organizations/${BUILDKITE_ORGANIZATION_SLUG}/pipelines/${BUILDKITE_PIPELINE_SLUG}/builds/${BUILDKITE_BUILD_UUID}/jobs/${BUILDKITE_JOB_ID}/artifacts)
  set(BUILDKITE_ARTIFACTS_PATH ${BUILDKITE_BUILD_PATH}/artifacts/${BUILDKITE_JOB_ID}.json)

  message(STATUS "  Fetching artifacts from: ${BUILDKITE_ARTIFACTS_URL}")
  get_timestamp(ARTIFACT_START_TIME)
  
  file(
    DOWNLOAD ${BUILDKITE_ARTIFACTS_URL}
    HTTPHEADER "Accept: application/json"
    TIMEOUT 15
    STATUS BUILDKITE_ARTIFACTS_STATUS
    ${BUILDKITE_ARTIFACTS_PATH}
  )

  get_timestamp(ARTIFACT_END_TIME)
  message(STATUS "  Artifact fetch completed at ${ARTIFACT_END_TIME}")

  if(NOT BUILDKITE_ARTIFACTS_STATUS EQUAL 0)
    list(APPEND BUILDKITE_JOBS_NOT_FOUND ${BUILDKITE_JOB_NAME})
    message(STATUS "  Status: Artifacts Not Found")
    continue()
  endif()
  
  file(READ ${BUILDKITE_ARTIFACTS_PATH} BUILDKITE_ARTIFACTS)
  string(JSON BUILDKITE_ARTIFACTS_LENGTH LENGTH ${BUILDKITE_ARTIFACTS})
  message(STATUS "  Found ${BUILDKITE_ARTIFACTS_LENGTH} artifacts")
  
  if(NOT BUILDKITE_ARTIFACTS_LENGTH GREATER 0)
    list(APPEND BUILDKITE_JOBS_NO_ARTIFACTS ${BUILDKITE_JOB_NAME})
    message(STATUS "  Status: No Artifacts")
    continue()
  endif()

  math(EXPR BUILDKITE_ARTIFACTS_MAX_INDEX "${BUILDKITE_ARTIFACTS_LENGTH} - 1")
  foreach(i RANGE 0 ${BUILDKITE_ARTIFACTS_MAX_INDEX})
    string(JSON BUILDKITE_ARTIFACT GET ${BUILDKITE_ARTIFACTS} ${i})
    string(JSON BUILDKITE_ARTIFACT_ID GET ${BUILDKITE_ARTIFACT} id)
    string(JSON BUILDKITE_ARTIFACT_PATH GET ${BUILDKITE_ARTIFACT} path)
    string(JSON BUILDKITE_ARTIFACT_SIZE GET ${BUILDKITE_ARTIFACT} size)

    message(STATUS "  Processing artifact:")
    message(STATUS "    Path: ${BUILDKITE_ARTIFACT_PATH}")
    message(STATUS "    Size: ${BUILDKITE_ARTIFACT_SIZE} bytes")

    if(NOT BUILDKITE_ARTIFACT_PATH MATCHES "\\.(o|a|lib|zip|tar|gz)")
      message(STATUS "    Status: Skipped (not a build artifact)")
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

    get_timestamp(DOWNLOAD_START_TIME)
    message(STATUS "    Download started at ${DOWNLOAD_START_TIME}")

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

    get_timestamp(DOWNLOAD_END_TIME)
    message(STATUS "    Download completed at ${DOWNLOAD_END_TIME}")

    if(BUILDKITE_ARTIFACT_PATH STREQUAL "libbun-profile.a.gz")
      get_timestamp(UNPACK_START_TIME)
      message(STATUS "    Unpacking started at ${UNPACK_START_TIME}")
      
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
      
      get_timestamp(UNPACK_END_TIME)
      message(STATUS "    Unpacking completed at ${UNPACK_END_TIME}")
    elseif(BUILDKITE_ARTIFACT_PATH STREQUAL "libbun-asan.a.gz")
      get_timestamp(UNPACK_START_TIME)
      message(STATUS "    Unpacking started at ${UNPACK_START_TIME}")
      
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
      
      get_timestamp(UNPACK_END_TIME)
      message(STATUS "    Unpacking completed at ${UNPACK_END_TIME}")
    endif()
  endforeach()

  list(APPEND BUILDKITE_JOBS_MATCH ${BUILDKITE_JOB_NAME})
  get_timestamp(JOB_END_TIME)
  message(STATUS "Job ${i} completed at ${JOB_END_TIME}")
endforeach()

get_timestamp(JOBS_END_TIME)
message(STATUS "All jobs processed at ${JOBS_END_TIME}")
message(STATUS "=====================")

# Summary of job statuses
message(STATUS "=== Build Summary ===")
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

get_timestamp(FINAL_TIME)
message(STATUS "Build process completed at ${FINAL_TIME}")
message(STATUS "===================")
