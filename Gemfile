# frozen_string_literal: true

source 'https://rubygems.org'

ruby File.read(File.join(__dir__, '.ruby-version'), chomp: true).delete_prefix('ruby-')

gem 'area'
gem 'dotenv'
gem 'gender_detector'
gem 'i18n', '>= 1'
gem 'nokogiri'
gem 'oauth'
gem 'oauth2'
gem 'pry'
gem 'puma'
gem 'rack-unreloader'
gem 'rake'
gem 'roda'
gem 'roda-route_list'
gem 'rubocop'
gem 'sendgrid-ruby'
gem 'sequel'
gem 'sequel_pg'
gem 'tilt'
gem 'typhoeus'
gem 'unicode_utils'
gem 'zbar'

group :test do
  gem 'capybara-selenium'
  gem 'chromedriver-helper', '~> 2.0'
  gem 'minitest'
  gem 'minitest-capybara'
  gem 'rack-test'
end

group :production do
  gem 'rollbar'
end
