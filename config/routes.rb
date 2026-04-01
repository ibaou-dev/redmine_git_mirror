RedmineApp::Application.routes.draw do
  # Webhook endpoint — public, keyed by token, no authentication
  post 'git_mirror/webhook/:token',
       to:  'git_mirror_webhook#receive',
       as:  'git_mirror_webhook',
       constraints: { token: /[A-Za-z0-9_\-]{20,}/ }

  # Project-scoped mirror config
  scope '/projects/:project_id' do
    resources :git_mirror_configs,
              path:        'git_mirror',
              only:        [:new, :create, :edit, :update, :destroy] do
      member do
        post :trigger_sync
        get  :confirm_destroy
      end
    end

    resources :git_mirror_sync_logs,
              path: 'git_mirror/logs',
              only: [:index, :show]
  end

  # Admin dashboard
  get 'git_mirror_admin', to: 'git_mirror_admin#index', as: 'git_mirror_admin'
end
