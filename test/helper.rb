require "xmlsimple"
require 'fileutils'

$test_id = 1

def generate_command header_list_file_name, bridgesupport_file_name, options
  options_to_add = options.map do |k, v|
    if k && v && v.strip.length > 0
      "--#{k} \"#{v}\""
    elsif k
      "--#{k}"
    else
      ""
    end
  end.join " "

<<-S
RUBYLIB='../DSTROOT/System/Library/BridgeSupport/ruby-3.2' \
RUBYOPT='' \
ruby ../gen_bridge_metadata.rb \
--format complete  \
#{options_to_add} \
"#{header_list_file_name}" \
-o '#{bridgesupport_file_name}'
S
end

def gen_bridge_metadata(header_file_name, options = {})
  default_options = {
    #debug: "", # uncomment this option for full debug trace
    cflags: "-Ioutput"
  }
  header_file_include_location = " -I./header -I. -I'.' "
  options = default_options.merge options
  options[:cflags] = " #{header_file_include_location} #{options[:cflags]} "
  output_folder = 'output'
  header_list_file_name = "#{output_folder}/#{header_file_name}-#{$test_id}.txt"
  bridgesupport_file_name = "#{output_folder}/#{ header_file_name }-#{$test_id}.bridgesupport"
  repro_script_file_name = "#{output_folder}/#{ header_file_name }-#{$test_id}.sh"
  puts "\n#{repro_script_file_name}"
  FileUtils.mkdir_p output_folder
  File.write header_list_file_name, header_file_name
  command = generate_command header_list_file_name, bridgesupport_file_name, options
  File.write repro_script_file_name, command
  $test_id += 1
  system "#{ command }"
  hash = XmlSimple.xml_in(open(bridgesupport_file_name))
end
