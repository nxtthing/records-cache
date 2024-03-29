class RecordsCache
  include Enumerable

  def initialize(record_class, settings)
    self.class.cached_classes_set << record_class
    @settings = settings
    @record_class = record_class
  end

  def each(&)
    (@records || reload).each(&)
  end

  def by_id(id)
    @by_id ||= to_a.index_by(&:id)
    @by_id[id] || @record_class.find_by(id:)
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
    records_scope = @record_class.all.to_a
    records_scope = @settings[:scope_modifier].call(records_scope) if @settings[:scope_modifier]
    @last_cached_update_at = records_scope.pluck(:updated_at).max if handle_updates?
    @last_reload_at = Time.current if handle_expiration?
    @records = records_scope.to_a
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
      def cache_records(scope_modifier: nil, handle_updates: false, expiration_delay: nil)
        records_cache = RecordsCache.new(self, { scope_modifier:, handle_updates:, expiration_delay: })

        define_singleton_method :records_cache do
          records_cache
        end

        after_commit -> { self.class.records_cache.reset }

        # wait until cache is populated on at startup synchronously
        records_cache.reload if Rake.application.top_level_tasks.empty?
      end

      def cache_belongs_to_association(association)
        alias_method "original_#{association}", association

        define_method association do |**args|
          return send("original_#{association}", **args) if association(association.to_sym).loaded? || args.present?

          instance_variable = :"@#{association}_cache"
          return instance_variable_get(instance_variable) if instance_variable_defined?(instance_variable)

          cached_value = association(association).klass.records_cache.by_id(send("#{association}_id"))
          instance_variable_set(instance_variable, cached_value)
        end
      end
    end
  end
end
