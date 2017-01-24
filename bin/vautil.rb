#!/usr/bin/env ruby

if RUBY_VERSION =~ /^1.8/
  require 'rubygems'
end

BASE_DIR = File.dirname(File.dirname(__FILE__))
$LOAD_PATH << BASE_DIR
$LOAD_PATH << BASE_DIR + "/lib"

require 'vautil'

def usage
  print <<HERE
Usage: vautil.rb <command> [args]
Commands:
  block_international_with_tn <did>
  run_codegen                 <branch_id>
  make_odbc                   <context_name>
  make_odbc_batch             <file>
  detect_fraud
  detect_domestic_fraud
  validate_odbc               <file>
  check_config                [file]
HERE
  exit(1)
end

def main(config_file, command, argument=nil)
  vautil = VAUtil.new(config_file)
  if (argument.nil?)
    vautil.send(command.to_sym)
  else
    vautil.send(command.to_sym, argument)
  end
end

usage if ARGV[0].nil?

if ARGV[0] == '-c'
  config_path = ARGV[1]
  cmd = ARGV[2]
  arg = ARGV[3]
else
  config_path = nil
  cmd = ARGV[0]
  arg = ARGV[1]
end

main(config_path, cmd, arg)
