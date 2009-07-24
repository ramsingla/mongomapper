require 'observer'

module MongoMapper
  module EmbeddedDocument
    class NotImplemented < StandardError; end

    def self.included(model)
      model.class_eval do
        extend ClassMethods
        include InstanceMethods

        extend Associations::ClassMethods
        include Associations::InstanceMethods

        include Validatable
        include Serialization
        include RailsCompatibility
      end
    end

    module ClassMethods
      
      def keys
        @keys ||= if parent = parent_model
          parent.keys.dup
        else
          HashWithIndifferentAccess.new
        end
      end

      def key(name, type, options={})
        key = Key.new(name, type, options)
        keys[key.name] = key
        apply_validations_for(key)
        create_indexes_for(key)
        key
      end

      def ensure_index(name_or_array, options={})
        keys_to_index = if name_or_array.is_a?(Array)
          name_or_array.map { |pair| [pair[0], pair[1]] }
        else
          name_or_array
        end

        collection.create_index(keys_to_index, options.delete(:unique))
      end

      def embeddable?
        !self.ancestors.include?(Document)
      end

      def parent_model
        if parent = ancestors[1]
          parent if parent.ancestors.include?(EmbeddedDocument)
        end
      end

    private
      def create_indexes_for(key)
        ensure_index key.name if key.options[:index]
      end

      def apply_validations_for(key)
        attribute = key.name.to_sym

        if key.options[:required]
          validates_presence_of(attribute, :message => "#{attribute}.not.present")
        end
        
        if key.options[:valid]
          validates_true_for attribute, :logic => lambda{  ( valid = send( attribute ).try( :valid? ) ).nil? ? true : valid  }, :message => "#{attribute}.record.invalid"
        end

        if key.options[:unique]
          validates_uniqueness_of(attribute, :message => "#{attribute}.already.taken")
        end

        if key.options[:numeric]
          number_options = key.type == Integer ? { :only_integer => true, :message => "#{attribute}.not.integer" } : { :message => "#{attribute}.not.numeric" }
          validates_numericality_of(attribute, number_options)
        end

        if key.options[:format]
          validates_format_of(attribute, :with => key.options[:format], :message => "#{attribute}.format.invalid")
        end

        if key.options[:length]
          length_options = case key.options[:length]
          when Integer
            {:minimum => 0, :maximum => key.options[:length], :message => "#{attribute}.exceeds.max_length"}
          when Range
            {:within => key.options[:length], :message => "#{attribute}.length.out_of_bounds"}
          when Hash
            key.options[:length].merge!(:message => "#{attribute}.length.invalid")
          end
          validates_length_of(attribute, length_options)
        end
      end
      
      def validates_uniqueness_of(*args)
        add_validations(args, MongoMapper::Validations::ValidatesUniquenessOf)
      end

      def validates_exclusion_of(*args)
        add_validations(args, MongoMapper::Validations::ValidatesExclusionOf)
      end

      def validates_inclusion_of(*args)
        add_validations(args, MongoMapper::Validations::ValidatesInclusionOf)
      end

    end

    module InstanceMethods
      
      #
      # Metadata attributes for fancy magic
      # e.g.  full_key_name  e.g. account.login, name.first
      #       user.account.new? => user.new?
      #       validates_uniqueness_of in embedded document
      #       callbacks in embedded document (TODO)
      #
      attr_reader :_root        # The Mongo::Document which is the root doc
      attr_reader :_parent      # The parent document. For root parent is nil
      attr_reader :_parent_key  # The key name of the embedded document in parent doc
      
      def initialize(attrs={})
        @_root = self.class.include?(MongoMapper::Document) ? self : nil
        @_parent = nil
        @_parent_key = nil
        unless attrs.nil?
          initialize_associations(attrs)
          self.attributes = attrs
        end
      end
      
      def new?
        _root.try(:new?)
      end
      
      def full_key_path(name)
        _parent ? _parent.full_key_path("#{_parent_key}.#{name}") : name
      end

      def attributes=(attrs)
        return if attrs.blank?
        attrs.each_pair do |key_name, value|
          if writer?(key_name)
            write_attribute(key_name, value)
          else
            writer_method ="#{key_name}="
            self.send(writer_method, value) if respond_to?(writer_method)
          end
        end
      end

      def attributes
        self.class.keys.inject(HashWithIndifferentAccess.new) do |attributes, key_hash|
          name, key = key_hash
          value = value_for_key(key)
          attributes[name] = value unless value.nil?
          attributes
        end
      end

      def reader?(name)
        defined_key_names.include?(name.to_s)
      end

      def writer?(name)
        name = name.to_s
        name = name.chop if name.ends_with?('=')
        reader?(name)
      end

      def before_typecast_reader?(name)
        name.to_s.match(/^(.*)_before_typecast$/) && reader?($1)
      end

      def [](name)
        read_attribute(name)
      end

      def []=(name, value)
        write_attribute(name, value)
      end

      def method_missing(method, *args, &block)
        attribute = method.to_s

        if reader?(attribute)
          read_attribute(attribute)
        elsif writer?(attribute)
          write_attribute(attribute.chop, args[0])
        elsif before_typecast_reader?(attribute)
          read_attribute_before_typecast(attribute.gsub(/_before_typecast$/, ''))
        else
          super
        end
      end

      def ==(other)
        other.is_a?(self.class) && attributes == other.attributes
      end

      def inspect
        attributes_as_nice_string = defined_key_names.collect do |name|
          "#{name}: #{read_attribute(name)}"
        end.join(", ")
        "#<#{self.class} #{attributes_as_nice_string}>"
      end

      alias :respond_to_without_attributes? :respond_to?

      def respond_to?(method, include_private=false)
        return true if reader?(method) || writer?(method) || before_typecast_reader?(method)
        super
      end

    private
      def value_for_key(key)
        if key.native?
          read_attribute(key.name)
        else
          embedded_document = read_attribute(key.name)
          embedded_document && embedded_document.attributes
        end
      end

      def read_attribute(name)
        defined_key(name).get(instance_variable_get("@#{name}"))
      end

      def read_attribute_before_typecast(name)
        instance_variable_get("@#{name}_before_typecast")
      end

      def write_attribute(name, value)
        instance_variable_set "@#{name}_before_typecast", value
        key = defined_key(name)
        result = instance_variable_set "@#{name}", key.set(value)
        if key.type.include?(MongoMapper::EmbeddedDocument) && !key.type.include?(MongoMapper::Document)
          attribute_val = read_attribute(name)
          attribute_val.instance_variable_set("@_root",       self._root)
          attribute_val.instance_variable_set("@_parent",     self)
          attribute_val.instance_variable_set("@_parent_key", name)
        end
      end

      def defined_key(name)
        self.class.keys[name]
      end

      def defined_key_names
        self.class.keys.keys
      end

      def only_defined_keys(hash={})
        defined_key_names = defined_key_names()
        hash.delete_if { |k, v| !defined_key_names.include?(k.to_s) }
      end
      
      def embedded_association_attributes
        embedded_attributes = HashWithIndifferentAccess.new
        self.class.associations.each_pair do |name, association|
          
          if association.type == :many && association.klass.embeddable?            
            if documents = instance_variable_get(association.ivar)
              embedded_attributes[name] = documents.collect do |item|
                attributes_hash = item.attributes
                
                item.send(:embedded_association_attributes).each_pair do |association_name, association_value|
                  attributes_hash[association_name] = association_value
                end
                
                attributes_hash
              end
            end
          end
        end
        
        embedded_attributes
      end

      def initialize_associations(attrs={})
        self.class.associations.each_pair do |name, association|
          if collection = attrs.delete(name)
            __send__("#{association.name}=", collection)
          end
        end
      end
    end
  end
end
