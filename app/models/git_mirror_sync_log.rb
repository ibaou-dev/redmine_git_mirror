class GitMirrorSyncLog < ActiveRecord::Base
  TRIGGER_TYPES = %w[scheduler webhook manual].freeze
  STATUSES      = %w[running success failed].freeze

  belongs_to :git_mirror_config

  validates :git_mirror_config_id, presence: true
  validates :trigger_type, inclusion: { in: TRIGGER_TYPES }
  validates :status,       inclusion: { in: STATUSES }
  validates :started_at,   presence: true

  scope :recent,    -> { order(started_at: :desc) }
  scope :failed,    -> { where(status: 'failed') }
  scope :success,   -> { where(status: 'success') }
  scope :for_config, ->(config_id) { where(git_mirror_config_id: config_id) }

  def duration_seconds
    return nil if completed_at.nil? || started_at.nil?

    (completed_at - started_at).round
  end

  def complete!(status:, commits_fetched: 0, output: nil, error_message: nil)
    update!(
      status:          status,
      completed_at:    Time.current,
      commits_fetched: commits_fetched,
      output:          output&.last(10_240),  # cap at 10 KB
      error_message:   error_message
    )
  end
end
