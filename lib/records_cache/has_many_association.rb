module RecordsCache
  class HasManyAssociation < Array
    def initialize(result, owner, association_name)
      @owner = owner
      @association_name = association_name
      super(result)
    end

    def build(**)
      @owner.public_send("original_#{@association_name}").build(**)
    end
  end
end
