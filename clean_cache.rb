#!/usr/bin/env ruby
# frozen_string_literal: true

# cleanCache-MacOS
# A Ruby script to clean temporary files and caches on macOS.

require "fileutils"
require "optparse"

module CleanCache
  BOLD  = "\e[1m"
  DIM   = "\e[2m"
  GREEN = "\e[32m"
  RED   = "\e[31m"
  YELLOW = "\e[33m"
  RESET = "\e[0m"

  def self.human_size(bytes)
    units = %w[B KB MB GB TB]
    unit = 0
    size = bytes.to_f
    while size >= 1024 && unit < units.length - 1
      size /= 1024
      unit += 1
    end
    format("%.2f %s", size, units[unit])
  end

  def self.dir_size(path)
    return 0 unless File.exist?(path)

    if File.directory?(path)
      Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH)
        .select { |f| File.file?(f) }
        .sum { |f| File.size(f) rescue 0 }
    else
      File.size(path) rescue 0
    end
  rescue Errno::EPERM, Errno::EACCES
    0
  end

  def self.clean_path(label, path)
    path = File.expand_path(path)
    return unless File.exist?(path)

    size = dir_size(path)
    return if size.zero?

    FileUtils.rm_rf(path)
    puts "  #{GREEN}✓#{RESET} #{label}: #{human_size(size)}"
    size
  rescue Errno::EPERM, Errno::EACCES
    puts "  #{RED}✗#{RESET} #{label}: permission denied (protected by macOS)"
    nil
  end

  def self.run_command(label, command)
    output = `#{command} 2>&1`
    if $?.success?
      puts "  #{GREEN}✓#{RESET} #{label}"
    else
      puts "  #{RED}✗#{RESET} #{label}: #{output.strip}"
    end
  end

  def self.clean_old_device_support
    dir = File.expand_path("~/Library/Developer/Xcode/iOS DeviceSupport")
    return 0 unless File.directory?(dir)

    entries = Dir.children(dir)
      .select { |e| File.directory?(File.join(dir, e)) }
      .map { |e| [e, e.scan(/\A(\d+(?:\.\d+)*)/).flatten.first] }
      .select { |_, v| v }
      .sort_by { |_, v| Gem::Version.new(v) }

    return 0 if entries.size <= 1

    freed = 0
    entries[0..-2].each do |name, _|
      path = File.join(dir, name)
      size = dir_size(path)
      FileUtils.rm_rf(path)
      puts "  #{GREEN}✓#{RESET} Xcode device support (old: #{name}): #{human_size(size)}"
      freed += size
    end
    puts "  Kept latest: #{entries.last.first}"
    freed
  end

  PROJECT_MARKERS = %w[
    package.json Gemfile Rakefile Cargo.toml go.mod build.gradle pom.xml
    composer.json Makefile CMakeLists.txt setup.py pyproject.toml
    requirements.txt Podfile .xcodeproj
  ].freeze

  # Artifact => list of project markers that make it safe to delete
  PROJECT_ARTIFACTS = {
    "node_modules"   => %w[package.json],
    "log"            => %w[Gemfile Rakefile],
    ".pytest_cache"  => %w[setup.py pyproject.toml requirements.txt],
    "__pycache__"    => %w[setup.py pyproject.toml requirements.txt],
    ".sass-cache"    => %w[package.json Gemfile],
    ".parcel-cache"  => %w[package.json],
    ".next/cache"    => %w[package.json],
    ".nuxt"          => %w[package.json],
    ".turbo"         => %w[package.json],
    "coverage"       => %w[package.json Gemfile setup.py pyproject.toml],
    ".angular/cache" => %w[package.json],
  }.freeze

  def self.find_project_roots
    home = Dir.home
    `find "#{home}" -maxdepth 4 -name "#{PROJECT_MARKERS.join('" -o -name "')}" 2>/dev/null`
      .split("\n")
      .reject { |f| f.include?("/Library/") || f.include?("/.Trash/") || f.include?("/node_modules/") }
      .map { |f| File.dirname(f) }
      .uniq
  end

  def self.gitignored?(root, path)
    system("git", "-C", root, "check-ignore", "-q", path, out: File::NULL, err: File::NULL)
  end

  def self.clean_project_artifacts
    home = Dir.home
    freed = 0
    roots = find_project_roots

    roots.each do |root|
      PROJECT_ARTIFACTS.each do |artifact, markers|
        next unless markers.any? { |m| File.exist?(File.join(root, m)) }

        dir = File.join(root, artifact)
        next unless File.directory?(dir)
        next unless gitignored?(root, artifact)

        size = dir_size(dir)
        next if size.zero?

        has_keep = File.exist?(File.join(dir, ".keep")) || File.exist?(File.join(dir, ".gitkeep"))
        if has_keep
          Dir.children(dir).each do |child|
            next if child == ".keep" || child == ".gitkeep"
            FileUtils.rm_rf(File.join(dir, child))
          end
        else
          FileUtils.rm_rf(dir)
        end
        puts "  #{GREEN}✓#{RESET} #{dir.sub(home, "~")}: #{human_size(size)}"
        freed += size
      end
    end
    freed
  end

  def self.clean_stale_zcompdumps
    home = Dir.home
    current = File.join(home, ".zcompdump")
    freed = 0

    Dir.glob(File.join(home, ".zcompdump*")).each do |f|
      next if f == current
      next if f == "#{current}.zwc"
      size = File.size(f) rescue 0
      next if size.zero?

      FileUtils.rm_rf(f)
      freed += size
    end

    if freed > 0
      puts "  #{GREEN}✓#{RESET} Stale zcompdumps: #{human_size(freed)}"
    end
    freed
  end

  CATEGORIES = %w[
    homebrew npm yarn pnpm bun rbenv mise bundler pip cocoapods carthage
    docker spotify gaming xcode android-studio gradle maven go cargo
    composer projects home browsers system
  ].freeze

  def self.parse_args(argv)
    options = {}

    parser = OptionParser.new do |opts|
      opts.banner = "Usage: clean_cache.rb [options] [category ...]"
      opts.separator ""
      opts.separator "With no arguments, all categories are cleaned."
      opts.separator ""
      opts.separator "Categories: #{CATEGORIES.join(", ")}"
      opts.separator ""

      opts.on("--scan", "Scan and show heaviest cleanable directories") do
        options[:scan] = true
      end

      opts.on("--list", "List available categories") do
        CATEGORIES.each { |c| puts c }
        exit
      end

      opts.on("--exclude CAT", "Exclude a category (can be repeated)") do |cat|
        unless CATEGORIES.include?(cat)
          abort "Unknown category: #{cat}\nAvailable: #{CATEGORIES.join(", ")}"
        end
        (options[:exclude] ||= []) << cat
      end

      opts.on("-h", "--help", "Show this help") do
        puts opts
        exit
      end
    end

    parser.parse!(argv)

    if argv.any?
      invalid = argv - CATEGORIES
      abort "Unknown categories: #{invalid.join(", ")}\nAvailable: #{CATEGORIES.join(", ")}" if invalid.any?
      options[:categories] = argv
    end

    options
  end

  def self.enabled?(category, options)
    if options[:categories]
      options[:categories].include?(category)
    elsif options[:exclude]
      !options[:exclude].include?(category)
    else
      true
    end
  end

  SCAN_DIRS = [
    "~/Library/Caches",
    "~/Library/Logs",
    "~/Library/Developer/Xcode/DerivedData",
    "~/Library/Developer/Xcode/iOS DeviceSupport",
    "~/Library/Developer/CoreSimulator/Caches",
    "~/Library/Application Support/Spotify/PersistentCache",
    "~/.gradle/caches",
    "~/.gradle/wrapper/dists",
    "~/.m2/repository",
    "~/.npm",
    "~/.cache",
    "~/.cargo/registry",
    "~/.bun/install/cache",
    "~/.bundle/cache",
    "~/.rbenv/cache",
    "~/.android",
    "~/.dotnet",
    "~/.node-gyp",
  ].freeze

  def self.scan!
    home = Dir.home
    puts "#{BOLD}cleanCache-MacOS — Scan Mode#{RESET}"
    puts "Scanning for cleanable directories...\n\n"

    entries = []

    SCAN_DIRS.each do |raw_path|
      path = File.expand_path(raw_path)
      next unless File.directory?(path)

      # For ~/Library/Caches and ~/Library/Logs, list children individually
      if raw_path == "~/Library/Caches" || raw_path == "~/Library/Logs"
        begin
          Dir.children(path).each do |child|
            child_path = File.join(path, child)
            next unless File.directory?(child_path)
            size = dir_size(child_path)
            next if size.zero?
            entries << [child_path.sub(home, "~"), size]
          end
        rescue Errno::EPERM, Errno::EACCES
          next
        end
      else
        size = dir_size(path)
        next if size.zero?
        entries << [path.sub(home, "~"), size]
      end
    end

    if entries.empty?
      puts "No cleanable directories found."
      return
    end

    entries.sort_by! { |_, size| -size }

    # Table layout
    max_path = [entries.map { |p, _| p.length }.max, 4].max
    max_size = [entries.map { |_, s| human_size(s).length }.max, 4].max
    total_width = max_path + 4 + max_size

    puts "#{BOLD}#{"Path".ljust(max_path)}    #{"Size".rjust(max_size)}#{RESET}"
    puts "#{DIM}#{"─" * total_width}#{RESET}"

    total = 0
    entries.each do |path, size|
      total += size
      color = size >= 1024 * 1024 * 100 ? RED : size >= 1024 * 1024 * 10 ? YELLOW : ""
      puts "#{path.ljust(max_path)}    #{color}#{human_size(size).rjust(max_size)}#{RESET}"
    end

    puts "#{DIM}#{"─" * total_width}#{RESET}"
    puts "#{BOLD}#{"Total".ljust(max_path)}    #{GREEN}#{human_size(total).rjust(max_size)}#{RESET}"
    puts "\n#{entries.length} directories found. Run without --scan to clean."
  end

  def self.section(title)
    puts "\n#{BOLD}#{title}#{RESET}"
    yield
  end

  def self.clean!(options = {})
    home = Dir.home
    total_freed = 0

    puts "#{BOLD}cleanCache-MacOS#{RESET}"
    if options[:categories]
      puts "Cleaning: #{options[:categories].join(", ")}\n"
    elsif options[:exclude]
      puts "Cleaning all except: #{options[:exclude].join(", ")}\n"
    else
      puts "Cleaning temporary files and caches...\n"
    end

    if enabled?("homebrew", options)
      section("Homebrew") do
        if system("which brew > /dev/null 2>&1")
          run_command("brew cleanup", "brew cleanup --prune=all -s")
          total_freed += clean_path("Homebrew cache", "~/Library/Caches/Homebrew").to_i
          total_freed += clean_path("Homebrew logs", "~/Library/Logs/Homebrew").to_i
        else
          puts "  (not installed, skipping)"
        end
      end
    end

    if enabled?("npm", options)
      section("npm") do
        if system("which npm > /dev/null 2>&1")
          run_command("npm cache clean", "npm cache clean --force")
          total_freed += clean_path("npm cache", "~/.npm/_cacache").to_i
        else
          puts "  (not installed, skipping)"
        end
      end
    end

    if enabled?("yarn", options)
      section("Yarn") do
        if system("which yarn > /dev/null 2>&1")
          run_command("yarn cache clean", "yarn cache clean")
          total_freed += clean_path("Yarn cache", "~/Library/Caches/Yarn").to_i
        else
          puts "  (not installed, skipping)"
        end
      end
    end

    if enabled?("pnpm", options)
      section("pnpm") do
        if system("which pnpm > /dev/null 2>&1")
          run_command("pnpm store prune", "pnpm store prune")
        else
          puts "  (not installed, skipping)"
        end
      end
    end

    if enabled?("bun", options)
      section("Bun") do
        total_freed += clean_path("Bun install cache", "~/.bun/install/cache").to_i
      end
    end

    if enabled?("rbenv", options)
      section("rbenv") do
        total_freed += clean_path("rbenv cache", "~/.rbenv/cache").to_i
      end
    end

    if enabled?("mise", options)
      section("mise") do
        if system("which mise > /dev/null 2>&1")
          run_command("mise cache clear", "mise cache clear")
          total_freed += clean_path("mise cache", "~/Library/Caches/mise").to_i
        else
          puts "  (not installed, skipping)"
        end
      end
    end

    if enabled?("bundler", options)
      section("Bundler") do
        total_freed += clean_path("Bundler cache", "~/.bundle/cache").to_i
      end
    end

    if enabled?("pip", options)
      section("pip") do
        total_freed += clean_path("pip cache", "~/Library/Caches/pip").to_i
      end
    end

    if enabled?("cocoapods", options)
      section("CocoaPods") do
        total_freed += clean_path("CocoaPods cache", "~/Library/Caches/CocoaPods").to_i
      end
    end

    if enabled?("carthage", options)
      section("Carthage") do
        total_freed += clean_path("Carthage cache", "~/Library/Caches/org.carthage.CarthageKit").to_i
      end
    end

    if enabled?("docker", options)
      section("Docker") do
        if system("which docker > /dev/null 2>&1")
          run_command("docker system prune", "docker system prune -f")
          run_command("docker builder prune", "docker builder prune -f")
        else
          puts "  (not installed, skipping)"
        end
      end
    end

    if enabled?("spotify", options)
      section("Spotify") do
        total_freed += clean_path("Spotify cache", "~/Library/Caches/com.spotify.client").to_i
        total_freed += clean_path("Spotify data cache", "~/Library/Application Support/Spotify/PersistentCache").to_i
      end
    end

    if enabled?("gaming", options)
      section("Gaming") do
        total_freed += clean_path("Steam cache", "~/Library/Caches/Steam").to_i
        total_freed += clean_path("Epic Games Launcher cache", "~/Library/Caches/com.epicgames.EpicGamesLauncher").to_i
      end
    end

    if enabled?("xcode", options)
      section("Xcode") do
        total_freed += clean_path("Xcode DerivedData", "~/Library/Developer/Xcode/DerivedData").to_i
        total_freed += clean_old_device_support.to_i
        total_freed += clean_path("CoreSimulator caches", "~/Library/Developer/CoreSimulator/Caches").to_i
      end
    end

    if enabled?("android-studio", options)
      section("Android Studio") do
        Dir.glob(File.expand_path("~/Library/Caches/Google/AndroidStudio*")).each do |dir|
          total_freed += clean_path("Android Studio cache (#{File.basename(dir)})", dir).to_i
        end
        total_freed += clean_path("Android build cache", "~/.android/build-cache").to_i
        total_freed += clean_path("Android cache", "~/.android/cache").to_i
      end
    end

    if enabled?("gradle", options)
      section("Gradle") do
        total_freed += clean_path("Gradle caches", "~/.gradle/caches").to_i
        total_freed += clean_path("Gradle wrapper dists", "~/.gradle/wrapper/dists").to_i
      end
    end

    if enabled?("maven", options)
      section("Maven") do
        total_freed += clean_path("Maven repository", "~/.m2/repository").to_i
      end
    end

    if enabled?("go", options)
      section("Go") do
        if system("which go > /dev/null 2>&1")
          run_command("go clean cache", "go clean -cache")
          run_command("go clean modcache", "go clean -modcache")
        else
          puts "  (not installed, skipping)"
        end
      end
    end

    if enabled?("cargo", options)
      section("Cargo (Rust)") do
        total_freed += clean_path("Cargo registry cache", "~/.cargo/registry/cache").to_i
      end
    end

    if enabled?("composer", options)
      section("Composer") do
        total_freed += clean_path("Composer cache", "~/Library/Caches/composer").to_i
      end
    end

    if enabled?("projects", options)
      section("Project Artifacts (~/*)") do
        total_freed += clean_project_artifacts.to_i
      end
    end

    if enabled?("home", options)
      section("Home Directory") do
        total_freed += clean_path("Babel cache", "~/.babel.json").to_i
        total_freed += clean_path("node-gyp cache", "~/.node-gyp").to_i
        total_freed += clean_path("Webdrivers cache", "~/.webdrivers").to_i
        total_freed += clean_path("XDG cache", "~/.cache").to_i
        total_freed += clean_path(".NET cache", "~/.dotnet").to_i
        total_freed += clean_path("HawtJNI cache", "~/.hawtjni").to_i
        total_freed += clean_stale_zcompdumps.to_i
      end
    end

    if enabled?("browsers", options)
      section("Browsers") do
        total_freed += clean_path("Safari cache", "~/Library/Caches/com.apple.Safari").to_i
        total_freed += clean_path("Google Chrome cache", "~/Library/Caches/Google/Chrome").to_i
        total_freed += clean_path("Firefox cache", "~/Library/Caches/Firefox").to_i
        total_freed += clean_path("Microsoft Edge cache", "~/Library/Caches/Microsoft Edge").to_i
        total_freed += clean_path("Brave cache", "~/Library/Caches/BraveSoftware/Brave-Browser").to_i
        total_freed += clean_path("Brave cache", "~/Library/Caches/com.brave.Browser").to_i
        total_freed += clean_path("Opera cache", "~/Library/Caches/com.operasoftware.Opera").to_i
        total_freed += clean_path("Opera GX cache", "~/Library/Caches/com.operasoftware.OperaGX").to_i
        total_freed += clean_path("Vivaldi cache", "~/Library/Caches/Vivaldi").to_i
        total_freed += clean_path("Vivaldi cache", "~/Library/Caches/com.vivaldi.Vivaldi").to_i
        total_freed += clean_path("Arc cache", "~/Library/Caches/company.thebrowser.Browser").to_i
      end
    end

    if enabled?("system", options)
      section("macOS System") do
        total_freed += clean_path("Apple CloudKit cache", "~/Library/Caches/CloudKit").to_i
        total_freed += clean_path("Swift Package Manager cache", "~/Library/Caches/org.swift.swiftpm").to_i
        total_freed += clean_path("TypeScript server cache", "~/Library/Caches/typescript").to_i
        total_freed += clean_path("User logs", "~/Library/Logs").to_i
      end
    end

    puts "\n#{BOLD}Done!#{RESET} Freed approximately #{GREEN}#{human_size(total_freed)}#{RESET} of disk space."
  end
end

options = CleanCache.parse_args(ARGV)
if options[:scan]
  CleanCache.scan!
else
  CleanCache.clean!(options)
end
