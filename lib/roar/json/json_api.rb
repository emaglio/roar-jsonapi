require 'roar/json'
require 'roar/decorator'
require 'set'

module Roar
  module JSON
    module JSONAPI
      def self.included(base)
        base.class_eval do
          include Roar::JSON
          include Roar::Hypermedia
          extend JSONAPI::Declarative
          extend JSONAPI::ForCollection
          include JSONAPI::Document

          nested :relationships do
          end

          nested :included do
          end
        end
      end

      module ForCollection
        def collection_representer # FIXME: cache.
          single = self # e.g. Song::Representer

          # this basically does Module.new { include Hash::Collection .. }
          nested_builder.(_base: default_nested_class, _features: [Roar::JSON, Roar::Hypermedia], _block: proc do
            collection :to_a, decorator: single # render/parse every item using the single representer.

            # toplevel links are defined here, as in
            # link(:self) { .. }

            def self.meta(_options = {}, &block)
              representable_attrs[:meta_representer] ||= begin
                meta_representer = Class.new(Roar::Decorator)
                meta_representer.send :include, Roar::JSON
                meta_representer
              end
              representable_attrs[:meta_representer].instance_exec(&block)
            end

            def to_hash(options = {})
              hash = super(to_a: options, user_options: options[:user_options]) # [{data: {..}, data: {..}}]
              collection = hash['to_a']
              meta       = render_meta(options)

              document = { data: [] }
              included = []
              collection.each do |single|
                document[:data] << single[:data]
                included += single.delete(:included) || []
              end

              Fragment::Links.(document, Renderer::Links.new.(hash, {}), options)
              Fragment::Included.(document, included, options)
              Fragment::Meta.(document, meta, options)

              document
            end

            private

            def render_meta(options)
              representer = representable_attrs[:meta_representer]
              meta        = representer ? representer.new(represented).to_hash : {}
              meta.merge!(options['meta']) if options['meta']
              meta
            end
          end)
        end

        def for_collection # FIXME: same API as representable. TODO: we could use ::collection_representer! here.
          @collection_representer ||= collection_representer
        end
      end

      # New API for JSON-API representers.
      module Declarative
        def type(name = nil)
          return @type unless name # original name.

          heritage.record(:type, name)
          @type = name.to_s
        end

        def link(name, options = {}, &block)
          return super(name, &block) unless options[:toplevel]
          for_collection.link(name, &block)
        end

        def meta(options = {}, &block)
          return for_collection.meta(name, &block) if options[:toplevel]

          representable_attrs[:meta_representer] ||= begin
            meta_representer = Class.new(Roar::Decorator)
            meta_representer.send :include, Roar::JSON
            meta_representer
          end
          representable_attrs[:meta_representer].instance_exec(&block)
        end

        def has_one(name, options = {}, &block)
          # every nested representer is a full-blown JSONAPI representer.
          dfn = nil

          nested(:included, inherit: true) do
            dfn = property(name, collection: options[:collection]) {
              include Roar::JSON::JSONAPI
              include Roar::JSON
              include Roar::Hypermedia

              instance_exec(&block)

              def from_document(hash)
                hash
              end
            }
          end

          property_representer = Class.new(dfn[:extend].(nil))
          property_representer.class_eval do
            def to_hash(_options)
              super(include: [:type, :id, :links])
            end
          end

          nested(:relationships, inherit: true) do # FIXME: make that a bit nicer readable and document what i'm doing here.
            property(name, options.merge(decorator: property_representer))
          end
        end

        def has_many(name, options = {}, &block)
          has_one(name, options.merge(collection: true), &block)
        end
      end

      module Renderer
        class Links
          def call(res, _options)
            tuples = (res.delete('links') || []).collect { |link| [link['rel'], link['href']] }
            # tuples.to_h
            ::Hash[tuples] # TODO: tuples.to_h when dropping < 2.1.
          end
        end
      end

      module Fragment
        Included = ->(document, included, options) do
          return unless included && included.any?
          return if options[:included] == false

          type_and_id_seen = Set.new

          included = included.select { |object|
            type_and_id_seen.add? [object[:type], object[:id]]
          }

          document[:included] = included
        end

        Links = ->(document, links, _options) do
          document[:links] = links if links.any?
        end

        Meta = ->(document, meta, _options) do
          document[:meta] = meta if meta.any?
        end
      end

      # {:include=>[:id, :title, :author, :included],
      #  :included=>{:include=>[:author], :author=>{:include=>[:email, :id]}}}
      module Options
        # TODO: make sure we don't change original params options.
        Include = ->(options, _decorator) do
          return options unless included = options[:include]
          included << :id # FIXME: changes original options.
          return options unless fields = options[:fields]

          internal_options = {}
          internal_options[:include] = [*included, :included]

          fields = options[:fields] || {}
          internal_options[:included] = { include: fields.keys }
          fields.each do |k, v|
            internal_options[:included][k] = { include: v + [:id] }
          end
          # pp internal_options
          options.merge(internal_options)
        end
      end

      module Document
        def to_hash(options = {})
          res = super(Options::Include.(options, self))

          links = Renderer::Links.new.(res, options)
          meta  = render_meta(options)

          relationships = render_relationships(res)
          included      = render_included(res)

          document = {
            data: data = {
              type: self.class.type,
              id:   res.delete('id').to_s
            }
          }
          data[:attributes]    = res unless res.empty?
          data[:relationships] = relationships if relationships && relationships.any?

          Fragment::Links.(data, links, options)
          Fragment::Included.(document, included, options)
          Fragment::Meta.(document, meta, options)

          document
        end

        def from_hash(hash, _options = {})
          super(from_document(hash))
        end

        private

        def from_document(hash)
          return {} unless hash['data'] # DISCUSS: Is failing silently here a good idea?
          # hash: {"data"=>{"type"=>"articles", "attributes"=>{"title"=>"Ember Hamster"}, "relationships"=>{"author"=>{"data"=>{"type"=>"people", "id"=>"9"}}}}}
          attributes = hash['data']['attributes'] || {}
          attributes['relationships'] = {}

          hash['data'].fetch('relationships', []).each do |rel, fragment|
            attributes['relationships'][rel] = fragment['data'] # DISCUSS: we could use a relationship representer here (but only if needed elsewhere).
          end

          # this is the format the object representer understands.
          attributes # {"title"=>"Ember Hamster", "author"=>{"type"=>"people", "id"=>"9"}}
        end

        # Go through {"album"=>{"title"=>"Hackers"}, "musicians"=>[{"name"=>"Eddie Van Halen"}, ..]} from linked:
        # and wrap every item in an array.
        def render_included(hash)
          return unless compound = hash.delete('included')

          compound.collect { |_name, hash|
            if hash.is_a?(::Hash)
              hash[:data]
            else
              hash.collect { |item| item[:data] }
            end
          }.flatten
        end

        def render_meta(options)
          representer = representable_attrs[:meta_representer]
          meta        = representer ? representer.new(represented).to_hash : {}
          meta.merge!(options['meta']) if options['meta']
          meta
        end

        def render_relationships(res)
          (res['relationships'] || []).each do |name, hash|
            if hash.is_a?(::Hash)
              hash[:links] = hash[:data].delete(:links) if hash[:data].key? :links
            else # hash => [{data: {}}, ..]
              res['relationships'][name] = collection = { data: [] }
              hash.each do |hsh|
                collection[:links] = hsh[:data].delete(:links) if hsh[:data].key? :links
                collection[:data] << hsh[:data]
              end
            end
          end
          res.delete('relationships')
        end
      end
    end
  end
end
