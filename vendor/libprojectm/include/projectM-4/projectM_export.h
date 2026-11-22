#pragma once

/*
 * Generated-header equivalent for the vendored projectM C API.
 * Keep this file in the clean vendor boundary; do not include source/projectm
 * build output from application targets.
 */
#if defined(PROJECTM_STATIC_DEFINE)
#  define PROJECTM_EXPORT
#elif defined(_WIN32)
#  if defined(projectM_EXPORTS)
#    define PROJECTM_EXPORT __declspec(dllexport)
#  else
#    define PROJECTM_EXPORT __declspec(dllimport)
#  endif
#else
#  define PROJECTM_EXPORT __attribute__((visibility("default")))
#endif

#define PROJECTM_NO_EXPORT
