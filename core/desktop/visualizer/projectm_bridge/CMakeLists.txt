cmake_minimum_required(VERSION 3.15)
project(projectm_bridge LANGUAGES C CXX)

option(AURADSP_BUILD_PROJECTM_BRIDGE
       "Build the projectM bridge when an external libprojectM is available"
       OFF)

if(NOT AURADSP_BUILD_PROJECTM_BRIDGE)
    message(STATUS "projectM bridge disabled (set AURADSP_BUILD_PROJECTM_BRIDGE=ON to enable)")
    return()
endif()

set(AURADSP_PROJECTM_ROOT "" CACHE PATH
    "Root of an installed projectM SDK")
set(AURADSP_PROJECTM_INCLUDE_DIR "" CACHE PATH
    "Directory containing projectM-4 headers")

if(NOT AURADSP_PROJECTM_INCLUDE_DIR)
    if(AURADSP_PROJECTM_ROOT AND EXISTS "${AURADSP_PROJECTM_ROOT}/include/projectM-4/core.h")
        set(AURADSP_PROJECTM_INCLUDE_DIR "${AURADSP_PROJECTM_ROOT}/include")
    else()
        set(AURADSP_PROJECTM_INCLUDE_DIR
            "${CMAKE_CURRENT_SOURCE_DIR}/../../../../vendor/libprojectm/include")
    endif()
endif()

find_library(AURADSP_PROJECTM_LIBRARY
    NAMES projectM-4 projectM-4d projectM
    HINTS
        "${AURADSP_PROJECTM_ROOT}/lib"
        "${AURADSP_PROJECTM_ROOT}/bin"
    REQUIRED)
find_package(OpenGL REQUIRED)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(projectm_bridge SHARED
    projectm_bridge.cpp
)

target_include_directories(projectm_bridge PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    "${AURADSP_PROJECTM_INCLUDE_DIR}"
)

target_link_libraries(projectm_bridge PRIVATE
    "${AURADSP_PROJECTM_LIBRARY}"
    OpenGL::GL
)

if(WIN32)
    # W3: the bridge owns a hidden WGL context (user32 window, gdi32
    # pixel format) on its dedicated render thread.
    target_link_libraries(projectm_bridge PRIVATE user32 gdi32)
endif()

target_compile_options(projectm_bridge PRIVATE
    $<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-fvisibility=default>
)

set_target_properties(projectm_bridge PROPERTIES
    OUTPUT_NAME "auradsp_projectm_bridge"
    PREFIX ""
)
