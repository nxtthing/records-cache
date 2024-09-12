require "records_cache/concern"

module RecordsCache
  class << self
    delegate :handle_reloads, to: Cache
  end
end
