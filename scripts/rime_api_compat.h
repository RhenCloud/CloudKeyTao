#ifndef CLOUDKEYTAO_RIME_API_COMPAT_H
#define CLOUDKEYTAO_RIME_API_COMPAT_H

#include <cstddef>
#include <cstdint>

using Bool = int;
constexpr Bool False = 0;
constexpr Bool True = 1;
using RimeSessionId = uintptr_t;

#define RIME_STRUCT(Type, var) Type var{}; var.data_size = sizeof(Type) - sizeof(var.data_size)

struct RimeTraits {
  int data_size;
  const char* shared_data_dir;
  const char* user_data_dir;
  const char* distribution_name;
  const char* distribution_code_name;
  const char* distribution_version;
  const char* app_name;
  const char** modules;
  int min_log_level;
  const char* log_dir;
  const char* prebuilt_data_dir;
  const char* staging_dir;
};

struct RimeCandidate {
  char* text;
  char* comment;
  void* reserved;
};

struct RimeMenu {
  int page_size;
  int page_no;
  Bool is_last_page;
  int highlighted_candidate_index;
  int num_candidates;
  RimeCandidate* candidates;
  char* select_keys;
};

struct RimeComposition {
  int length;
  int cursor_pos;
  int sel_start;
  int sel_end;
  char* preedit;
};

struct RimeContext {
  int data_size;
  RimeComposition composition;
  RimeMenu menu;
  char* commit_text_preview;
  char** select_labels;
};

struct RimeApi {
  void (*initialize)(RimeTraits*);
  void (*finalize)(void);
  Bool (*start_maintenance)(Bool);
  void (*join_maintenance_thread)(void);
  RimeSessionId (*create_session)(void);
  Bool (*destroy_session)(RimeSessionId);
  Bool (*process_key)(RimeSessionId, int, int);
  void (*clear_composition)(RimeSessionId);
  Bool (*get_context)(RimeSessionId, RimeContext*);
  Bool (*free_context)(RimeContext*);
  Bool (*select_schema)(RimeSessionId, const char*);
};

extern "C" RimeApi* rime_get_api(void);

#endif
