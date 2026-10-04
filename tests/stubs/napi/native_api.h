#pragma once

#include <stddef.h>
#include <stdint.h>

typedef struct napi_env__* napi_env;
typedef struct napi_value__* napi_value;
typedef struct napi_callback_info__* napi_callback_info;
typedef struct napi_threadsafe_function__* napi_threadsafe_function;
typedef int napi_status;
typedef int napi_valuetype;
typedef int napi_threadsafe_function_call_mode;
typedef int napi_threadsafe_function_release_mode;

typedef napi_value (*napi_callback)(napi_env, napi_callback_info);
typedef void (*napi_threadsafe_function_call_js)(napi_env, napi_value, void*, void*);
typedef void (*napi_cleanup_hook)(void*);

typedef struct {
  const char* utf8name;
  void* name;
  napi_callback method;
  void* getter;
  void* setter;
  void* value;
  int attributes;
  void* data;
} napi_property_descriptor;

#define napi_ok 0
#define napi_invalid_arg 1
#define napi_generic_failure 9
#define napi_undefined 0
#define napi_function 7
#define napi_default 0
#define napi_tsfn_nonblocking 0
#define napi_tsfn_abort 1
#define NAPI_AUTO_LENGTH ((size_t)-1)

napi_status napi_create_double(napi_env, double, napi_value*);
napi_status napi_set_named_property(napi_env, napi_value, const char*, napi_value);
napi_status napi_create_string_utf8(napi_env, const char*, size_t, napi_value*);
napi_status napi_create_object(napi_env, napi_value*);
napi_status napi_get_undefined(napi_env, napi_value*);
napi_status napi_call_function(napi_env, napi_value, napi_value, size_t, const napi_value*, napi_value*);
napi_status napi_release_threadsafe_function(napi_threadsafe_function, napi_threadsafe_function_release_mode);
napi_status napi_get_cb_info(napi_env, napi_callback_info, size_t*, napi_value*, napi_value*, void**);
napi_status napi_typeof(napi_env, napi_value, napi_valuetype*);
napi_status napi_create_threadsafe_function(napi_env, napi_value, napi_value, napi_value, size_t, size_t, void*, void*, void*, napi_threadsafe_function_call_js, napi_threadsafe_function*);
napi_status napi_get_value_double(napi_env, napi_value, double*);
napi_status napi_get_value_int32(napi_env, napi_value, int32_t*);
napi_status napi_define_properties(napi_env, napi_value, size_t, const napi_property_descriptor*);
napi_status napi_add_env_cleanup_hook(napi_env, napi_cleanup_hook, void*);
napi_status napi_call_threadsafe_function(napi_threadsafe_function, void*, napi_threadsafe_function_call_mode);
