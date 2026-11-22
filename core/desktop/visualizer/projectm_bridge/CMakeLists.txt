cmake_minimum_required(VERSION 3.15)
project(projectm_bridge LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include_directories(
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../vendor/libprojectm/include
)

add_library(projectm_bridge SHARED
    projectm_bridge.cpp
)

set_target_properties(projectm_bridge PROPERTIES
    OUTPUT_NAME "auradsp_projectm_bridge"
    PREFIX ""
)

if (WIN32)
    target_compile_definitions(projectm_bridge PRIVATE PROJECTM_EXPORT=__declspec(dllexport))
else()
    target_compile_options(projectm_bridge PRIVATE -fvisibility=default)
endif()
