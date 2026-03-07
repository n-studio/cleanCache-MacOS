#!/usr/bin/env ruby
# frozen_string_literal: true

# cleanCache-MacOS
# A Ruby script to clean temporary files and caches on macOS.

require "fileutils"

module CleanCache
  BOLD  = "\e[1m"
  GREEN = "\e[32m"
  RED   = "\e[31m"
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
  end

  def self.clean_path(label, path)
    path = File.expand_path(path)
    return unless File.exist?(path)

    size = dir_size(path)
    return if size.zero?

    FileUtils.rm_rf(path)
    puts "  #{GREEN}✓#{RESET} #{label}: #{human_size(size)}"
    size
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

  def self.section(title)
    puts "\n#{BOLD}#{title}#{RESET}"
    yield
  end

  def self.clean!
    home = Dir.home
    total_freed = 0

    puts "#{BOLD}cleanCache-MacOS#{RESET}"
    puts "Cleaning temporary files and caches...\n"

    # --- Homebrew ---
    section("Homebrew") do
      if system("which brew > /dev/null 2>&1")
        run_command("brew cleanup", "brew cleanup --prune=all -s")
        total_freed += clean_path("Homebrew cache", "~/Library/Caches/Homebrew").to_i
        total_freed += clean_path("Homebrew logs", "~/Library/Logs/Homebrew").to_i
      else
        puts "  (not installed, skipping)"
      end
    end

    # --- npm ---
    section("npm") do
      if system("which npm > /dev/null 2>&1")
        run_command("npm cache clean", "npm cache clean --force")
        total_freed += clean_path("npm cache", "~/.npm/_cacache").to_i
      else
        puts "  (not installed, skipping)"
      end
    end

    # --- Yarn ---
    section("Yarn") do
      if system("which yarn > /dev/null 2>&1")
        run_command("yarn cache clean", "yarn cache clean")
        total_freed += clean_path("Yarn cache", "~/Library/Caches/Yarn").to_i
      else
        puts "  (not installed, skipping)"
      end
    end

    # --- pnpm ---
    section("pnpm") do
      if system("which pnpm > /dev/null 2>&1")
        run_command("pnpm store prune", "pnpm store prune")
      else
        puts "  (not installed, skipping)"
      end
    end

    # --- Bun ---
    section("Bun") do
      total_freed += clean_path("Bun install cache", "~/.bun/install/cache").to_i
    end

    # --- rbenv ---
    section("rbenv") do
      total_freed += clean_path("rbenv cache", "~/.rbenv/cache").to_i
    end

    # --- mise ---
    section("mise") do
      if system("which mise > /dev/null 2>&1")
        run_command("mise cache clear", "mise cache clear")
        total_freed += clean_path("mise cache", "~/Library/Caches/mise").to_i
      else
        puts "  (not installed, skipping)"
      end
    end

    # --- Bundler ---
    section("Bundler") do
      total_freed += clean_path("Bundler cache", "~/.bundle/cache").to_i
    end

    # --- pip ---
    section("pip") do
      total_freed += clean_path("pip cache", "~/Library/Caches/pip").to_i
    end

    # --- CocoaPods ---
    section("CocoaPods") do
      total_freed += clean_path("CocoaPods cache", "~/Library/Caches/CocoaPods").to_i
    end

    # --- Carthage ---
    section("Carthage") do
      total_freed += clean_path("Carthage cache", "~/Library/Caches/org.carthage.CarthageKit").to_i
    end

    # --- Docker ---
    section("Docker") do
      if system("which docker > /dev/null 2>&1")
        run_command("docker system prune", "docker system prune -f")
        run_command("docker builder prune", "docker builder prune -f")
      else
        puts "  (not installed, skipping)"
      end
    end

    # --- Spotify ---
    section("Spotify") do
      total_freed += clean_path("Spotify cache", "~/Library/Caches/com.spotify.client").to_i
      total_freed += clean_path("Spotify data cache", "~/Library/Application Support/Spotify/PersistentCache").to_i
    end

    # --- Xcode ---
    section("Xcode") do
      total_freed += clean_path("Xcode DerivedData", "~/Library/Developer/Xcode/DerivedData").to_i
      total_freed += clean_old_device_support.to_i
      total_freed += clean_path("CoreSimulator caches", "~/Library/Developer/CoreSimulator/Caches").to_i
    end

    # --- Gradle ---
    section("Gradle") do
      total_freed += clean_path("Gradle caches", "~/.gradle/caches").to_i
      total_freed += clean_path("Gradle wrapper dists", "~/.gradle/wrapper/dists").to_i
    end

    # --- Maven ---
    section("Maven") do
      total_freed += clean_path("Maven repository", "~/.m2/repository").to_i
    end

    # --- Go ---
    section("Go") do
      if system("which go > /dev/null 2>&1")
        run_command("go clean cache", "go clean -cache")
        run_command("go clean modcache", "go clean -modcache")
      else
        puts "  (not installed, skipping)"
      end
    end

    # --- Rust / Cargo ---
    section("Cargo (Rust)") do
      total_freed += clean_path("Cargo registry cache", "~/.cargo/registry/cache").to_i
    end

    # --- Composer (PHP) ---
    section("Composer") do
      total_freed += clean_path("Composer cache", "~/Library/Caches/composer").to_i
    end

    # --- Project artifacts ---
    section("Project Artifacts (~/*)") do
      total_freed += clean_project_artifacts.to_i
    end

    # --- Home directory caches ---
    section("Home Directory") do
      total_freed += clean_path("Babel cache", "~/.babel.json").to_i
      total_freed += clean_path("node-gyp cache", "~/.node-gyp").to_i
      total_freed += clean_path("Webdrivers cache", "~/.webdrivers").to_i
      total_freed += clean_path("XDG cache", "~/.cache").to_i
      total_freed += clean_path(".NET cache", "~/.dotnet").to_i
      total_freed += clean_path("HawtJNI cache", "~/.hawtjni").to_i
      total_freed += clean_stale_zcompdumps.to_i
    end

    # --- macOS system caches (safe targets only) ---
    section("macOS System") do
      total_freed += clean_path("Apple CloudKit cache", "~/Library/Caches/CloudKit").to_i
      total_freed += clean_path("Safari cache", "~/Library/Caches/com.apple.Safari").to_i
      total_freed += clean_path("Swift Package Manager cache", "~/Library/Caches/org.swift.swiftpm").to_i
      total_freed += clean_path("TypeScript server cache", "~/Library/Caches/typescript").to_i
      total_freed += clean_path("Google Chrome cache", "~/Library/Caches/Google/Chrome").to_i
      total_freed += clean_path("User logs", "~/Library/Logs").to_i
    end

    puts "\n#{BOLD}Done!#{RESET} Freed approximately #{GREEN}#{human_size(total_freed)}#{RESET} of disk space."
  end
end

CleanCache.clean!
