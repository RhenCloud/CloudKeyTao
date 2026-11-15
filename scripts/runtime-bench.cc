#if __has_include(<rime_api.h>)
#include <rime_api.h>
#else
#include "rime_api_compat.h"
#endif

#include <cstdio>
#include <cstring>

struct Case {
  const char* label;
  const char* input;
  const char* expected;
};

static int rank_of(RimeApi* api, RimeSessionId session, const Case& test) {
  api->clear_composition(session);
  for (const unsigned char* p = reinterpret_cast<const unsigned char*>(test.input); *p;
       ++p) {
    if (!api->process_key(session, *p, 0)) return -1;
  }

  RIME_STRUCT(RimeContext, context);
  if (!api->get_context(session, &context)) return -1;
  int rank = 0;
  for (int i = 0; i < context.menu.num_candidates; ++i) {
    if (std::strcmp(context.menu.candidates[i].text, test.expected) == 0) {
      rank = i + 1;
      break;
    }
  }
  std::printf("%s\t%s\t%s\t%d\t%d\n", test.label, test.input, test.expected,
              rank, context.menu.num_candidates);
  api->free_context(&context);
  return rank;
}

int main(int argc, char** argv) {
  if (argc != 3) {
    std::fprintf(stderr, "usage: runtime-bench <user_data_dir> <shared_data_dir>\n");
    return 2;
  }

  RimeApi* api = rime_get_api();
  if (!api) return 3;
  RIME_STRUCT(RimeTraits, traits);
  traits.user_data_dir = argv[1];
  traits.shared_data_dir = argv[2];
  traits.app_name = "cloudkeytao-runtime-bench";
  traits.distribution_name = "CloudKeyTao";
  traits.distribution_code_name = "cloudkeytao";
  traits.distribution_version = "bench";
  traits.log_dir = "";
  api->initialize(&traits);
  api->start_maintenance(True);
  api->join_maintenance_thread();
  RimeSessionId session = api->create_session();
  if (!session || !api->select_schema(session, "cloudkeytao")) return 4;

  const Case cases[] = {
      {"normal", "dz", "到"},
      {"pinyin", "`dao", "到"},
      {"liangfen", "`hr", "一"},
      {"gbk", "`wwx", "慰"},
  };
  bool ok = true;
  for (const auto& test : cases) ok = rank_of(api, session, test) > 0 && ok;
  api->destroy_session(session);
  api->finalize();
  return ok ? 0 : 1;
}
