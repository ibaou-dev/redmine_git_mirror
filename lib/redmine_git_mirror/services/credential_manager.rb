module RedmineGitMirror
  module Services
    # Manages SSH key files and builds git environment variables for authentication.
    #
    # SSH private keys are NEVER stored in the database. They live on the
    # filesystem under tmp/redmine_git_mirror/ssh_keys/ with mode 0600.
    # Only the filename (a UUID) is stored in the DB.
    class CredentialManager
      SSH_KEYS_DIR_NAME = 'redmine_git_mirror/ssh_keys'.freeze

      def initialize(config)
        @config = config
      end

      # Returns a Hash of environment variables to pass to git subprocess.
      # Caller must merge this into the environment for Open3.capture3.
      def git_env
        base = { 'GIT_TERMINAL_PROMPT' => '0' }

        case @config.auth_type
        when 'ssh_key'
          base.merge(ssh_env)
        when 'token'
          {}  # token is embedded in the URL — see authenticated_remote_url
        when 'userpass'
          {}  # credentials embedded in URL — see authenticated_remote_url
        else
          base
        end
      end

      # Returns the remote URL with credentials embedded for HTTPS auth types.
      # For SSH, returns the original remote_url unchanged.
      def authenticated_remote_url
        url = @config.remote_url.to_s

        case @config.auth_type
        when 'token'
          token = @config.access_token.to_s
          return url if token.blank?

          embed_credentials_in_url(url, 'x-access-token', token)
        when 'userpass'
          username = @config.username.to_s
          password = @config.password.to_s
          return url if username.blank?

          embed_credentials_in_url(url, username, password)
        else
          url
        end
      end

      # Write SSH key material to the filesystem.
      # Returns the filename (UUID) that was written.
      def write_ssh_key(key_material)
        raise ArgumentError, 'SSH key material must not be blank' if key_material.blank?

        # Basic safety: reject anything with obvious shell-injection chars in the key payload
        if key_material.include?("\x00")
          raise ArgumentError, 'SSH key material contains null bytes'
        end

        filename = @config.ssh_key_filename.presence || SecureRandom.uuid
        path     = ssh_key_path(filename)

        FileUtils.mkdir_p(ssh_keys_dir, mode: 0o700)
        File.write(path, key_material, perm: 0o600)
        # Enforce permissions regardless of umask
        File.chmod(0o600, path)

        filename
      end

      # Return the absolute filesystem path for the config's SSH key file.
      def ssh_key_path(filename = nil)
        fname = filename || @config.ssh_key_filename
        raise ArgumentError, 'No SSH key filename configured' if fname.blank?

        # Safety: filename must be a UUID (no path separators)
        unless fname.match?(/\A[a-f0-9\-]{36}\z/)
          raise ArgumentError, "Invalid SSH key filename: #{fname}"
        end

        File.join(ssh_keys_dir, fname)
      end

      # Delete the SSH key file from disk.
      def delete_ssh_key
        return unless @config.ssh_key_filename.present?

        path = ssh_key_path
        File.delete(path) if File.exist?(path)
      rescue StandardError => e
        Rails.logger.error "[RedmineGitMirror::CredentialManager] Failed to delete SSH key: #{e.message}"
      end

      # -----------------------------------------------------------------------
      private
      # -----------------------------------------------------------------------

      def ssh_keys_dir
        @ssh_keys_dir ||= File.join(Rails.root, 'tmp', SSH_KEYS_DIR_NAME)
      end

      def ssh_env
        path = ssh_key_path
        unless File.exist?(path)
          raise "SSH key file not found: #{path}. Upload the key before syncing."
        end

        {
          'GIT_TERMINAL_PROMPT' => '0',
          'GIT_SSH_COMMAND'     => "ssh -i #{Shellwords.escape(path)} " \
                                   '-o StrictHostKeyChecking=no ' \
                                   '-o IdentitiesOnly=yes ' \
                                   '-o BatchMode=yes'
        }
      end

      def embed_credentials_in_url(url, username, password)
        uri = URI.parse(url)
        return url unless uri.scheme&.start_with?('http')

        uri.user     = URI.encode_www_form_component(username)
        uri.password = URI.encode_www_form_component(password)
        uri.to_s
      rescue URI::InvalidURIError
        url
      end
    end
  end
end
