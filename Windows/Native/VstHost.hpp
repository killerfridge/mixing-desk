#pragma once
#include "Session.hpp"
#include <map>
namespace desk::windows {
class PluginEffect : public InsertProcessor {
public:
  virtual Json parameters() = 0;
  virtual void edit(uint32_t, double) = 0;
  virtual Json snapshot() = 0;
  virtual Json status() const = 0;
  virtual void service() = 0;
};
Json inspectVst(const std::string &path);
Json scanVst();
class PluginRack {
  struct Record {
    std::string signature;
    std::shared_ptr<PluginEffect> effect;
  };
  std::map<std::string, Record> records_;
  std::vector<std::pair<uint64_t, std::shared_ptr<PluginEffect>>> retired_;
  Json catalog_ = Json::array();

public:
  PluginRack();
  Json scan();
#ifdef MDW_PLUGIN_TESTS
  void setTestCatalog(Json catalog) { catalog_ = std::move(catalog); }
#endif
  void prepare(const Json &, uint64_t generation);
  InsertProcessor *processor(const Json &, bool);
  void collect(uint64_t generation);
  void clear() {
    records_.clear();
    retired_.clear();
  }
  Json status();
  Json states();
  Json parameters(const std::string &);
  void edit(const std::string &, uint32_t, double);
  void reload(const std::string &, uint64_t generation);
};
} // namespace desk::windows
