require 'openssl'

module RedmineGitMirror
  module Services
    # Verifies incoming webhook requests from GitHub, GitLab, and Bitbucket.
    #
    # Verification strategy:
    #   GitHub / Bitbucket:  HMAC-SHA256 over raw request body,
    #                         header: X-Hub-Signature-256
    #   GitLab:              Simple token comparison,
    #                         header: X-Gitlab-Token
    #
    # Replay attack prevention:
    #   Each delivery carries a UUID header. Previously seen UUIDs within
    #   the last 10 minutes are rejected.
    class WebhookVerifier
      class VerificationError < StandardError; end
      class ReplayAttackError  < VerificationError; end
      class InvalidSignatureError < VerificationError; end
      class MissingSecretError    < VerificationError; end

      # Header names
      GITHUB_SIGNATURE_HEADER   = 'X-Hub-Signature-256'
      GITHUB_DELIVERY_HEADER    = 'X-GitHub-Delivery'
      GITHUB_EVENT_HEADER       = 'X-GitHub-Event'

      GITLAB_TOKEN_HEADER       = 'X-Gitlab-Token'
      GITLAB_EVENT_HEADER       = 'X-Gitlab-Event'
      GITLAB_DELIVERY_HEADER    = 'X-Gitlab-Event-UUID'

      BITBUCKET_SIGNATURE_HEADER = 'X-Hub-Signature'
      BITBUCKET_EVENT_HEADER     = 'X-Event-Key'
      BITBUCKET_DELIVERY_HEADER  = 'X-Request-UUID'

      def initialize(config, request)
        @config  = config
        @request = request
      end

      # Detects the platform, verifies signature/token, checks for replay attacks.
      # Raises a VerificationError subclass on any failure.
      # Returns the detected platform as a Symbol: :github, :gitlab, :bitbucket, :unknown
      def verify!
        check_replay_attack!

        platform = detect_platform
        case platform
        when :github
          verify_github!
        when :gitlab
          verify_gitlab!
        when :bitbucket
          verify_bitbucket!
        else
          # Unknown platform — if a secret is configured, we can't verify, so reject
          if @config.webhook_secret.present?
            raise InvalidSignatureError,
                  'Cannot verify webhook: unrecognized platform headers. ' \
                  'Remove webhook secret or use a supported provider.'
          end
          # No secret and unknown platform — allow (webhook_enabled acts as the gate)
        end

        platform
      end

      # Returns the delivery UUID from request headers (nil if not present)
      def delivery_uuid
        @delivery_uuid ||= begin
          header_value(GITHUB_DELIVERY_HEADER) ||
            header_value(GITLAB_DELIVERY_HEADER) ||
            header_value(BITBUCKET_DELIVERY_HEADER)
        end
      end

      # -----------------------------------------------------------------------
      private
      # -----------------------------------------------------------------------

      def detect_platform
        return :github    if header_value(GITHUB_EVENT_HEADER).present?
        return :gitlab    if header_value(GITLAB_EVENT_HEADER).present?
        return :bitbucket if header_value(BITBUCKET_EVENT_HEADER).present?

        :unknown
      end

      def check_replay_attack!
        return unless delivery_uuid.present?
        return unless GitMirrorWebhookDelivery.seen?(delivery_uuid)

        raise ReplayAttackError, "Duplicate webhook delivery: #{delivery_uuid}"
      end

      def verify_github!
        signature = header_value(GITHUB_SIGNATURE_HEADER)
        return unless @config.webhook_secret.present? || signature.present?

        if @config.webhook_secret.blank?
          raise MissingSecretError,
                'GitHub webhook signature present but no secret configured. ' \
                'Configure a webhook secret in Redmine to verify signatures.'
        end

        unless signature.present?
          raise InvalidSignatureError, 'Missing X-Hub-Signature-256 header'
        end

        expected = "sha256=#{hmac_sha256(@config.webhook_secret, raw_body)}"
        unless ActiveSupport::SecurityUtils.secure_compare(expected, signature)
          raise InvalidSignatureError, 'GitHub webhook signature mismatch'
        end
      end

      def verify_gitlab!
        token = header_value(GITLAB_TOKEN_HEADER)

        if @config.webhook_secret.present?
          unless token.present?
            raise InvalidSignatureError, 'Missing X-Gitlab-Token header'
          end

          unless ActiveSupport::SecurityUtils.secure_compare(@config.webhook_secret, token)
            raise InvalidSignatureError, 'GitLab webhook token mismatch'
          end
        end
      end

      def verify_bitbucket!
        signature = header_value(BITBUCKET_SIGNATURE_HEADER)
        return unless @config.webhook_secret.present? || signature.present?

        if @config.webhook_secret.blank?
          raise MissingSecretError,
                'Bitbucket webhook signature present but no secret configured.'
        end

        unless signature.present?
          raise InvalidSignatureError, 'Missing X-Hub-Signature header'
        end

        # Bitbucket uses sha256= prefix like GitHub
        alg, provided_hex = signature.split('=', 2)
        computed_hex = hmac_sha256(@config.webhook_secret, raw_body)

        unless alg == 'sha256' &&
               ActiveSupport::SecurityUtils.secure_compare(computed_hex, provided_hex.to_s)
          raise InvalidSignatureError, 'Bitbucket webhook signature mismatch'
        end
      end

      def hmac_sha256(secret, body)
        OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'), secret, body)
      end

      def raw_body
        @raw_body ||= begin
          @request.body.rewind
          @request.body.read
        ensure
          @request.body.rewind
        end
      end

      def header_value(name)
        # Rack header format: HTTP_X_HUB_SIGNATURE_256
        rack_key = "HTTP_#{name.upcase.tr('-', '_')}"
        @request.env[rack_key].presence
      end
    end
  end
end
