#if __has_include(<rime_api.h>)
#include <rime_api.h>
#else
#include "rime_api_compat.h"
#endif

#include <cstdio>

static bool has_candidates(RimeApi* api, RimeSessionId session,
                           const char* input, const char* label) {
  api->clear_composition(session);
  for (const unsigned char* p = reinterpret_cast<const unsigned char*>(input); *p;
       ++p) {
    if (!api->process_key(session, *p, 0)) {
      std::fprintf(stderr, "[runtime] %s: key 0x%02x was not consumed\n", label,
                   *p);
      return false;
    }
  }

  RIME_STRUCT(RimeContext, context);
  if (!api->get_context(session, &context)) {
    std::fprintf(stderr, "[runtime] %s: get_context failed\n", label);
    return false;
  }
  const bool ok = context.menu.num_candidates > 0;
  if (!ok) {
    std::fprintf(stderr, "[runtime] %s: no candidates for '%s'\n", label, input);
  } else {
    std::printf("[runtime] %-12s %d candidate(s), first: %s\n", label,
                context.menu.num_candidates,
                context.menu.candidates[0].text);
  }
  api->free_context(&context);
  return ok;
}

int main(int argc, char** argv) {
  if (argc != 3) {
    std::fprintf(stderr, "usage: runtime-test <user_data_dir> <shared_data_dir>\n");
    return 2;
  }

  RimeApi* api = rime_get_api();
  if (!api) {
    std::fprintf(stderr, "[runtime] rime_get_api failed\n");
    return 3;
  }

  RIME_STRUCT(RimeTraits, traits);
  traits.user_data_dir = argv[1];
  traits.shared_data_dir = argv[2];
  traits.app_name = "cloudkeytao-runtime-test";
  traits.distribution_name = "CloudKeyTao";
  traits.distribution_code_name = "cloudkeytao";
  traits.distribution_version = "test";
  traits.log_dir = "";
  api->initialize(&traits);
  api->start_maintenance(True);
  api->join_maintenance_thread();

  RimeSessionId session = api->create_session();
  if (!session || !api->select_schema(session, "cloudkeytao")) {
    std::fprintf(stderr, "[runtime] unable to select cloudkeytao\n");
    api->finalize();
    return 4;
  }

  bool ok = true;
  ok = has_candidates(api, session, "dz", "normal") && ok;
  ok = has_candidates(api, session, "`dao", "pinyin") && ok;
  ok = has_candidates(api, session, "`hr", "liangfen") && ok;
  ok = has_candidates(api, session, "`wwx", "gbk") && ok;
  ok = has_candidates(api, session, "/rq", "quick-text") && ok;

  api->destroy_session(session);
  api->finalize();
  return ok ? 0 : 1;
}
