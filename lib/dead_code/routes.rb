# frozen_string_literal: true

module DeadCode
  # The set of [controller_path, action] pairs an app routes to.
  class RouteTable
    attr_reader :actions, :wildcard_controllers, :warnings, :source
    attr_accessor :dynamic

    def initialize(source)
      @source = source
      @actions = Hash.new { |h, k| h[k] = Set.new }
      @wildcard_controllers = Set.new # every public method is routable (devise_for controllers:)
      @dynamic = false                # a `:controller` / `:action` segment routes to anything
      @warnings = []
    end

    def add(controller, action) = @actions[controller.to_s.delete_prefix("/")] << action.to_s
    def size = @actions.values.sum(&:size)

    # Output of dump_routes.rb run inside the booted app (most accurate, needs a bootable app).
    def self.from_json(path)
      table = new("routes JSON #{path}")
      JSON.parse(File.read(path)).each do |route|
        controller, action = route.values_at("controller", "action")
        if controller.nil? || action.nil?
          table.dynamic = true if route["path"].to_s.match?(/:controller|:action/)
          next
        end
        table.add(controller, action)
      end
      table
    end
  end

  # Statically evaluates the routes DSL (config/routes.rb + `draw` files) with Prism. It covers the
  # Rails 7 mapper surface that produces controller#action pairs: namespace, scope, controller,
  # resources/resource (only/except/controller/module/concerns, member/collection/nested), verb
  # helpers with to:/controller:/action:/"path" => "c#a" and path shorthand, root, concern(s),
  # draw, devise_for/use_doorkeeper `controllers`. Unknown block DSLs are descended into with the
  # same scope, which errs towards "routed" (fewer false "no route" findings).
  class RouteParser
    RESOURCES_ACTIONS = %w[index create new edit show update destroy].freeze
    RESOURCE_ACTIONS = %w[create new edit show update destroy].freeze
    VERBS = %i[get post put patch delete options head match].freeze
    SKIP = %i[mount direct resolve redirect].freeze
    UNKNOWN = Object.new.freeze
    Scope = Struct.new(:mod, :controller, :level, keyword_init: true)

    def initialize(root, files)
      @root = root
      @files = files
      @concerns = {}
    end

    def parse
      table = RouteTable.new("static parse of #{@files.join(", ")}")
      @table = table
      main, draws = @files.partition { |f| f == "config/routes.rb" }
      @draw_files = draws
      (main.empty? ? draws : main).each do |rel|
        walk(Prism.parse_file(File.join(@root, rel)).value, Scope.new(mod: nil, controller: nil, level: nil))
      end
      table
    end

    private

    def walk(node, scope)
      case node
      when nil then nil
      when Prism::CallNode then handle_call(node, scope)
      else node.compact_child_nodes.each { |child| walk(child, scope) }
      end
    end

    def walk_block(call, scope)
      walk(call.block.body, scope) if call.block.is_a?(Prism::BlockNode)
    end

    def handle_call(call, scope)
      args, opts = arguments(call)
      case call.name
      when :namespace
        name = args.first
        mod = opts.key?(:module) ? opts[:module] : name
        inner = scope.dup
        inner.mod = join(scope.mod, mod) unless mod.nil? || mod == UNKNOWN
        inner.level = nil
        walk_block(call, inner)
      when :scope
        inner = scope.dup
        inner.mod = join(scope.mod, opts[:module]) if opts.key?(:module) && opts[:module] && opts[:module] != UNKNOWN
        inner.controller = opts[:controller].to_s if opts[:controller].is_a?(String) || opts[:controller].is_a?(Symbol)
        walk_block(call, inner)
      when :controller
        if call.block && (args.first.is_a?(String) || args.first.is_a?(Symbol))
          walk_block(call, scope.dup.tap { |s| s.controller = args.first.to_s })
        end
      when :resources, :resource
        args.select { |a| a.is_a?(Symbol) || a.is_a?(String) }.each do |resource_name|
          resource(call, resource_name.to_s, opts, scope, plural: call.name == :resources)
        end
      when *VERBS then match(args, opts, scope)
      when :root
        match(["/"], args.first.is_a?(String) ? opts.merge(to: args.first) : opts, scope)
      when :member, :collection, :new
        walk_block(call, scope.dup.tap { |s| s.level = call.name })
      when :concern
        @concerns[args.first] = call.block if call.block.is_a?(Prism::BlockNode)
      when :concerns
        args.flatten.each { |name| apply_concern(name, scope) }
      when :draw
        return walk_block(call, scope) if call.block # Rails.application.routes.draw do ... end

        rel = "config/routes/#{args.first}.rb"
        walk(Prism.parse_file(File.join(@root, rel)).value, scope) if File.exist?(File.join(@root, rel))
      when :devise_for, :controllers
        mapping = call.name == :devise_for ? opts[:controllers] : opts
        (mapping.is_a?(Hash) ? mapping : {}).each_value do |controller|
          next unless controller.is_a?(String) || controller.is_a?(Symbol)

          @table.wildcard_controllers << controller_path(controller.to_s, scope)
        end
        walk_block(call, scope)
      when *SKIP then nil
      else
        walk(call.receiver, scope)
        walk_block(call, scope)
      end
    end

    def resource(call, name, opts, scope, plural:)
      mod = opts.key?(:module) && opts[:module] && opts[:module] != UNKNOWN ? join(scope.mod, opts[:module]) : scope.mod
      controller = opts[:controller]
      controller = (plural ? name : name.pluralize) unless controller.is_a?(String) || controller.is_a?(Symbol)
      path = controller.to_s.start_with?("/") ? controller.to_s.delete_prefix("/") : join(mod, controller.to_s)

      actions = plural ? RESOURCES_ACTIONS : RESOURCE_ACTIONS
      actions &= Array(opts[:only]).map(&:to_s) if opts.key?(:only) && opts[:only] != UNKNOWN
      actions -= Array(opts[:except]).map(&:to_s) if opts.key?(:except) && opts[:except] != UNKNOWN
      actions.each { |a| @table.add(path, a) }

      inner = Scope.new(mod:, controller: "/#{path}", level: plural ? :resources : :resource)
      Array(opts[:concerns]).each { |c| apply_concern(c, inner) }
      walk_block(call, inner)
    end

    def apply_concern(name, scope)
      block = @concerns[name]
      block ? walk(block.body, scope) : @table.warnings << "routes: unknown concern #{name.inspect}"
    end

    # Mirrors ActionDispatch::Routing::Mapper#match / #add_route / Mapping.build.
    def match(args, opts, scope)
      if args.empty? && (pair = opts.find { |k, _| k.is_a?(String) })
        hash_path, target = pair
        opts = opts.except(hash_path)
        case target
        when Symbol then opts = opts.merge(action: target)
        when String then opts = opts.merge(target.include?("#") ? { to: target } : { controller: target })
        else return # Rack app / redirect
        end
        args = [hash_path]
      end
      return if opts.key?(:to) && !opts[:to].is_a?(String) # redirect(...) / Rack endpoint

      args = [nil] if args.empty?
      args.each do |path|
        path = nil if path == UNKNOWN
        @table.dynamic = true if path.is_a?(String) && path.match?(/:controller|:action/)
        controller = opts[:controller].is_a?(String) || opts[:controller].is_a?(Symbol) ? opts[:controller].to_s : nil
        action = opts[:action].is_a?(String) || opts[:action].is_a?(Symbol) ? opts[:action].to_s : nil
        to = opts[:to]
        bare_path = path.delete_suffix("(.:format)") if path.is_a?(String)
        # get "photos/search" => photos#search
        if to.nil? && action.nil? && bare_path&.match?(%r{\A/?[-\w]+/[-\w/]+\z})
          to = bare_path.delete_prefix("/").sub(%r{/([^/]*)\z}, '#\1').tr("-", "_")
        end
        if to&.include?("#")
          to_controller, to_action = to.split("#", 2)
          controller = to_controller unless to_controller.empty?
          action = to_action
        end
        action ||= path.to_s.tr("-", "_") if path.is_a?(Symbol) || (path.is_a?(String) && path.match?(/\A[\w-]+\z/))
        controller ||= scope.controller
        controller_path = controller && controller_path(controller, scope, opts[:module])
        next unless controller_path && action

        @table.add(controller_path, action)
      end
    end

    def controller_path(controller, scope, extra_module = nil)
      return controller.delete_prefix("/") if controller.start_with?("/")

      mod = extra_module.is_a?(String) || extra_module.is_a?(Symbol) ? join(scope.mod, extra_module) : scope.mod
      join(mod, controller)
    end

    def join(*parts) = parts.compact.map(&:to_s).reject(&:empty?).join("/").then { |s| s.empty? ? nil : s }

    def arguments(call)
      nodes = call.arguments&.arguments || []
      opts = {}
      if (last = nodes.last).is_a?(Prism::KeywordHashNode) || last.is_a?(Prism::HashNode)
        opts = literal(last)
        opts = {} unless opts.is_a?(Hash)
        nodes = nodes[0...-1]
      end
      [nodes.map { |n| literal(n) }, opts]
    end

    def literal(node)
      case node
      when Prism::SymbolNode then node.unescaped.to_sym
      when Prism::StringNode then node.unescaped
      when Prism::ArrayNode then node.elements.map { |e| literal(e) }
      when Prism::KeywordHashNode, Prism::HashNode
        node.elements.each_with_object({}) do |assoc, h|
          next unless assoc.is_a?(Prism::AssocNode)

          h[literal(assoc.key)] = literal(assoc.value)
        end
      when Prism::NilNode then nil
      when Prism::TrueNode then true
      when Prism::FalseNode then false
      else UNKNOWN
      end
    end
  end
end
