require "thread_cache"

class RecordsCache
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

  def by_id(id)
    @by_id ||= to_a.index_by(&:id)
    @by_id[id] ||= @record_class.find_by(id:)
    record = @by_id[id]
    record && result_record(record)
  end

  def by_ids(ids)
    ids.map { |id| by_id(id) }
  end

  def reset
    @records = nil
    @by_id = nil
  end

  def handle_updates?
    @settings[:handle_updates]
  end

  def handle_reload
    @handling_reload = true
    reload if outdated?
    @handling_reload = false
  end

  def reload
    reset
    records_scope = @record_class.all
    records_scope = @settings[:scope_modifier].call(records_scope) if @settings[:scope_modifier]
    @last_reload_at = Time.current if handle_expiration?
    results = records_scope.to_a
    @last_cached_update_at = results.pluck(:updated_at).max if handle_updates?
    @grouped_records = {}
    @records = @settings[:after_load].call(results)
  end

  def outdated_expiration?
    return false unless handle_expiration?
    return true unless @last_reload_at

    @last_reload_at < @settings[:expiration_delay].ago
  end

  def handling_reload?
    @handling_reload
  end

  private

  def result_record(record)
    return record unless @settings[:thread_safe]

    ::ThreadCache.fetch(record.class.name, record.id) do
      dup_record(record)
    end
  end

  def dup_record(record)
    record.class.allocate.init_with_attributes(record.instance_variable_get(:@attributes).dup)
  end

  def thread_unsafe_each(group_key: nil, group_value: nil, &)
    results = (@records || reload)
    if group_key
      @grouped_records[group_key] ||= results.group_by(&group_key)
      results = @grouped_records[group_key][group_value]
    end

    results.each(&)
  end

  def outdated?
    outdated_updates? || outdated_expiration?
  end

  def handle_expiration?
    @settings[:expiration_delay]
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
        !c.handling_reload? && (c.handle_updates? || c.outdated_expiration?)
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

  module Concern
    extend ActiveSupport::Concern

    class_methods do
      def cache_records(
        scope_modifier: nil,
        handle_updates: false,
        expiration_delay: nil,
        thread_safe: true,
        after_load: -> (records) { records }
      )
        records_cache = RecordsCache.new(
          self,
          { scope_modifier:, handle_updates:, expiration_delay:, thread_safe:, after_load: }
        )

        define_singleton_method :records_cache do
          records_cache
        end

        after_commit -> { self.class.records_cache.reset }

        # wait until cache is populated on at startup synchronously
        records_cache.reload if Rake.application.top_level_tasks.empty?
      end

      def cache_belongs_to_association(association)
        cache_association(:belongs_to, association) do |object, assoc|
          assoc.klass.records_cache.by_id(object.send(assoc.reflection.foreign_key))
        end
      end

      def cache_has_many_association(association)
        cache_association(:has_many, association) do |object, assoc|
          reflect = assoc.reflection
          p_key = object.send(refl.association_primary_key)
          assoc.klass.records_cache.thread_unsafe_select(
            group_key: :sprint_id,
            group_value: object.sprint_id
          ) do |record|
            record.send(reflect.foreign_key) == p_key
          end
        end
      end

      private

      def cache_association(association_type, association_name, &get_value)
        alias_method "original_#{association_name}", association_name

        define_method association_name do |**args|
          assoc = association(association_name)
          if assoc.loaded? || args.present?
            return send("original_#{association_name}", **args)
          end

          cache_name = "@#{association_type}_associations_record_cache"
          instance_variable_set(cache_name, {}) unless instance_variable_defined?(cache_name)
          cache = instance_variable_get(cache_name)
          return cache[association_name] if cache.key?(association_name)

          cache[association_name] = get_value.call(object, assoc)
        end
      end
    end
  end
end
