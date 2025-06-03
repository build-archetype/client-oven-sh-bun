# Add timestamp function
function(get_timestamp VAR)
    string(TIMESTAMP ${VAR} "%Y-%m-%d %H:%M:%S")
    set(${VAR} ${${VAR}} PARENT_SCOPE)
endfunction()

get_timestamp(START_TIME)
message(STATUS "Script started at ${START_TIME}")

# Read the JSON file
message(STATUS "Reading JSON file...")
file(READ ${CMAKE_CURRENT_SOURCE_DIR}/fail.debug.json BUILDKITE_BUILD)
message(STATUS "JSON file read complete")

# Write raw JSON to a debug file
file(WRITE ${CMAKE_CURRENT_SOURCE_DIR}/build.json.debug "${BUILDKITE_BUILD}")

# Use jq to get the jobs array
message(STATUS "Extracting jobs using jq...")
execute_process(
    COMMAND jq -r ".jobs" ${CMAKE_CURRENT_SOURCE_DIR}/fail.debug.json
    OUTPUT_VARIABLE BUILDKITE_JOBS
    RESULT_VARIABLE JQ_RESULT
)

if(NOT JQ_RESULT EQUAL 0)
    message(FATAL_ERROR "Failed to extract jobs using jq")
endif()

# Get job count using jq
execute_process(
    COMMAND jq -r ".jobs | length" ${CMAKE_CURRENT_SOURCE_DIR}/fail.debug.json
    OUTPUT_VARIABLE BUILDKITE_JOBS_COUNT
    RESULT_VARIABLE JQ_RESULT
)

if(NOT JQ_RESULT EQUAL 0)
    message(FATAL_ERROR "Failed to get job count using jq")
endif()

message(STATUS "Found ${BUILDKITE_JOBS_COUNT} jobs")

if(NOT BUILDKITE_JOBS_COUNT GREATER 0)
    message(FATAL_ERROR "No jobs found in JSON")
    return()
endif()

# Initialize job tracking
set(BUILDKITE_JOBS_FAILED)
set(BUILDKITE_JOBS_NOT_FOUND)
set(BUILDKITE_JOBS_NO_ARTIFACTS)
set(BUILDKITE_JOBS_NO_MATCH)
set(BUILDKITE_JOBS_MATCH)

# Process each job
math(EXPR BUILDKITE_JOBS_MAX_INDEX "${BUILDKITE_JOBS_COUNT} - 1")
foreach(i RANGE ${BUILDKITE_JOBS_MAX_INDEX})
    get_timestamp(JOB_START_TIME)
    message(STATUS "Processing job ${i}/${BUILDKITE_JOBS_MAX_INDEX} at ${JOB_START_TIME}")
    
    # Extract job fields using jq
    execute_process(
        COMMAND jq -r ".jobs[${i}] | {id: .id, passed: .passed, group_id: .group_uuid, group_key: .group_identifier, name: (.step_key // .name)}" ${CMAKE_CURRENT_SOURCE_DIR}/fail.debug.json
        OUTPUT_VARIABLE JOB_JSON
        RESULT_VARIABLE JQ_RESULT
    )

    if(NOT JQ_RESULT EQUAL 0)
        message(STATUS "  Warning: Could not extract job ${i} using jq")
        continue()
    endif()

    # Parse the job JSON
    string(JSON BUILDKITE_JOB_ID GET ${JOB_JSON} id)
    string(JSON BUILDKITE_JOB_PASSED GET ${JOB_JSON} passed)
    string(JSON BUILDKITE_JOB_GROUP_ID GET ${JOB_JSON} group_id)
    string(JSON BUILDKITE_JOB_GROUP_KEY GET ${JOB_JSON} group_key)
    string(JSON BUILDKITE_JOB_NAME GET ${JOB_JSON} name)

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

    # For testing, we'll match any job
    list(APPEND BUILDKITE_JOBS_MATCH ${BUILDKITE_JOB_NAME})
    get_timestamp(JOB_END_TIME)
    message(STATUS "Job ${i} completed at ${JOB_END_TIME}")
endforeach()

get_timestamp(END_TIME)
message(STATUS "Script completed at ${END_TIME}")

# Summary of job statuses
message(STATUS "=== Build Summary ===")
if(BUILDKITE_JOBS_FAILED)
    list(SORT BUILDKITE_JOBS_FAILED COMPARE STRING)
    list(JOIN BUILDKITE_JOBS_FAILED " " BUILDKITE_JOBS_FAILED)
    message(WARNING "The following jobs were found, but failed: ${BUILDKITE_JOBS_FAILED}")
endif()

if(BUILDKITE_JOBS_MATCH)
    list(SORT BUILDKITE_JOBS_MATCH COMPARE STRING)
    list(JOIN BUILDKITE_JOBS_MATCH " " BUILDKITE_JOBS_MATCH)
    message(STATUS "The following jobs were found and processed: ${BUILDKITE_JOBS_MATCH}")
endif() 