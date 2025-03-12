require "records_cache/cache"
require "records_cache/has_many_association"

module RecordsCache
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
        records_cache = Cache.new(
          self,
          { scope_modifier:, handle_updates:, expiration_delay:, thread_safe:, after_load: }
        )

        define_singleton_method :records_cache do
          records_cache
        end

        after_commit -> { self.class.records_cache.reset }

        # wait until cache is populated on at startup synchronously
        records_cache.handle_reload if Rake.application.top_level_tasks.empty?
      end

      def cache_belongs_to_association(association_name)
        cache_association(association_name) do |object, assoc|
          assoc.klass.records_cache.by_id(object.send(assoc.reflection.foreign_key))
        end
      end

      def cache_has_many_association(association_name)
        cache_association(association_name) do |object, assoc|
          reflect = assoc.reflection
          p_key = object.send(reflect.association_primary_key)
          cache = assoc.klass.records_cache
          records = cache.thread_unsafe_select(
            group_key: :sprint_id,
            group_value: object.sprint_id
          ) do |record|
            record.send(reflect.foreign_key) == p_key
          end
          HasManyAssociation.new(
            records.map { |record| cache.result_record(record) },
            object,
            association_name
          )
        end
      end

      def cache_has_one_association(association_name)
        cache_association(association_name) do |object, assoc|
          reflect = assoc.reflection
          p_key = object.send(reflect.association_primary_key)
          assoc.klass.records_cache.thread_unsafe_find(
            group_key: :sprint_id,
            group_value: object.sprint_id
          ) do |record|
            record.send(reflect.foreign_key) == p_key
          end
        end
      end

      private

      def cache_association(association_name, &get_value)
        alias_method "original_#{association_name}", association_name

        define_method association_name do |**args|
          assoc = association(association_name)
          if assoc.loaded? || args.present? || new_record?
            return send("original_#{association_name}", **args)
          end

          cache_name = "@#{association_name}_associations_record_cache"
          instance_variable_set(cache_name, {}) unless instance_variable_defined?(cache_name)
          cache = instance_variable_get(cache_name)
          return cache[association_name] if cache.key?(association_name)

          cache[association_name] = get_value.call(self, assoc)
        end
      end
    end
  end
end