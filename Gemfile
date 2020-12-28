# A sample Gemfile
source 'https://rubygems.org'

ruby '2.2.2'

gem 'activesupport',    '4.2.3'
gem 'activerecord',     '4.2.3'
gem 'annotate',         '~> 2.6.10'

gem 'settingslogic',    '~> 2.0.9'

gem 'sentry-raven',     '~> 0.13.3'
gem 'metriks',          '~> 0.9.9'

gem 'connection_pool',  '~> 2.2.0'

gem 'rbvmomi',          '~> 1.8.2'
gem 'fog',              '~> 1.36.0'
# gem 'fog-vsphere',      ''

gem 'pg'
gem 'aasm', '~> 4.2.0'
gem 'sidekiq'

gem 'sinatra',          '~> 1.4.6'
gem 'sinatra-contrib',  '~> 1.4.6', require: false # see http://stackoverflow.com/a/20642616/1045752
gem 'rack-contrib',     '~> 1.4.0'
gem 'rack-parser',      '~> 0.6.1', require: 'rack/parser'
gem 'multi_json',       '~> 1.0'

gem 'retryable',        '~> 2.0.2'
gem 'puma',             '~> 3.12'
gem 'carrierwave',      '~> 0.10.0'

group :development do
  # just for cmd, e.g.: rails g model, rails c, rails db
  gem 'rails', '4.2.3', require: false

  gem 'rerun'
  gem 'factory_girl_rails', '~> 4.0'
end

group :development, :test do
  gem 'rspec', '~> 3.3.0'
end

group :test do
  gem 'database_cleaner',   '~> 1.5'
  gem 'factory_girl',       '~> 4.0'
end
