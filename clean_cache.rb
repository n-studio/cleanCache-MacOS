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

  CATEGORIES = %w[
    homebrew npm yarn pnpm bun rbenv mise bundler pip cocoapods carthage
    docker spotify gaming xcode android-studio gradle maven go cargo
    composer postman projects home browsers system
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

      opts.on("--storage", "Show disk storage breakdown by category") do
        options[:storage] = true
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

    # 1. Applications: /Applications + ~/Library (minus iOS backups, Developer, Android, Docker) + app dotdirs (minus .docker) + Homebrew
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
    applications = app_size + app_lib + app_dots + homebrew_size
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
      ["Applications",     applications],
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

    # APFS clonefile(2) lets files share blocks, so the apparent total
    # (what du reports per path) exceeds actual blocks on disk (what df
    # reports). Attribute the savings to System Cache: macOS clones are
    # concentrated in /private (cryptex, dyld_shared_cache, install caches).
    # After this adjustment, sum(categories) == used_disk.
    clone_savings = expected_apparent - used_disk
    if clone_savings > 0
      results = results.map do |name, size|
        name == "System Cache" ? [name, [size - clone_savings, 0].max] : [name, size]
      end
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

    puts "#{DIM}#{"─" * total_width}#{RESET}"
    puts "#{BOLD}#{"Used".ljust(max_name)}    #{human_size(used_disk).rjust(max_size)}#{RESET}"
    puts "#{"Available".ljust(max_name)}    #{GREEN}#{human_size(avail_disk).rjust(max_size)}#{RESET}"
    puts "#{BOLD}#{"Capacity".ljust(max_name)}    #{human_size(total_disk).rjust(max_size)}#{RESET}"
    if clone_savings > SCAN_MIN_SIZE
      puts "#{DIM}System Cache reduced by #{human_size(clone_savings)} of APFS clone-shared blocks (cryptex / dyld / install caches).#{RESET}"
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
      end
    end

    if enabled?("system", options)
      section("macOS System") do
        total_freed += clean_path("Apple CloudKit cache", "~/Library/Caches/CloudKit").to_i
        total_freed += clean_path("TypeScript server cache", "~/Library/Caches/typescript").to_i
        total_freed += clean_path("User logs", "~/Library/Logs").to_i
        total_freed += clean_old_relocated_items.to_i
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
else
  CleanCache.clean!(options)
end
