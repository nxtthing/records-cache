`gem "records_cache", github: "nxtthing/records-cache"`

```ruby
class ApplicationRecord < ActiveRecord::Base
  include RecordsCache::Concern
end

class ApplicationController < ActionController::Base
  before_action -> { RecordsCache.handle_reloads(async: true) }
end

class ApplicationJob < ActiveJob::Base
  before_perform -> { RecordsCache.handle_reloads(async: false) }
end


class PropertyType < ApplicationRecord
  cache_records handle_updates: true, expiration_delay: 30.minutes
end


class Property < ApplicationRecord
  belongs_to :property_type # , inverse_of: :properties # memory leak fix
  cache_belongs_to_association :property_type
end

Sprint.records_cache.by_id(17)

PropertyType.records_cache.find { |property_type| ... }

```
