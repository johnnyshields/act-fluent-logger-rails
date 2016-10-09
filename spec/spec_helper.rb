$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), '..', 'lib'))
$LOAD_PATH.unshift(File.dirname(__FILE__))

require 'active_support'
require 'active_support/deprecation'
require 'active_support/core_ext/module'
require 'active_support/logger' if ActiveSupport::VERSION::STRING >= '4'
require 'active_support/tagged_logging'
require 'shims/rails_3_logging' if ActiveSupport::VERSION::STRING < '4'
require 'yaml'
require 'act-fluent-logger-rails/logger'
