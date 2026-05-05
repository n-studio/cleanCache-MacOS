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
  rescue Errno::EPERM, Errno::EACCES, Errno::EINTR
    0
  end

  def self.fast_dir_size(path)
    path = File.expand_path(path)
    return 0 unless File.exist?(path)
    output = `du -skx "#{path}" 2>/dev/null`.strip
    return 0 if output.empty?
    output.split("\t").first.to_i * 1024
  rescue StandardError
    0
  end

  def self.disk_usage
    # On APFS (macOS 10.15+), use the Data volume for accurate container-level totals.
    # "Used" is computed as total - available since df per-volume "used" excludes other volumes.
    df_path = File.directory?("/System/Volumes/Data") ? "/System/Volumes/Data" : "/"
    line = `df -Pk "#{df_path}"`.split("\n").last
    parts = line.split
    total = parts[1].to_i * 1024
    available = parts[3].to_i * 1024
    [total, total - available, available]
  end

  # Sizes of APFS sibling volumes (System, Preboot, Recovery, VM) in the same
  # container as the Data volume.  These consume container capacity that df
  # reports as "used" but that du never sees because they are separate volumes.
  def self.apfs_sibling_volumes_size
    output = `diskutil apfs list 2>/dev/null`
    return 0 if output.empty?

    # Find the container that holds the Data role volume
    containers = output.split(/^\+-- Container /)
    containers.shift # drop text before first container

    containers.each do |block|
      volumes = block.split(/\+-> Volume /)
      volumes.shift # container header

      has_data = volumes.any? { |v| v =~ /\(Data\)/ }
      next unless has_data

      sibling_bytes = 0
      volumes.each do |v|
        next if v =~ /\(Data\)/
        if v =~ /Capacity Consumed:\s+(\d+)\s+B\b/
          sibling_bytes += $1.to_i
        end
      end
      return sibling_bytes
    end
    0
  rescue StandardError
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
  rescue Errno::EPERM, Errno::EACCES, Errno::EINTR
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

  # Chromium-based browsers (Chrome, Brave, Edge, Opera, Vivaldi, Arc) ship
  # their main framework as <App>.app/Contents/Frameworks/<X> Framework.framework
  # with versioned subdirs under Versions/ and a "Current" symlink to the
  # active one. Each update writes a new version (~600–700 MB) but old ones
  # are kept indefinitely. Only the Current target is loaded; deleting the
  # others is safe — even while the browser is running, since open file
  # handles keep the running version alive until the process exits.
  def self.clean_old_chromium_frameworks
    freed = 0
    Dir.glob("/Applications/*.app/Contents/Frameworks/*.framework/Versions").each do |versions_dir|
      current_link = File.join(versions_dir, "Current")
      next unless File.symlink?(current_link)

      current = File.readlink(current_link)
      target = File.expand_path(current, versions_dir)
      next unless File.directory?(target)
      current_name = File.basename(target)

      old_versions = Dir.children(versions_dir)
        .reject { |name| name == "Current" || name == current_name }
        .map { |name| File.join(versions_dir, name) }
        .select { |path| File.directory?(path) && !File.symlink?(path) }
      next if old_versions.empty?

      app_name = versions_dir[%r{/Applications/([^/]+)\.app/}, 1]
      bundle_freed = 0
      old_versions.each do |old|
        size = fast_dir_size(old)
        FileUtils.rm_rf(old)
        next if File.exist?(old)
        bundle_freed += size
      end

      if bundle_freed > 0
        puts "  #{GREEN}✓#{RESET} Old framework versions (#{app_name}, kept #{current_name}): #{human_size(bundle_freed)}"
        freed += bundle_freed
      end
    end
    freed
  end

  # macOS sandbox keeps a per-bundle code-sign clone tree at
  # /private/var/folders/<prefix>/<user-hash>/X/<bundle-id>.code_sign_clone/
  # (sibling of $TMPDIR), with one subdir per code-signing verification.
  # Chrome and its forks (Brave, Edge, Opera, Vivaldi, Arc) accumulate one
  # per auto-update without ever cleaning up — easily tens of GB. The
  # snapshots are APFS-cloned, so apparent size dwarfs real disk impact, but
  # they still take real bytes. Keep the most-recent snapshot per bundle as
  # a safety fallback; delete the rest.
  def self.clean_old_code_sign_clones
    tmpdir = ENV["TMPDIR"]
    return 0 if tmpdir.nil? || tmpdir.empty?

    workspace = File.join(File.dirname(tmpdir.sub(%r{/+\z}, "")), "X")
    return 0 unless File.directory?(workspace)

    freed = 0
    Dir.glob(File.join(workspace, "*.code_sign_clone")).each do |bundle_dir|
      snapshots = Dir.children(bundle_dir)
        .map { |c| File.join(bundle_dir, c) }
        .select { |p| File.directory?(p) }
      next if snapshots.size <= 1

      snapshots.sort_by! { |p| File.mtime(p) rescue Time.at(0) }
      bundle_name = File.basename(bundle_dir).sub(/\.code_sign_clone\z/, "")
      bundle_freed = 0
      snapshots[0..-2].each do |old|
        size = dir_size(old)
        FileUtils.rm_rf(old)
        next if File.exist?(old)
        bundle_freed += size
      end

      if bundle_freed > 0
        puts "  #{GREEN}✓#{RESET} Code-sign clones (#{bundle_name}): #{human_size(bundle_freed)}"
        freed += bundle_freed
      end
    end
    freed
  end

  # macOS creates "Relocated Items" / "Previously Relocated Items N" in
  # /Users/Shared on each system update — snapshots of default config files
  # (mostly /etc/ssh/*) preserved in case the user customised them. Keep the
  # most-recent snapshot as a safety fallback; delete the older ones.
  # These are root-owned, so deletion requires sudo.
  def self.clean_old_relocated_items
    shared = "/Users/Shared"
    return 0 unless File.directory?(shared)

    entries = Dir.children(shared)
      .select { |c| c == "Relocated Items" || c.start_with?("Previously Relocated Items") }
      .map { |c| File.join(shared, c) }
      .select { |p| File.directory?(p) }

    return 0 if entries.size <= 1

    latest = entries.max_by { |p| File.mtime(p) rescue Time.at(0) }

    freed = 0
    permission_denied = false
    entries.each do |path|
      next if path == latest
      size = dir_size(path)
      FileUtils.rm_rf(path, secure: true)
      if File.exist?(path)
        permission_denied = true
      else
        puts "  #{GREEN}✓#{RESET} #{File.basename(path)}: #{human_size(size)}"
        freed += size
      end
    end
    if permission_denied
      puts "  #{RED}✗#{RESET} Some Relocated Items dirs are root-owned — re-run with sudo to delete."
    elsif freed > 0
      puts "  Kept latest: #{File.basename(latest)}"
    end
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

  # Drops PostgreSQL databases whose name ends with _test_<digits> — parallel
  # test fixtures (Rails parallel tests, pytest-postgres, etc.) that are
  # auto-recreated by the test framework and safe to remove.
  def self.clean_postgresql_test_databases
    clusters = postgresql_clusters
    if clusters.empty?
      puts "  (no PostgreSQL clusters found)"
      return 0
    end

    pattern = '_test_[0-9]+$'
    total_freed = 0
    clusters.each do |cluster_path|
      cluster_name = File.basename(cluster_path)
      endpoint = postgresql_running_endpoint(cluster_path)
      unless endpoint
        puts "  #{DIM}#{cluster_name}: not running, skipping#{RESET}"
        next
      end

      psql = psql_for(cluster_name)
      list_query = "SELECT datname, pg_database_size(datname) FROM pg_database WHERE datname ~ '#{pattern}' ORDER BY 1;"
      output = `"#{psql}" -h "#{endpoint[:socket_dir]}" -p #{endpoint[:port]} -d postgres -At -F'|' -c "#{list_query}" 2>/dev/null`
      unless $?.success?
        puts "  #{RED}✗#{RESET} #{cluster_name}: psql query failed"
        next
      end

      targets = output.lines.map { |l| l.chomp.split("|", 2) }
                            .select { |name, size| name && size }
                            .map { |name, size| [name, size.to_i] }

      if targets.empty?
        puts "  #{DIM}#{cluster_name}: no _test_<n> databases found#{RESET}"
        next
      end

      targets.each do |name, size|
        next if name.include?('"') # paranoia: skip names that would break quoting
        drop = `"#{psql}" -h "#{endpoint[:socket_dir]}" -p #{endpoint[:port]} -d postgres -c 'DROP DATABASE "#{name}" WITH (FORCE);' 2>&1`
        if $?.success?
          puts "  #{GREEN}✓#{RESET} #{cluster_name}/#{name}: #{human_size(size)}"
          total_freed += size
        else
          puts "  #{RED}✗#{RESET} #{cluster_name}/#{name}: #{drop.strip.lines.last&.strip}"
        end
      end
    end
    total_freed
  end

  CATEGORIES = %w[
    homebrew npm yarn pnpm bun rbenv mise bundler pip cocoapods carthage
    docker postgresql spotify gaming xcode android-studio gradle maven go cargo
    composer postman projects home browsers system
  ].freeze

  INSPECT_CATEGORIES = %w[homebrew postgresql reserved].freeze

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

      opts.on("--storage", "Show disk storage breakdown by category") do
        options[:storage] = true
      end

      opts.on("--inspect CAT", INSPECT_CATEGORIES,
              "Drill into a storage category (#{INSPECT_CATEGORIES.join(", ")})") do |cat|
        options[:inspect] = cat
      end

      opts.on("--force-purge", "Reserve disk via fcntl(F_PREALLOCATE) to evict APFS purgeable bytes") do
        options[:force_purge] = true
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

  # Directories whose immediate children are listed individually
  SCAN_EXPAND_DIRS = [
    "~/Library/Caches",
    "~/Library/Logs",
    "~/Library/Application Support",
    "~/Library/Containers",
    "~/Library/Group Containers",
    "~/Library/Developer/Xcode",
    "~/Library/Developer/CoreSimulator",
    "/Library/Caches",
  ].freeze

  # Specific paths shown as single entries
  SCAN_SINGLE_DIRS = [
    "~/.Trash",
    "~/Library/Application Support/MobileSync/Backup",
    "~/Library/Developer/Packages",
    "~/Library/Developer/CommandLineTools",
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
    "~/Library/Application Support/Postman",
  ].freeze

  # Minimum size to show in scan results (1 GB)
  SCAN_MIN_SIZE = 1024 * 1024 * 1024

  # Dotfiles/dotdirs in ~ that are application-related (not personal documents)
  STORAGE_APP_DOTDIRS = %w[
    .npm .yarn .pnpm-store .bun .cache .gradle .m2 .cargo .rustup .bundle
    .rbenv .pyenv .nvm .volta .android .dotnet .cocoapods .node-gyp .composer
    .docker .gem .local .mix .hex .config .swiftpm .mise .hawtjni .webdrivers
    .vscode .cursor .conda .virtualenvs
  ].freeze

  def self.scan!
    home = Dir.home
    puts "#{BOLD}cleanCache-MacOS — Scan Mode#{RESET}"
    puts "Scanning for cleanable directories...\n\n"

    entries = []

    SCAN_EXPAND_DIRS.each do |raw_path|
      path = File.expand_path(raw_path)
      next unless File.directory?(path)

      begin
        Dir.children(path).each do |child|
          child_path = File.join(path, child)
          next unless File.directory?(child_path)
          size = dir_size(child_path)
          next if size < SCAN_MIN_SIZE
          entries << [child_path.sub(home, "~"), size]
        end
      rescue Errno::EPERM, Errno::EACCES
        next
      end
    end

    SCAN_SINGLE_DIRS.each do |raw_path|
      path = File.expand_path(raw_path)
      next unless File.exist?(path)
      size = dir_size(path)
      next if size < SCAN_MIN_SIZE
      entries << [path.sub(home, "~"), size]
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
    puts "\n#{entries.length} directories (>= 1 MB). Run without --scan to clean."
  end

  # Force-purge: trigger eviction of APFS purgeable content (Photos optimised
  # originals, iCloud Drive cached files, on-device AI assets, app caches that
  # opted into NSPurgeable, downloaded language packs, etc.).
  #
  # The mechanism: macOS only evicts purgeable bytes under disk pressure.
  # There's no public API to ask for eviction directly — `diskutil`, `tmutil`
  # and `purge(8)` don't cover it. Instead of writing a large fill file (which
  # burns SSD endurance), we use fcntl(F_PREALLOCATE) to reserve filesystem
  # blocks at the inode level without writing any data. The blocks count
  # against `df` available — same pressure signal — but the SSD's NAND cells
  # are never touched. This is the same primitive the App Store uses to
  # preallocate space for downloads, which is why an App Store install can
  # succeed on an apparently-full disk: the preallocation forces purgeable
  # eviction. Releasing the file frees the blocks instantly.
  #
  # How this implementation works:
  #   1. Snapshot avail via df (disk_usage), refuse if too close to floor.
  #   2. Open a placeholder file at /tmp/cleanCache-MacOS-purge.fill with
  #      O_EXCL (won't clobber). The file's logical size stays at 0;
  #      F_PREALLOCATE reserves blocks past EOF.
  #   3. Loop: re-check df, call fcntl(F_PREALLOCATE, F_ALLOCATEALL) for
  #      a 256 MB chunk, ftruncate to make the reservation visible in stat.
  #      Stop when reserved ≥ max_reserve, when avail dips to the floor,
  #      or on ENOSPC. Per-chunk re-checks let concurrent writes push us
  #      off the loop instead of crashing the system.
  #   4. Close + unlink the file. APFS releases the blocks the moment the
  #      last fd is gone. The eviction the kernel performed during the
  #      reservation is the net win, visible by comparing df before vs
  #      after.
  #
  # The fstore_t struct passed to fcntl:
  #   u_int32_t fst_flags       — F_ALLOCATEALL = all-or-nothing
  #   int       fst_posmode     — F_PEOFPOSMODE = offset relative to EOF
  #   off_t     fst_offset      — 0 (start at EOF)
  #   off_t     fst_length      — bytes to reserve
  #   off_t     fst_bytesalloc  — (out) bytes actually allocated
  # Pack format "LlqqQ" → 4 + 4 + 8 + 8 + 8 = 32 bytes. The 4-byte fields
  # leave the off_t fields naturally 8-byte aligned, so no padding.
  #
  # Why this is bounded: three independent caps — FORCE_PURGE_MAX_FILL is an
  # absolute byte ceiling, FORCE_PURGE_FLOOR_BYTES is an absolute
  # available-space floor, and we re-derive `chunk` against current avail
  # every iteration. Whichever cap binds first stops the loop.
  #
  # Why cleanup is reliable: idempotent cleanup lambda invoked from three
  # independent points — the `ensure` of the alloc loop (normal exit and
  # most exceptions), an `at_exit` handler (SystemExit / uncaught
  # exceptions), and SIGINT/SIGTERM traps (Ctrl-C and `kill`). A
  # `cleaned_up` flag makes re-entry a no-op. SIGKILL or power loss can
  # leak the placeholder, but /tmp is wiped on reboot — and since the file
  # holds reservations rather than written data, even a leak only costs
  # disk accounting until the next reboot.
  #
  # Costs: a few hundred ms of fcntl calls. No SSD writes.
  F_PREALLOCATE             = 42                 # macOS fcntl: reserve blocks
  F_ALLOCATEALL             = 0x00000004         # all-or-nothing reservation
  F_PEOFPOSMODE             = 3                  # offset is relative to EOF
  FSTORE_T_PACK             = "LlqqQ"            # u32 flags, i32 posmode, 3× off_t
  FORCE_PURGE_FLOOR_BYTES   = 8 * 1024**3        # never reserve below 8 GB available
  FORCE_PURGE_MAX_FILL      = 100 * 1024**3      # never reserve more than 100 GB
  FORCE_PURGE_CHUNK_BYTES   = 256 * 1024 * 1024  # 256 MB chunks → frequent re-checks
  FORCE_PURGE_HEADROOM      = 5 * 1024**3        # require this much room above floor to start
  FORCE_PURGE_PATH          = "/tmp/cleanCache-MacOS-purge.fill"

  def self.force_purge!
    fill_path = FORCE_PURGE_PATH

    total, _used, avail = disk_usage
    puts "#{BOLD}cleanCache-MacOS — Force purge#{RESET}"
    puts "Reserves disk space via fcntl(F_PREALLOCATE) to evict APFS purgeable"
    puts "bytes, then releases the reservation. No data is written to the SSD."
    puts ""
    puts "  Disk:        #{human_size(total)}"
    puts "  Available:   #{human_size(avail)}"
    puts "  Floor:       #{human_size(FORCE_PURGE_FLOOR_BYTES)} (will not allocate below this)"
    puts "  Max reserve: #{human_size(FORCE_PURGE_MAX_FILL)}"
    puts "  Path:        #{fill_path}"
    puts ""

    if avail <= FORCE_PURGE_FLOOR_BYTES + FORCE_PURGE_HEADROOM
      puts "#{YELLOW}Refusing to run: available space (#{human_size(avail)}) is too close to the floor.#{RESET}"
      puts "  Need at least #{human_size(FORCE_PURGE_FLOOR_BYTES + FORCE_PURGE_HEADROOM)} available."
      return
    end

    if File.exist?(fill_path)
      puts "#{RED}Refusing to run: a placeholder already exists at #{fill_path}.#{RESET}"
      puts "  If no purge is currently running, remove it manually and retry."
      return
    end

    max_reserve = [avail - FORCE_PURGE_FLOOR_BYTES, FORCE_PURGE_MAX_FILL].min
    puts "Will reserve up to #{human_size(max_reserve)}, then release it."
    puts ""
    print "Type #{BOLD}yes#{RESET} to proceed: "
    $stdout.flush
    answer = ($stdin.gets || "").strip
    unless answer == "yes"
      puts "Aborted."
      return
    end

    cleaned_up = false
    cleanup = lambda do
      next if cleaned_up
      cleaned_up = true
      next unless File.exist?(fill_path)
      bytes = (File.size(fill_path) rescue 0)
      puts ""
      print "  Releasing reservation (#{human_size(bytes)})..."
      $stdout.flush
      File.unlink(fill_path) rescue nil
      puts " #{GREEN}done#{RESET}"
    end

    at_exit(&cleanup)
    trap("INT")  { cleanup.call; exit 130 }
    trap("TERM") { cleanup.call; exit 143 }

    reserved = 0
    stop_reason = nil
    begin
      File.open(fill_path, File::CREAT | File::RDWR | File::EXCL, 0o600) do |f|
        while reserved < max_reserve
          _, _, current_avail = disk_usage
          if current_avail <= FORCE_PURGE_FLOOR_BYTES
            stop_reason = "hit floor (#{human_size(current_avail)} available)"
            break
          end
          remaining_to_floor = current_avail - FORCE_PURGE_FLOOR_BYTES
          chunk = [FORCE_PURGE_CHUNK_BYTES, max_reserve - reserved, remaining_to_floor].min
          break if chunk <= 0

          fstore = [F_ALLOCATEALL, F_PEOFPOSMODE, 0, chunk, 0].pack(FSTORE_T_PACK)
          f.fcntl(F_PREALLOCATE, fstore)
          bytesalloc = fstore.unpack(FSTORE_T_PACK)[4]
          if bytesalloc <= 0
            stop_reason = "kernel allocated 0 bytes"
            break
          end
          f.truncate(reserved + bytesalloc)
          reserved += bytesalloc
          printf "\r  Reserved: %s  (avail: %s)   ", human_size(reserved), human_size(current_avail)
          $stdout.flush
        end
      end
    rescue Errno::ENOSPC
      stop_reason = "disk full"
    rescue Errno::EINVAL, Errno::EOPNOTSUPP => e
      stop_reason = "F_PREALLOCATE failed: #{e.class}: #{e.message}"
    ensure
      cleanup.call
    end

    _, _, after_avail = disk_usage
    reclaimed = after_avail - avail
    puts ""
    puts "  Stopped: #{stop_reason}" if stop_reason
    if reclaimed > 0
      puts "#{GREEN}Reclaimed #{human_size(reclaimed)} of purgeable space.#{RESET}"
      puts "  Available: #{human_size(avail)} → #{human_size(after_avail)}"
    elsif reclaimed < 0
      puts "#{YELLOW}Available decreased by #{human_size(-reclaimed)} (other writes during purge?).#{RESET}"
      puts "  Available: #{human_size(avail)} → #{human_size(after_avail)}"
    else
      puts "No purgeable space was reclaimed."
    end
  end

  # Invariant: the sum of every category below must equal the total used disk.
  # "Other" is NOT a residual (used_disk - accounted) — that hides bugs.
  # If the categories don't add up to used_disk, the accounting is wrong and
  # the code must be fixed (e.g. a path is missed, double-counted, or
  # mis-categorised). Treat any discrepancy as a bug, not a rounding artefact.
  def self.storage!
    home = Dir.home
    puts "#{BOLD}cleanCache-MacOS — Storage#{RESET}"
    puts "Analyzing disk usage...\n\n"

    total_disk, used_disk, avail_disk = disk_usage

    # 1. Applications: split into four rows — /Applications (.app bundles),
    #    ~/Library (app data, minus iOS backups, Developer, Android, Docker),
    #    home dotdirs (CLI tool caches, minus .docker), /opt/homebrew.
    print "  Scanning Applications..."; $stdout.flush
    app_size = fast_dir_size("/Applications")
    lib_size = fast_dir_size("#{home}/Library")
    ios_size = fast_dir_size("#{home}/Library/Application Support/MobileSync")
    developer_size = fast_dir_size("#{home}/Library/Developer")
    sys_developer_size = fast_dir_size("/Library/Developer")
    android_size = fast_dir_size("#{home}/Library/Android")
    docker_container_size = fast_dir_size("#{home}/Library/Containers/com.docker.docker")
    docker_app_support_size = fast_dir_size("#{home}/Library/Application Support/Docker Desktop")
    docker_group_size = fast_dir_size("#{home}/Library/Group Containers/group.com.docker")
    docker_dotdir_size = fast_dir_size("#{home}/.docker")
    docker_lib = docker_container_size + docker_app_support_size + docker_group_size
    macos_logs_size = [fast_dir_size("#{home}/Library/Logs") - fast_dir_size("#{home}/Library/Logs/Homebrew"), 0].max
    macos_system_size =
      fast_dir_size("#{home}/Library/Caches/CloudKit") +
      fast_dir_size("#{home}/Library/Caches/typescript") +
      macos_logs_size
    homebrew_size = fast_dir_size("/opt/homebrew")
    swiftpm_size = fast_dir_size("#{home}/Library/Caches/org.swift.swiftpm")
    app_lib = [lib_size - ios_size - developer_size - android_size - docker_lib - macos_system_size - swiftpm_size, 0].max
    app_dots = STORAGE_APP_DOTDIRS.reject { |d| d == ".docker" }
                                  .sum { |d| fast_dir_size(File.join(home, d)) }
    puts " done"

    # 2. Developer: ~/Library/Developer + /Library/Developer + SPM cache (Xcode, CoreSimulator runtimes, CLT, etc.)
    developer = developer_size + sys_developer_size + swiftpm_size

    # 3. Android: ~/Library/Android (Android Studio SDKs, AVDs, etc.)
    android = android_size

    # 4. Docker: VM disk + group containers + app support + ~/.docker
    docker = docker_lib + docker_dotdir_size

    # 2. Movies
    print "  Scanning Movies..."; $stdout.flush
    movies = fast_dir_size("#{home}/Movies")
    puts " done"

    # 3. Music
    print "  Scanning Music..."; $stdout.flush
    music = fast_dir_size("#{home}/Music")
    puts " done"

    # 4. Pictures
    print "  Scanning Pictures..."; $stdout.flush
    pictures = fast_dir_size("#{home}/Pictures")
    puts " done"

    # 5. Downloads
    print "  Scanning Downloads..."; $stdout.flush
    downloads = fast_dir_size("#{home}/Downloads")
    puts " done"

    # 6. Documents: everything in ~ not app-related and not media/Library/Trash
    print "  Scanning Documents..."; $stdout.flush
    excluded_home = %w[Library Movies Music Pictures Downloads .Trash] + STORAGE_APP_DOTDIRS
    documents = 0
    begin
      Dir.children(home).each do |child|
        next if excluded_home.include?(child)
        full = File.join(home, child)
        documents += File.directory?(full) ? fast_dir_size(full) : (File.size(full) rescue 0)
      end
    rescue Errno::EPERM, Errno::EACCES
    end
    puts " done"

    # 8. iOS Files
    ios_files = ios_size

    # 9. Trash
    print "  Scanning Trash..."; $stdout.flush
    trash = fast_dir_size("#{home}/.Trash")
    puts " done"

    # Other Users: secondary user accounts on this machine.
    print "  Scanning other users..."; $stdout.flush
    other_users_detail = []
    if File.directory?("/Users")
      begin
        Dir.children("/Users").each do |u|
          next if u == File.basename(home) || u == "Shared" || u.start_with?(".")
          path = "/Users/#{u}"
          next unless File.directory?(path)
          size = fast_dir_size(path)
          other_users_detail << [path, size] if size > SCAN_MIN_SIZE
        end
      rescue Errno::EPERM, Errno::EACCES
      end
    end
    other_users = other_users_detail.sum { |_, s| s }
    puts " done"

    # macOS: user Library paths related to macOS cleanup handled by this tool.
    print "  Scanning macOS caches..."; $stdout.flush
    os_size = macos_system_size
    puts " done"

    # System areas — split into named sub-categories instead of one aggregate.
    print "  Scanning system files..."; $stdout.flush
    # /private holds /var/{folders,db,log,install} — sandbox caches, dyld
    # shared cache, system databases, install caches.
    system_cache_size = fast_dir_size("/private")
    # /System/Volumes/Data/System mirrors writable /System content via firmlinks
    # (Speech voices, AssetsV2, mobile assets, system caches).
    system_files_size = fast_dir_size("/System/Volumes/Data/System")
    # /Library minus /Library/Developer (already in Developer) — third-party
    # system installs (fonts, kexts, app support).
    shared_lib_size = [fast_dir_size("/Library") - sys_developer_size, 0].max
    # APFS sibling volumes (macOS System SSV, Preboot, Recovery, VM swap) live
    # in the same container as Data and consume capacity df reports as "used".
    os_volumes_size = apfs_sibling_volumes_size
    # /usr/local is firmlinked to Data; the rest of /usr lives on SSV and is
    # already accounted for via os_volumes_size.
    usr_local_size = fast_dir_size("/usr/local")
    # /opt minus /opt/homebrew (already in Applications).
    opt_size = [fast_dir_size("/opt") - homebrew_size, 0].max
    shared_users_size = fast_dir_size("/Users/Shared")
    metadata_size = 0
    %w[
      .Spotlight-V100 .fseventsd .DocumentRevisions-V100
      .PreviousSystemInformation MobileSoftwareUpdate
    ].each do |p|
      metadata_size += fast_dir_size("/System/Volumes/Data/#{p}")
    end
    sibling_size = os_volumes_size # alias kept for the volume-coverage check
    puts " done"

    # Root-level directories not covered by the categories above — listed
    # individually as their own rows. No catch-all "Other" aggregate.
    print "  Scanning root..."; $stdout.flush
    extra_root_detail = []
    accounted_root = %w[Applications Library Users private usr opt System bin sbin]
    # Symlinks to /private (already counted) and out-of-volume / special mounts.
    firmlink_root = %w[etc tmp var Volumes dev home cores]
    begin
      Dir.children("/").each do |child|
        next if accounted_root.include?(child) || firmlink_root.include?(child)
        next if child.start_with?(".")
        path = "/#{child}"
        next unless File.directory?(path)
        size = fast_dir_size(path)
        extra_root_detail << [path, size] if size > 0
      end
    rescue Errno::EPERM, Errno::EACCES
    end
    puts " done"

    # Build results in display order. Every byte lives in a named row —
    # no catch-all "Other" aggregate. Stray root-level paths are appended
    # as their own explicit rows below.
    results = [
      ["Applications (.app)",     app_size],
      ["Applications (Library)",  app_lib],
      ["Applications (dotdirs)",  app_dots],
      ["Applications (Homebrew)", homebrew_size],
      ["Developer",        developer],
      ["Android",          android],
      ["Docker",           docker],
      ["Movies",           movies],
      ["Music",            music],
      ["Pictures",         pictures],
      ["Downloads",        downloads],
      ["Documents",        documents],
      ["macOS",            os_size],
      ["System Cache",     system_cache_size],
      ["System Files",     system_files_size],
      ["/Library",         shared_lib_size],
      ["OS Volumes",       os_volumes_size],
      ["/usr/local",       usr_local_size],
      ["/opt",             opt_size],
      ["/Users/Shared",    shared_users_size],
      ["Volume metadata",  metadata_size],
      ["iOS Files",        ios_files],
      ["Trash",            trash],
      ["Other Users",      other_users],
    ]
    extra_root_detail.sort_by { |_, s| -s }.each do |path, size|
      results << [path, size]
    end

    # Tight-invariant anchor: the apparent total of the Data volume + the
    # sibling APFS volumes (System/Preboot/Recovery/VM) is what every category
    # combined must equal. Anything else is a bug — a missed path or a
    # double-count between categories.
    print "  Verifying volume coverage..."; $stdout.flush
    data_apparent = fast_dir_size("/System/Volumes/Data")
    expected_apparent = data_apparent + sibling_size
    puts " done"

    # Tight invariant: sum(categories) == du(Data volume) + sibling volumes.
    # Any deviation is a bug — a missed path or a double-count between
    # categories. Check this BEFORE adjusting for APFS clone savings.
    measured = results.sum { |_, s| s }
    accounting_error = measured - expected_apparent

    # Two effects pull (sum of categories) away from used_disk:
    #   - APFS clonefile(2) shares blocks between files, so du's apparent total
    #     can exceed real disk usage. Attribute the savings to System Cache
    #     (where macOS clones are concentrated: cryptex, dyld_shared_cache,
    #     install caches).
    #   - TCC-protected paths du can't traverse without sudo (Apple Intelligence
    #     ML models under AssetsV2, .Spotlight-V100, .fseventsd, com.apple.TCC,
    #     etc.) hide bytes that df still counts. Surface them as "Reserved".
    # After adjustment, sum(categories) == used_disk.
    clone_savings = expected_apparent - used_disk
    reserved_size = 0
    if clone_savings > 0
      results = results.map do |name, size|
        name == "System Cache" ? [name, [size - clone_savings, 0].max] : [name, size]
      end
    elsif clone_savings < 0
      reserved_size = -clone_savings
      idx = results.index { |name, _| name == "System Files" } || results.size
      results.insert(idx + 1, ["Reserved (sudo)", reserved_size])
    end
    adjusted_total = results.sum { |_, s| s }

    puts ""
    max_name = [results.map { |n, _| n.length }.max, 8].max
    max_size = [results.map { |_, s| human_size(s).length }.max, 4].max
    bar_width = 20
    total_width = max_name + 4 + max_size + 3 + 6 + 3 + bar_width

    puts "#{BOLD}#{"Category".ljust(max_name)}    #{"Size".rjust(max_size)}   #{"  %".rjust(6)}   Bar#{RESET}"
    puts "#{DIM}#{"─" * total_width}#{RESET}"

    results.each do |name, size|
      pct = adjusted_total > 0 ? (size.to_f / adjusted_total * 100) : 0
      filled = [[0, (pct / 100 * bar_width).round].max, bar_width].min
      bar = "█" * filled + "░" * (bar_width - filled)
      color = size >= 1024**3 * 10 ? RED : size >= 1024**3 ? YELLOW : ""
      puts "#{name.ljust(max_name)}    #{color}#{human_size(size).rjust(max_size)}#{RESET}   #{format("%5.1f%%", pct)}   #{color}#{bar}#{RESET}"
    end

    used_pct = total_disk > 0 ? (used_disk.to_f / total_disk * 100) : 0
    avail_pct = total_disk > 0 ? (avail_disk.to_f / total_disk * 100) : 0
    puts "#{DIM}#{"─" * total_width}#{RESET}"
    puts "#{BOLD}#{"Used".ljust(max_name)}    #{human_size(used_disk).rjust(max_size)}   #{format("%5.1f%%", used_pct)}#{RESET}"
    puts "#{"Available".ljust(max_name)}    #{GREEN}#{human_size(avail_disk).rjust(max_size)}#{RESET}   #{format("%5.1f%%", avail_pct)}"
    puts "#{BOLD}#{"Capacity".ljust(max_name)}    #{human_size(total_disk).rjust(max_size)}#{RESET}"
    if clone_savings > SCAN_MIN_SIZE
      puts "#{DIM}System Cache reduced by #{human_size(clone_savings)} of APFS clone-shared blocks (cryptex / dyld / install caches).#{RESET}"
    end
    if reserved_size > SCAN_MIN_SIZE
      puts "#{DIM}Reserved holds TCC-protected paths du can't traverse (Apple Intelligence models, Spotlight, fseventsd) — re-run with sudo for detail.#{RESET}"
    end

    # Tight invariant violation (pre-adjustment): a path is missed,
    # double-counted, or mis-categorised in the storage accounting.
    if accounting_error.abs > SCAN_MIN_SIZE
      sign = accounting_error > 0 ? "double-counted" : "unaccounted"
      puts ""
      puts "#{YELLOW}⚠  Accounting bug: #{human_size(accounting_error.abs)} #{sign}#{RESET}"
      puts "#{DIM}   Sum of categories (#{human_size(measured)}) ≠ volume apparent total (#{human_size(expected_apparent)}). Fix storage! accounting.#{RESET}"
    end

    print_breakdown = lambda do |title, detail|
      next if detail.empty?
      puts "\n#{BOLD}#{title}:#{RESET}"
      max_path = detail.map { |p, _| p.length }.max
      detail.sort_by { |_, s| -s }.each do |path, size|
        color = size >= 1024**3 * 10 ? RED : size >= 1024**3 ? YELLOW : ""
        puts "  #{path.ljust(max_path)}    #{color}#{human_size(size).rjust(max_size)}#{RESET}"
      end
    end

    print_breakdown.call("Other Users breakdown", other_users_detail)
  end

  def self.inspect!(category)
    case category
    when "homebrew"   then inspect_homebrew!
    when "postgresql" then inspect_postgresql!
    when "reserved"   then inspect_reserved!
    else
      abort "Unknown inspect category: #{category}\nAvailable: #{INSPECT_CATEGORIES.join(", ")}"
    end
  end

  def self.print_inspect_table(entries)
    if entries.empty?
      puts "(nothing to show)"
      return
    end
    max_name = entries.map { |n, _| n.length }.max
    max_size = entries.map { |_, s| human_size(s).length }.max
    total = entries.sum { |_, s| s }
    width = max_name + 4 + max_size

    entries.each do |name, size|
      color = size >= 1024**3 * 10 ? RED : size >= 1024**3 ? YELLOW : ""
      puts "  #{name.ljust(max_name)}    #{color}#{human_size(size).rjust(max_size)}#{RESET}"
    end
    puts "  #{DIM}#{"─" * width}#{RESET}"
    puts "  #{BOLD}#{"Total".ljust(max_name)}    #{human_size(total).rjust(max_size)}#{RESET}"
  end

  # Brew's own var subdirs (not service data, not orphans). `db` holds nested
  # per-formula data dirs like var/db/redis, so it's a category, not orphan.
  HOMEBREW_INTERNAL_VARS = %w[log homebrew cache run lib db].freeze

  def self.inspect_homebrew!
    brew_root = "/opt/homebrew"
    puts "#{BOLD}cleanCache-MacOS — Inspect: Homebrew#{RESET}"
    unless File.directory?(brew_root)
      puts "Homebrew not found at #{brew_root}."
      return
    end
    puts "Sizing #{brew_root}/{Cellar,Caskroom,var}...\n\n"

    # Cellar = formula installations, Caskroom = cask metadata,
    # var/* = brew services data (postgres/mongo/mysql DBs, logs) — real user
    # data, not cache. Surfaced here because it dominates Homebrew's footprint.
    cellar_dir = File.join(brew_root, "Cellar")
    installed = File.directory?(cellar_dir) ? Dir.children(cellar_dir).reject { |n| n.start_with?(".") } : []

    # Each row: [label, size, path, override_color]
    rows = []

    if File.directory?(cellar_dir)
      Dir.children(cellar_dir).each do |name|
        next if name.start_with?(".")
        path = File.join(cellar_dir, name)
        next unless File.directory?(path)
        size = fast_dir_size(path)
        next if size.zero?
        rows << [name, size, nil, nil]
      end
    end

    cask_dir = File.join(brew_root, "Caskroom")
    if File.directory?(cask_dir)
      Dir.children(cask_dir).each do |name|
        next if name.start_with?(".")
        path = File.join(cask_dir, name)
        next unless File.directory?(path)
        size = fast_dir_size(path)
        next if size.zero?
        rows << ["#{name} (cask)", size, nil, nil]
      end
    end

    var_dir = File.join(brew_root, "var")
    if File.directory?(var_dir)
      Dir.children(var_dir).each do |name|
        next if name.start_with?(".")
        path = File.join(var_dir, name)
        next unless File.directory?(path)
        size = fast_dir_size(path)
        next if size.zero?
        # Orphan = data dir left behind after `brew uninstall`. Allow prefix
        # match so var/mongodb pairs with Cellar/mongodb-community.
        orphan = !HOMEBREW_INTERNAL_VARS.include?(name) &&
                 !installed.any? { |f| f == name || f.start_with?("#{name}-") }
        rows << ["#{name} (var)", size, path, orphan ? RED : nil]
      end
    end

    rows.sort_by! { |_, s, _, _| -s }

    if rows.empty?
      puts "(nothing to show)"
      return
    end

    max_name = rows.map { |n, _, _, _| n.length }.max
    max_size = rows.map { |_, s, _, _| human_size(s).length }.max
    max_path = rows.map { |_, _, p, _| p ? p.length : 0 }.max
    total = rows.sum { |_, s, _, _| s }
    width = max_name + 4 + max_size + (max_path > 0 ? 4 + max_path : 0)

    rows.each do |name, size, path, override|
      size_color = override || (size >= 1024**3 * 10 ? RED : size >= 1024**3 ? YELLOW : "")
      name_color = override || ""
      path_str = path ? "    #{override || DIM}#{path}#{RESET}" : ""
      puts "  #{name_color}#{name.ljust(max_name)}#{RESET}    #{size_color}#{human_size(size).rjust(max_size)}#{RESET}#{path_str}"
    end
    puts "  #{DIM}#{"─" * width}#{RESET}"
    puts "  #{BOLD}#{"Total".ljust(max_name)}    #{human_size(total).rjust(max_size)}#{RESET}"

    orphans = rows.count { |_, _, _, o| o == RED }
    if orphans > 0
      puts "#{DIM}#{orphans} var dir(s) in red have no matching installed formula — likely leftover data from `brew uninstall`.#{RESET}"
    end
  end

  # Homebrew Postgres clusters live under /opt/homebrew/var/postgres*; only
  # directories with a PG_VERSION file are real clusters.
  def self.postgresql_clusters
    var_dir = "/opt/homebrew/var"
    return [] unless File.directory?(var_dir)
    Dir.children(var_dir).select { |d| d.start_with?("postgres") }
                         .map { |d| File.join(var_dir, d) }
                         .select { |p| File.directory?(p) && File.file?(File.join(p, "PG_VERSION")) }
                         .sort
  end

  # postmaster.pid layout: pid, data dir, start ts, port, socket dir, host,
  # shmem id, status. The file can be stale (e.g. status "stopping" after a
  # crash) and two clusters defaulting to port 5432 both write 5432, so we
  # verify the pid is alive before trusting the rest.
  def self.postgresql_running_endpoint(cluster_path)
    pidfile = File.join(cluster_path, "postmaster.pid")
    return nil unless File.file?(pidfile)
    lines = File.readlines(pidfile, chomp: true) rescue []
    return nil unless lines.length > 4 && lines[0] =~ /^\d+$/ && lines[3] =~ /^\d+$/
    pid = lines[0].to_i
    alive = (Process.kill(0, pid) rescue nil) == 1
    return nil unless alive
    { port: lines[3], socket_dir: lines[4] }
  end

  def self.psql_for(cluster_name)
    bin = File.join("/opt/homebrew/opt", cluster_name, "bin", "psql")
    File.executable?(bin) ? bin : "psql"
  end

  def self.inspect_postgresql!
    puts "#{BOLD}cleanCache-MacOS — Inspect: PostgreSQL#{RESET}"
    clusters = postgresql_clusters
    if clusters.empty?
      puts "No PostgreSQL clusters found under /opt/homebrew/var."
      return
    end

    clusters.each do |cluster_path|
      cluster_name = File.basename(cluster_path)
      cluster_size = fast_dir_size(cluster_path)
      puts "\n#{BOLD}#{cluster_name}#{RESET}  #{DIM}(#{cluster_path}, #{human_size(cluster_size)})#{RESET}"

      endpoint = postgresql_running_endpoint(cluster_path)
      unless endpoint
        puts "  #{DIM}Cluster not running — skipping (run `brew services start #{cluster_name}` to inspect).#{RESET}"
        next
      end

      psql = psql_for(cluster_name)
      query = "SELECT datname, pg_database_size(datname) FROM pg_database ORDER BY 2 DESC;"
      output = `"#{psql}" -h "#{endpoint[:socket_dir]}" -p #{endpoint[:port]} -d postgres -At -F'|' -c "#{query}" 2>/dev/null`
      unless $?.success? && !output.empty?
        puts "  #{DIM}psql query failed — skipping.#{RESET}"
        next
      end

      entries = []
      output.each_line do |line|
        name, size = line.chomp.split("|", 2)
        entries << [name, size.to_i] if name && size
      end

      if entries.empty?
        puts "  (no databases visible)"
        next
      end

      print_inspect_table(entries)
    end
  end

  def self.inspect_reserved!
    data_root = "/System/Volumes/Data"
    puts "#{BOLD}cleanCache-MacOS — Inspect: Reserved#{RESET}"
    unless File.directory?(data_root)
      puts "#{data_root} not found."
      return
    end
    if Process.uid != 0
      puts "#{YELLOW}⚠  Not running as root. TCC-protected paths (Apple Intelligence models, Spotlight, fseventsd) will undercount — re-run with sudo for accurate sizes.#{RESET}"
    end
    puts "Sizing top-level entries of #{data_root}...\n\n"

    entries = []
    begin
      Dir.children(data_root).each do |child|
        path = File.join(data_root, child)
        next unless File.directory?(path)
        size = fast_dir_size(path)
        next if size.zero?
        entries << [child, size]
      end
    rescue Errno::EPERM, Errno::EACCES
    end

    entries.sort_by! { |_, s| -s }
    print_inspect_table(entries)
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

    if enabled?("postgresql", options)
      section("PostgreSQL") do
        total_freed += clean_postgresql_test_databases.to_i
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
        total_freed += clean_path("Swift Package Manager cache", "~/Library/Caches/org.swift.swiftpm").to_i
        if system("which xcrun > /dev/null 2>&1")
          run_command("xcrun simctl delete unavailable", "xcrun simctl delete unavailable")
          run_command("xcrun simctl runtime delete unused", "xcrun simctl runtime delete unused")
        end
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

    if enabled?("postman", options)
      section("Postman") do
        total_freed += clean_path("Postman cache", "~/Library/Caches/Postman").to_i
        total_freed += clean_path("Postman cache", "~/Library/Caches/com.postmanlabs.mac").to_i
        total_freed += clean_path("Postman IndexedDB", "~/Library/Application Support/Postman/IndexedDB").to_i
        total_freed += clean_path("Postman Cache", "~/Library/Application Support/Postman/Cache").to_i
        total_freed += clean_path("Postman GPUCache", "~/Library/Application Support/Postman/GPUCache").to_i
        total_freed += clean_path("Postman blob_storage", "~/Library/Application Support/Postman/blob_storage").to_i
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
        total_freed += clean_old_chromium_frameworks.to_i
      end
    end

    if enabled?("system", options)
      section("macOS System") do
        total_freed += clean_path("Apple CloudKit cache", "~/Library/Caches/CloudKit").to_i
        total_freed += clean_path("TypeScript server cache", "~/Library/Caches/typescript").to_i
        total_freed += clean_path("User logs", "~/Library/Logs").to_i
        total_freed += clean_old_relocated_items.to_i
        total_freed += clean_old_code_sign_clones.to_i
      end
    end

    puts "\n#{BOLD}Done!#{RESET} Freed approximately #{GREEN}#{human_size(total_freed)}#{RESET} of disk space."
  end
end

options = CleanCache.parse_args(ARGV)
if options[:scan]
  CleanCache.scan!
elsif options[:storage]
  CleanCache.storage!
elsif options[:inspect]
  CleanCache.inspect!(options[:inspect])
elsif options[:force_purge]
  CleanCache.force_purge!
else
  CleanCache.clean!(options)
end
