# cleanCache-MacOS

A Ruby script that cleans temporary files, caches, and build artifacts on macOS to free up disk space.

## What it cleans

| Category | What gets cleaned |
|---|---|
| **Homebrew** | Outdated downloads, cache, logs |
| **npm** | `_cacache` directory |
| **Yarn** | Global cache |
| **pnpm** | Pruned store |
| **Bun** | Install cache |
| **rbenv** | Ruby build cache |
| **mise** | Runtime cache |
| **Bundler** | Gem cache |
| **pip** | Package cache |
| **CocoaPods** | Pod cache |
| **Carthage** | Build cache |
| **Docker** | Dangling images, stopped containers, dangling build cache |
| **Spotify** | Streaming and persistent cache |
| **Xcode** | DerivedData, iOS DeviceSupport, Simulator caches |
| **Android Studio** | IDE caches, build cache |
| **Gradle** | Build caches, wrapper distributions |
| **Maven** | Local repository |
| **Go** | Module and build cache |
| **Cargo (Rust)** | Registry cache |
| **Composer (PHP)** | Package cache |
| **Project Artifacts** | `node_modules`, `log`, `__pycache__`, `.pytest_cache`, `.sass-cache`, `.parcel-cache`, `.next/cache`, `.nuxt`, `.turbo`, `coverage`, `.angular/cache` |
| **Home Directory** | `.babel.json`, `.node-gyp`, `.webdrivers`, `.cache`, `.dotnet`, `.hawtjni`, stale `.zcompdump` files |
| **Browsers** | Safari, Chrome, Firefox, Edge, Brave, Opera, Opera GX, Vivaldi, Arc |
| **macOS System** | CloudKit, Swift PM, TypeScript caches, `~/Library/Logs` |
## Requirements

- macOS
- Ruby (included with macOS)

## Usage

```sh
git clone https://github.com/your-username/cleanCache-MacOS.git
cd cleanCache-MacOS
./clean_cache.rb                          # clean everything
./clean_cache.rb browsers docker          # clean only specific categories
./clean_cache.rb --exclude projects home  # clean everything except these
./clean_cache.rb --list                   # list available categories
./clean_cache.rb --help                   # show help
```

Available categories: `homebrew`, `npm`, `yarn`, `pnpm`, `bun`, `rbenv`, `mise`, `bundler`, `pip`, `cocoapods`, `carthage`, `docker`, `spotify`, `xcode`, `android-studio`, `gradle`, `maven`, `go`, `cargo`, `composer`, `projects`, `home`, `browsers`, `system`

## How it works

The script iterates through each category and:

1. Runs the tool's built-in cleanup command if available (e.g. `brew cleanup`, `docker system prune`)
2. Removes known cache directories
3. Reports how much space was freed per item
4. Prints a total at the end

Tools that aren't installed are automatically skipped.

## Safety

This script only deletes data that is **automatically recoverable** — caches, build artifacts, and downloaded dependencies that tools will re-fetch on demand. It will never delete anything that requires manual restoration. Some tools may run slower on their next invocation while caches are rebuilt.

## License

MIT
