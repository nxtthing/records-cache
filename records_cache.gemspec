Gem::Specification.new do |s|
  s.name        = "records_cache"
  s.summary     = "RecordsCache"
  s.version     = "0.2.7"
  s.authors     = ["Aliaksandr Yakubenka"]
  s.email       = "alexandr.yakubenko@startdatelabs.com"
  s.files       = ["lib/records_cache.rb"]
  s.license       = "MIT"
  s.add_dependency "activesupport"
  s.add_runtime_dependency "thread_cache"
end
