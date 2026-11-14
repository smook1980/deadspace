# frozen_string_literal: true

require "optparse"

module Deadspace
  # `deadspace [options] [RAILS_ROOT]`. Returns a process exit status instead of exiting, so it can be tested.
  class CLI
    def initialize(argv, out: $stdout, err: $stderr, env: ENV)
      @argv = argv.dup
      @out = out
      @err = err
      @options = { color: out.tty? && !env.key?("NO_COLOR"), routes: :static, only: nil, paths: [], ignore: [] }
    end

    def run
      parser.parse!(@argv)
      root = File.expand_path(@argv.first || ".")
      return fail!("#{root} does not look like a Rails app (no config/application.rb)") unless rails_app?(root)

      analyze(root)
      0
    rescue OptionParser::ParseError => e
      fail!("#{e.message}\n#{parser.banner}")
    end

    private

    def analyze(root)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      config = Config.load(root, @options[:config])
      ignore = @options[:ignore]
      warn_missing_ignores(root)

      routes = load_routes(root, config, ignore)
      findings, index = Deadspace.analyze(root, config:, routes:, ignore:)
      findings = filter(findings)

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      report = Report.new(findings, index:, routes:, root:, elapsed:)
      unless @options[:quiet]
        report.print_terminal(@out, color: @options[:color], verbose: @options[:verbose], width: @options[:width])
      end
      write_csv(report, findings) if @options[:csv]
    end

    def load_routes(root, config, ignore)
      case @options[:routes]
      when nil then nil
      when :static
        files = Collector.new(root, config, ignore:).files("routes_globs")
        if files.empty?
          @err.puts "No routes files found; skipping route analysis"
          return nil
        end
        RouteParser.new(root, files).parse
      else RouteTable.from_json(@options[:routes])
      end
    end

    def filter(findings)
      if @options[:only]
        wanted = @options[:only] == "unused" ? :unused : :likely_unused
        findings = findings.select { |f| f.confidence == wanted }
      end
      return findings if @options[:paths].empty?

      findings.select { |f| @options[:paths].any? { |p| f.location.path.start_with?(p) } }
    end

    def write_csv(report, findings)
      tests_path = report.write_csv(@options[:csv])
      test_rows = findings.sum { |f| f.tests.size }
      @err.puts "Wrote #{findings.size} findings to #{@options[:csv]} and #{test_rows} removable test blocks " \
                "to #{tests_path}"
    end

    # A typo in a plain --ignore path would otherwise silently ignore nothing.
    def warn_missing_ignores(root)
      @options[:ignore].each do |path|
        next if path.match?(Collector::GLOB_CHARS) || File.exist?(File.join(root, path))

        @err.puts "--ignore #{path}: no such file or directory under #{root}"
      end
    end

    def rails_app?(root) = File.exist?(File.join(root, "config/application.rb"))

    def fail!(message)
      @err.puts message
      1
    end

    def parser
      @parser ||= OptionParser.new do |o|
        o.banner = "Usage: deadspace [options] [RAILS_ROOT (default: .)]"
        o.version = VERSION
        o.on("--csv PATH", "Also write findings to PATH and removable tests to PATH_tests.csv") do |v|
          @options[:csv] = v
        end
        o.on("--config PATH", "YAML overrides (default: RAILS_ROOT/.deadspace.yml if present)") do |v|
          @options[:config] = v
        end
        o.on("--routes-json PATH", "Use routes dumped from the booted app instead of parsing routes.rb") do |v|
          @options[:routes] = v
        end
        o.on("--no-routes", "Skip route analysis (every public controller method counts as an action)") do
          @options[:routes] = nil
        end
        o.on("--ignore PATH", "Skip a file, directory or glob when collecting source files (repeatable),",
             "e.g. --ignore script/one_offs --ignore 'lib/tasks/**/backfill_*.rake'") do |v|
          @options[:ignore] << v
        end
        o.on("--only LEVEL", %w[unused likely], "Only report 'unused' or 'likely' findings") do |v|
          @options[:only] = v
        end
        o.on("--path PREFIX", "Only report findings under this path (repeatable); analysis is still app-wide") do |v|
          @options[:paths] << v
        end
        o.on("--quiet", "No terminal report (use with --csv)") { @options[:quiet] = true }
        o.on("--[no-]color", "Colorize output (default: when stdout is a TTY and NO_COLOR is unset)") do |v|
          @options[:color] = v
        end
        o.on("--width COLUMNS", Integer, "Wrap the report at this width (default: terminal width)") do |v|
          @options[:width] = v
        end
        o.on("--verbose", "Print parse and route warnings") { @options[:verbose] = true }
      end
    end
  end
end
