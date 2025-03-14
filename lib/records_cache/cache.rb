require "thread_cache"

module RecordsCache
  class Cache
    include Enumerable

    def initialize(record_class, settings)
      self.class.cached_classes_set << record_class
      @settings = settings
      @record_class = record_class
    end

    def each(&block)
      thread_unsafe_each do |record|
        block.call(result_record(record))
      end
    end

    def thread_unsafe_select(group_key: nil, group_value: nil, &comparator_block)
      result = []
      thread_unsafe_each(group_key:, group_value:) do |record|
        result << result_record(record) if comparator_block.call(record)
      end
      result
    end

    def thread_unsafe_find(group_key: nil, group_value: nil, &comparator_block)
      thread_unsafe_each(group_key:, group_value:) do |record|
        return result_record(record) if comparator_block.call(record)
      end
      nil
    end

    def by_id(id, is_retry: false)
      result = thread_unsafe_find(group_key: :id, group_value: id) { |_record| true }
      return result if result
      return result if is_retry
      return result unless @record_class.exists?(id:)

      # reload and retry in case if record exists in DB but does not exist in cache
      reset
      by_id(id, is_retry: true)
    end

    def by_ids(ids)
      ids.map { |id| by_id(id) }
    end

    def handle_updates?
      @settings[:handle_updates]
    end

    def handle_reload
      reload if outdated?
    end

    def reset
      @records = nil
      @grouped_records = {}
    end

    def reloading?
      @reloading
    end

    def result_record(record)
      return record unless @settings[:thread_safe]

      ::ThreadCache.fetch(record.class.name, record.id) do
        dup_record(record)
      end
    end

    def handle_expiration?
      @settings[:expiration_delay]
    end

    private

    def reload
      @reloading = true
      records_scope = @record_class.all
      records_scope = @settings[:scope_modifier].call(records_scope) if @settings[:scope_modifier]
      results = records_scope.to_a
      @last_reload_at = Time.current if handle_expiration?
      @last_cached_update_at = results.pluck(:updated_at).max if handle_updates?
      results = @settings[:after_load].call(results)
      reset
      @reloading = false
      @records = results
    end

    def dup_record(record)
      record.class.allocate.init_with_attributes(record.instance_variable_get(:@attributes).dup)
    end

    def thread_unsafe_each(group_key: nil, group_value: nil, &)
      records_was = @records
      results = (@records || reload)
      if group_key
        val_was = @grouped_records[group_key]
        val_now = @grouped_records[group_key] ||= results.group_by(&group_key)
        unless @grouped_records[group_key]
          Sentry.capture_message("DEBUG [AY] empty records cache", contexts: {
            cache: {
              results_class: results.class.name,
              results_size: results&.count,
              records_class: @records.class.name,
              records_size: @records&.count,
              records_was_class: records_was.class.name,
              records_was_size: records_was&.count,
              reloading: @reloading
            },
            group: {
              val_was:,
              val_now:
            },
            args: {
              group_key:,
              group_value:
            }
          })
        end
        results = @grouped_records[group_key][group_value] || []
      end

      results.each(&)
    end

    def outdated?
      !@records || outdated_updates? || outdated_expiration?
    end

    def outdated_expiration?
      return false unless handle_expiration?
      return true unless @last_reload_at

      @last_reload_at < @settings[:expiration_delay].ago
    end

    def outdated_updates?
      return false unless handle_updates?
      return true unless @last_cached_update_at

      @record_class.exists?(["updated_at > ?", @last_cached_update_at])
    end

    class << self
      def cached_classes_set
        @cached_classes_set ||= ::Set.new
      end

      def handle_reloads(async: false)
        caches_to_handle_reload = record_caches.select do |c|
          !c.reloading? && (c.handle_updates? || c.handle_expiration?)
        end

        return if caches_to_handle_reload.blank?

        reload_task = -> { caches_to_handle_reload.each(&:handle_reload) }

        return reload_task.call unless async

        Concurrent::Promises.future(&reload_task)
      end

      private

      def record_caches
        cached_classes_set.map(&:records_cache)
      end
    end
  end
end
