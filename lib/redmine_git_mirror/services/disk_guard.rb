module RedmineGitMirror
  module Services
    # Guards against running git operations when disk space is critically low.
    module DiskGuard
      class InsufficientSpaceError < StandardError; end

      # Minimum free bytes required before a fresh clone operation (500 MB)
      MIN_BYTES_FOR_CLONE = 500 * 1024 * 1024

      # Minimum free bytes required before a fetch operation (50 MB)
      MIN_BYTES_FOR_FETCH = 50 * 1024 * 1024

      module_function

      # Checks disk space at `path` (or its parent if it doesn't exist yet).
      # Raises InsufficientSpaceError if available space is below `min_bytes`.
      def check!(path, min_bytes: MIN_BYTES_FOR_CLONE)
        check_path = path.to_s
        # Walk up until we find an existing directory
        check_path = File.dirname(check_path) until Dir.exist?(check_path) || check_path == '/'

        available = available_bytes(check_path)
        if available < min_bytes
          raise InsufficientSpaceError,
                "Insufficient disk space at #{check_path}: " \
                "#{(available / 1024.0 / 1024).round(1)} MB available, " \
                "#{(min_bytes / 1024.0 / 1024).round} MB required"
        end

        available
      end

      def available_bytes(path)
        stat = File.statvfs(path)
        stat.block_size * stat.blocks_available
      rescue NotImplementedError, NoMethodError
        # Fallback for platforms without statvfs (Windows/JRuby/some Linux Ruby builds)
        df_output = `df -k #{Shellwords.escape(path)} 2>/dev/null`.lines.last.to_s
        kb_available = df_output.split[3].to_i
        kb_available * 1024
      end
    end
  end
end
