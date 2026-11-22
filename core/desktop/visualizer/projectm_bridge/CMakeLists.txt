cmake_minimum_required(VERSION 3.15)
project(projectm_bridge LANGUAGES C CXX)

option(AURADSP_BUILD_PROJECTM_BRIDGE
       "Build the projectM bridge when an external libprojectM is available"
       OFF)

if(NOT AURADSP_BUILD_PROJECTM_BRIDGE)
    message(STATUS "projectM bridge disabled (set AURADSP_BUILD_PROJECTM_BRIDGE=ON to enable)")
    return()
endif()

find_library(AURADSP_PROJECTM_LIBRARY
    NAMES projectM-4 projectM-4d projectM
    REQUIRED)
find_package(OpenGL REQUIRED)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(projectm_bridge SHARED
    projectm_bridge.cpp
)

target_include_directories(projectm_bridge PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../vendor/libprojectm/include
)

target_link_libraries(projectm_bridge PRIVATE
    "${AURADSP_PROJECTM_LIBRARY}"
    OpenGL::GL
)

target_compile_definitions(projectm_bridge PRIVATE projectM_EXPORTS)

target_compile_options(projectm_bridge PRIVATE
    $<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-fvisibility=default>
)

set_target_properties(projectm_bridge PROPERTIES
    OUTPUT_NAME "auradsp_projectm_bridge"
    PREFIX ""
)
