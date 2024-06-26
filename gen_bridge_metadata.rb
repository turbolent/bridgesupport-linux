#!/usr/bin/ruby
# -*- coding: utf-8; mode: ruby; indent-tabs-mode: true; ruby-indent-level: 4; tab-width: 8 -*-
# Copyright (c) 2006-2012, Apple Inc. All rights reserved.
# Copyright (c) 2005-2006 FUJIMOTO Hisakuni
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1.  Redistributions of source code must retain the above copyright
#     notice, this list of conditions and the following disclaimer.
# 2.  Redistributions in binary form must reproduce the above copyright
#     notice, this list of conditions and the following disclaimer in the
#     documentation and/or other materials provided with the distribution.
# 3.  Neither the name of Apple Inc. ("Apple") nor the names of
#     its contributors may be used to endorse or promote products derived
#     from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY APPLE AND ITS CONTRIBUTORS "AS IS" AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL APPLE OR ITS CONTRIBUTORS BE LIABLE FOR
# ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
# STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
# IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

# If we have a <ROOT>/System/Library/BridgeSupport/ruby-{version} path in
# the module search path, then set $slb to <ROOT>/System/Library/BridgeSupport.
# Otherwise, if this script is called as <ROOT>/usr/bin/gen_bridge_metadata,
# then set $slb to <ROOT>/System/Library/BridgeSupport.
$slb = $_slb_ = File.expand_path(File.join(__FILE__, '../../../System/Library/BridgeSupport'))
_slbr_ = "#{$slb}/ruby-#{RUBY_VERSION.sub(/^(\d+\.\d+)(\..*)?$/, '\1')}"
$:.unshift(_slbr_) unless $:.any? do |p|
    if %r{#{_slbr_}$} =~ p
	$slb = File.dirname(p)
	true
    end
end
if $slb == $_slb_
    rel = $0.dup
    if rel.sub!(%r{/usr/bin/gen_bridge_metadata$}, '') and !rel.empty?
	$slb = "#{rel}/#{$_slb_}"
    end
end

require 'rexml/document'
require 'fileutils'
require 'optparse'
require 'tmpdir'
require 'pathname'
require 'ostruct'
require 'shellwords'
require 'bridgesupportparser'

class OCHeaderAnalyzer
    CPP = ['/usr/bin/cpp-4.2', '/usr/bin/cpp-4.0', '/usr/bin/cpp'].find { |x| File.exist?(x) }
    raise "Can't find cpp: have you installed Xcode and the command-line tools?" if CPP.nil?
    CPPFLAGS = ""
    CPPFLAGS << " -D__GNUC__" unless /^cpp-4/.match(File.basename(CPP))

    def self.data(data)
	new(data)
    end

    def self.path(path, fails_on_error=true, do_64=false, flags='')
	complete, filtered = OCHeaderAnalyzer.do_cpp(path, fails_on_error, do_64, flags)
	new(filtered, complete, path)
    end

    def initialize(data, complete_data=nil, path=nil)
	@externname = 'extern'
	@cpp_result = data
	@complete_cpp_result = complete_data
	@path = path
    end

    # Get the list of C enumerations, as a Hash object (keys are the enumeration
    # names and values are their values.
    def enums
	if @enums.nil?
	    re = /\benum\b\s*(\w+\s+)?\{([^}]*)\}/
	    @enums = {}
	    @cpp_result.scan(re).each do |m|
		m[1].split(',').map do |i|
		    name, val = i.split('=', 2).map { |x| x.strip }
		    @enums[name] = val unless name.empty? or name[0] == ?#
		end
	    end
	end
	@enums
    end

    def file_content
	if @file_content.nil?
	    @file_content = File.read(@path)
	    # This is very naive, and won't work with embedded comments, but it
	    # should be enough for now.
	    @file_content.gsub!(%r{/\*([^*]+)\*/}, '')
	    @file_content.gsub!(%r{//.+$}, '')
	end
	@file_content
    end

    # Get the list of `#define KEY VAL' macros, as an Hash object.
    def defines
	if @defines.nil?
	    re = /#define\s+([^\s]+)\s+(\([^)]+\)|[^\s]+)\s*$/
	    @defines = {}
	    file_content.scan(re).each do |m|
		next unless !m[0].include?('(') and m[1] != '\\'
		@defines[m[0]] = m[1]
	    end
	end
	@defines
    end

    # Get the list of C structure names, as an Array.
    def struct_names
	re = /typedef\s+struct\s*\w*\s*((\w+)|\{([^{}]*(\{[^}]+\})?)*\}\s*([^\s]+))\s*(__attribute__\(.+\))?\s*;/ # Ouch...
	@struct_names ||= @cpp_result.scan(re).map { |m|
	    a = m.compact
	    a.pop if /^__attribute__/.match(a.last)
	    a.last
	}.flatten
    end

    # Get the list of CoreFoundation types, as an Array.
    def cftype_names
	re = /typedef\s+(const\s+)?struct\s*\w+\s*\*\s*([^\s]+Ref)\s*;/
	@cftype_names ||= @cpp_result.scan(re).map { |m| m.compact[-1] }.flatten
    end

    # Get the list of function pointer types, as an Hash object (keys are the
    # type names and values are their C declaration.
    def function_pointer_types
	unless @func_ptr_types
	    @func_ptr_types = {}
	    re = /typedef\s+([\w\s]+)\s*\(\s*\*\s*(\w+)\s*\)\s*\(([^)]*)\)\s*;/
	    data = @cpp_result.scan(re)
	    re = /typedef\s+([\w\s]+)\s*\(([^)]+)\)\s*;/
	    data |= @cpp_result.scan(re).map do |m|
		ary = m[0].split(/(\w+)$/)
		ary[1] << ' *'
		ary << m[1]
		ary
	    end
	    data.each do |m|
		name = m[1]
		args = m[2].split(',').map do |x|
		    x.strip!
		    if x.include?(' ')
			ptr = x.sub!(/\[\]\s*$/, '')
			x = x.sub(/\w+\s*$/, '').strip
			ptr ? x + '*' : x
		    else
			x
		    end
		end
		type = "#{m[0]}(*)(#{args.join(', ')})"
		@func_ptr_types[name] = type
	    end
	end
	@func_ptr_types
    end

    def typedefs
	if @typedefs.nil?
	    re = /^\s*typedef\s+(.+)\s+(\w+)\s*;$/
	    @typedefs = {}
	    data = (@complete_cpp_result or @cpp_result)
	    data.scan(re).each { |m| @typedefs[m[1]] = m[0] }
	end
	@typedefs
    end

    def externs
	re = /^\s*#{@externname}\s+\b(.*)\s*;.*$/
	@externs ||= @cpp_result.scan(re).map { |m| m[0].strip }
    end

    def constants
	@constants ||= externs.map { |i| constant?(i, true) }.flatten.compact
    end

    def functions(inline=false)
	if inline
	    return @inline_functions if @inline_functions
	    inline_func_re = /(inline|__inline__)\s+((__attribute__\(\([^)]*\)\)\s+)?([\w\s\*<>]+)\s*\(([^)]*)\)\s*)\{/
	    res = @cpp_result.scan(inline_func_re)
	    res.each { |x| x.delete_at(0); x.delete_at(1) }
	else
	    return @functions if @functions
	    skip_inline_re = /(static)?\s(inline|__inline__)[^{;]+(;|\{([^{}]*(\{[^}]+\})?)*\})\s*/
	    skip_attributes_re = /__attribute__\((\([^()]*(\([^()]*\)|\))+)+\)/
	    func_re = /(^([\w\s\*<>]+)\s*\(([^)]*)\)\s*);/
	    res = @cpp_result.gsub(skip_inline_re, '').gsub(skip_attributes_re, '').scan(func_re)
	end
	funcs = res.map do |m|
	    orig, base, args = m
	    base.sub!(/^.*extern\s+/, '')
	    func = constant?(base)
	    if func
		args = args.strip.split(',').map { |i| constant?(i) }
		next if args.any? { |x| x.nil? }
		args = [] if args.size == 1 and args[0].rettype == 'void'
		FuncInfo.new(func, args, orig, inline)
	    end
	end.compact
	if inline
	    @inline_functions = funcs
	else
	    @functions = funcs
	end
	funcs
    end

    def informal_protocols
	self.ocmethods # to generate @inf_protocols
	@inf_protocols
    end

    def ocmethods
	if @ocmethods.nil?
	    @inf_protocols ||= {}
	    interface_re = /^@(interface|protocol)\s+(\w+)\s*([(<][^)>]+[)>])?/
	    end_re = /^@end/
	    body_re = /^\s*[-+]\s*(\([^)]+\))?\s*([^:\s;]+)/
	    args_re = /\w+\s*:/
	    prop_re = /^@property\s*(\([^)]+\))?\s*([^;]+);$/
	    current_interface = current_category = nil
	    @ocmethods = {}
	    i = 0
	    @cpp_result.each_line do |line|
		size = line.size
		line.strip!
		if md = interface_re.match(line)
		    current_interface = md[1] == 'protocol' ? 'NSObject' : md[2]
		    current_category = md[3].delete('()<>').strip if md[3]
		elsif end_re.match(line)
		    current_interface = current_category = nil
		elsif current_interface and md = prop_re.match(line)
		    # Parsing Objective-C 2.0 properties.
		    if (a = md[2].split(/\s/)).length >= 2 \
		    and /^\w+$/.match(name = a[-1]) \
		    and (type = a[0..-2].join(' ')).index(',').nil?
			getter, setter = name, "set#{name[0].chr.upcase + name[1..-1]}"
			readonly = false
			if attributes = md[1]
			    if md = /getter\s*=\s*(\w+)/.match(attributes)
				getter = md[1]
			    end
			    if md = /setter\s*=\s*(\w+)/.match(attributes)
				setter = md[1]
			    end
			    readonly = true if attributes.index('readonly')
			end
			typeinfo = VarInfo.new(type, '', '')
			methods = (@ocmethods[current_interface] ||= [])
			methods << MethodInfo.new(typeinfo, getter, false, [], line)
			unless readonly
			    methods << MethodInfo.new(VarInfo.new('void', '', ''), setter + ':', false, [typeinfo], line)
			end
		    end
		elsif current_interface and (line[0] == ?+ or line[0] == ?-)
		    mtype = line[0]
		    data = @cpp_result[i..-1]
		    body_md = body_re.match(data)
		    next if body_md.nil?
		    rettype = body_md[1] ? body_md[1].delete('()') : 'id'
		    retval = VarInfo.new(rettype, '', '')
		    args = []
		    selector = ''
		    data = data[0..data.index(';')]
		    args_data = []
		    data.scan(args_re) { |x| args_data << [$`, x.delete(' '), $'] }
		    variadic = false
		    args_data.each_with_index do |ary, n|
			before, argname, argtype = ary
			arg_nameless = (n > 0 and /\)\s*$/.match(before))
			argname = ':' if arg_nameless
			realargname = nil
			if n < args_data.length - 1
			    argtype.sub!(args_data[n + 1][2], '')
			    if arg_nameless
				argtype.sub!(/(\w+\s*)?\w+\s*:\s*$/, '')
			    else
				unless argtype.sub!(/(\w+)\s+\w+\s*:\s*$/) { |s| realargname = $1; '' }
				    # maybe the next argument is nameless
				    argtype.sub!(/\w+\s*:\s*$/, '')
				end
			    end
		     else
			    argtype.sub!(/\s+__attribute__\(\(.+\)\)/, '')
			    if arg_nameless
				argtype.sub!(/\w+\s*;$/, '')
			    else
				unless argtype.sub!(/(\w+)\s*;$/) { |s| realargname = $1; '' }
				    variadic = argtype.sub!(/,\s*\.\.\.\s*;/, '') != nil
				    argtype.sub!(/\w+\s*$/, '') if variadic
				end
			    end
			end
			selector << argname
			realargname ||= argname.sub(/:/, '')
			argtype = 'id' if argtype.strip.empty?
			args << VarInfo.new(argtype, realargname, '') unless argtype.empty?
		    end
		    selector = body_md[2] if selector.empty?
		    args << VarInfo.new('...', 'vararg', '') if variadic
		    method = MethodInfo.new(retval, selector, line[0] == ?+, args, data)
		    if current_category and current_interface == 'NSObject'
			(@inf_protocols[current_category] ||= []) << method
		    end
		    (@ocmethods[current_interface] ||= []) << method
		end
		i += size
	    end
	end
	return @ocmethods
    end

    #######
    private
    #######

    def constant?(str, multi=false)
	str.strip!
	return nil if str.empty?
	if str == '...'
	    VarInfo.new('...', '...', str)
	else
	    str << " dummy" if str[-1].chr == '*' or str.index(/\s/).nil?
	    tokens = multi ? str.split(',') : [str]
	    part = tokens.first
	    part.sub!(/\s*__attribute__\(.+\)\s*$/, '')
	    re = /^([^()]*)\b(\w+)\b\s*(\[[^\]]*\])*$/
	    m = re.match(part)
	    if m
		return nil if m[1].split(/\s+/).any? { |x| ['end', 'typedef'].include?(x) }
		m = m.to_a[1..-1].compact.map { |i| i.strip }
		m[0] += m[2] if m.size == 3
		m[0] = 'void' if m[1] == 'void'
		m[0] = m.join(' ') if m[0] == 'const'
		var = begin
		    VarInfo.new(m[0], m[1], part)
		rescue
		    return nil
		end
		if tokens.size > 1
		    [var, *tokens[1..-1].map { |x| constant?(m[0] + x.strip.sub(/^\*+/, '')) }]
		else
		    var
		end
	    end
	end
    end

    def self.do_cpp(path, fails_on_error=true, do_64=false, flags='')
	f_on = false
	err_file = '/tmp/.cpp.err'
	cpp_line = "#{CPP} #{CPPFLAGS} #{flags} #{do_64 ? '-D__LP64__' : ''} \"#{path}\" 2>#{err_file}"
	complete_result = `#{cpp_line}`
	if $?.to_i != 0 and fails_on_error
	    $stderr.puts File.read(err_file)
	    File.unlink(err_file)
	    raise "#{CPP} returned #{$?.to_int/256} exit status\nline was: #{cpp_line}"
	end
	result = complete_result.select { |s|
	    # First pass to only grab non-empty lines and the pre-processed lines
	    # only from the target header (and not the entire pre-processing result).
	    next if s.strip.empty?
	    m = %r{^#\s*\d+\s+"([^"]+)"}.match(s)
	    f_on = (File.basename(m[1]) == File.basename(path)) if m
	    f_on
	}.select { |s|
	    # Second pass to ignore all pro-processor comments that were left.
	    /^#/.match(s) == nil
	}.join
	File.unlink(err_file)
	return [complete_result, result]
    end

    class VarInfo
	attr_reader :rettype, :stripped_rettype, :name, :orig
	attr_accessor :octype

	def initialize(type, name, orig)
	    @rettype = type
	    @name = name
	    @orig = orig
	    @rettype.gsub!( /\[[^\]]*\]/, '*' )
	    t = type.gsub(/\b(__)?const\b/,'')
	    t.gsub!(/<[^>]*>/, '')
	    t.gsub!(/\b(in|out|inout|oneway|const)\b/, '')
	    t.gsub!(/\b__private_extern__\b/, '')

	    re = /^\s*\(\s*/
	    if re.match(t)
		parenAtBeginning = 1
	    end

	    t.gsub!(/^\s*\(?\s*/, '')

	    if parenAtBeginning
		t.gsub!(/\s*\)?\s*$/, '')
	    else
		t.gsub!(/\s*$/, '')
	    end

	    t.gsub!(/\n/, ' ')
	    raise "empty type (was '#{type}')" if t.empty?
	    @stripped_rettype = t
	end

	def function_pointer?(func_ptr_types)
	    type = (func_ptr_types[@stripped_rettype] or @stripped_rettype)
	    @function_pointer ||= FuncPointerInfo.new_from_type(type)
	end

	def <=>(x)
	    self.name <=> x.name
	end

	def hash
	    @name.hash
	end

	def eql?(o)
	    @name == o.name
	end
    end

    class FuncInfo < VarInfo
	attr_reader :args, :argc

	def initialize(func, args, orig, inline=false)
	    super(func.rettype, func.name, orig)
	    @args = args
	    @argc = @args.size
	    if @args[-1] && @args[-1].rettype == '...'
		@argc -= 1
		@variadic = true
		@args.pop
	    end
	    @inline = inline
	    self
	end

	def variadic?
	    @variadic
	end

	def inline?
	    @inline
	end
    end

    class FuncPointerInfo < FuncInfo
	def self.new_from_type(type)
	    @cache ||= {}
	    info = @cache[type]
	    return info if info

	    tokens = type.split(/\(\*\)/)
	    return nil if tokens.size != 2

	    rettype = tokens.first.strip
	    rest = tokens.last.sub(/^\s*\(\s*/, '').sub(/\s*\)\s*$/, '')
	    argtypes = rest.split(/,/).map { |x| x.strip }

	    @cache[type] = self.new(rettype, argtypes, type)
	end

	def initialize(rettype, argtypes, orig)
	    args = argtypes.map { |x| VarInfo.new(x, '', '') }
	    super(VarInfo.new(rettype, '', ''), args, orig)
	end
    end

    class MethodInfo < FuncInfo
	attr_reader :selector

	def initialize(method, selector, is_class, args, orig)
	    super(method, args, orig)
	    @selector, @is_class = selector, is_class
	    self
	end

	def class_method?
	    @is_class
	end

	def <=>(o)
	    @selector <=> o.selector
	end

	def hash
	    @selector.hash
	end

	def eql?(o)
	    @selector == o.selector
	end
    end
end

# class to print xml with attributes in a fixed order, so that diff-ing
# .bridgesupport files is more meaningful.  From:
#     http://stackoverflow.com/questions/574724/rexml-preserve-attributes-order
class OrderedAttributes < REXML::Formatters::Pretty
    def write_element(elm, out)
        att = elm.attributes

        class <<att
            alias _each_attribute each_attribute

            def each_attribute(&b)
                to_enum(:_each_attribute).sort_by {|x| x.name}.each(&b)
            end
        end

        super(elm, out)
    end
end

class BridgeSupportGenerator
    VERSION = '1.0'

    ARCH = 'i386'
    ARCH64 = 'x86_64'
    FORMATS = ['final', 'exceptions-template', 'dylib', 'complete']
    FORMAT_FINAL, FORMAT_TEMPLATE, FORMAT_DYLIB, FORMAT_COMPLETE = FORMATS

    attr_accessor :headers, :generate_format, :private, :frameworks,
	:exception_paths, :compiler_flags, :enable_32, :enable_64, :out_file,
	:emulate_ppc, :install_name

    attr_reader :resolved_structs, :resolved_cftypes, :resolved_enums,
	:types_encoding, :defines, :resolved_inf_protocols_encoding

    OAH_TRANSLATE = '/usr/libexec/oah/translate'

    def initialize
	@parser = nil
	@headers = []
	@imports = []
	@incdirs = []
	@exception_paths = []
	@out_file = nil
	@install_name = nil
	@generate_format = FORMAT_FINAL
	@private = false
	@compiler_flags = nil
	@frameworks = []
	@enable_32 = false
	@enable_64 = false
	@emulate_ppc = false # PPC support is disabled since SnowLeopard
     end

#    def duplicate
#	g = BridgeSupportGenerator.new
#	g.headers = @headers
#	g.exception_paths = @exception_paths
#	g.out_file = @out_file
#	g.generate_format = @generate_format
#	g.private = @private
#	g.compiler_flags = @compiler_flags
#	g.frameworks = @frameworks
#	g.enable_64 = @enable_64
#	g.emulate_ppc = @emulate_ppc
#	return g
#    end

    def add_header(path)
	h = (Pathname.new(path).absolute? || File.exist?(path)) ? File.basename(path) : path
	@headers << path
	@imports << h
	@import_directive ||= ''
	@import_directive << "\n#include <#{h}>"
    end

    # Encodes the 4 include path pieces into a single string.
    # "group" should be 'A', 'Q' or 'S' for Angled, Quoted or System.
    # "isUserSupplied" and "isFramework" are booleans
    def encode_includes(path, group, isUserSupplied, isFramework)
	group + (isUserSupplied ? 'T' : 'F') + (isFramework ? 'T' : 'F') + path
    end

    def _parse(args, arch, ignore_merge_errors = false)
	bool_sel_types = []
	@all_sel_types.each_index { |i| bool_sel_types[i] = @all_sel_types[i].gsub(/\b(?:BOOL|Boolean)\b/, 'bool') }
	bool_types = []
	@method_exception_types.each_index { |i| bool_types[i] = @method_exception_types[i].gsub(/\b(?:BOOL|Boolean)\b/, 'bool') }

	parser = Bridgesupportparser::Parser.new(args.imports, @headers, bool_sel_types, bool_types, args.defines, args.incdirs, args.defaultincs, args.sysroot)

	case @generate_format
	when FORMAT_DYLIB
	    parser.only_parse_class(Bridgesupportparser::AFunction)
	end

	target_triple = "x86_64-linux-gnu"
	$stderr.puts "### _parse(\"#{target_triple}\")" if $DEBUG
	parser.parse(target_triple)
	@sel_types = {}
	@all_sel_types.each_index do |i|
	    t = parser.special_method_encodings[i]
	    raise "No sel_of_type corresponding to #{@all_sel_types[i]}" if t.nil?
	    @sel_types[@all_sel_types[i]] = t
	end
	@types = {}
	@method_exception_types.each_index do |i|
	    t = parser.special_type_encodings[i]
	    raise "No type corresponding to #{@method_exception_types[i]}" if t.nil?
	    @types[@method_exception_types[i]] = t
	end

	# structs
	@structs.each do |name, ary|
	    s = parser.all_structs[name]
	    raise "No struct corresponding to #{name}" if s.nil?
	    s[:opaque] = true if s && ary[0]
	end
	# Note that struct names (k below) may either be "struct xxx" or just
	# "xxx" if due to a typedef.  Thus, we need to use the actual name
	# (v.name below) if we want to test for a leading underscore.
	parser.all_structs.delete_if { |k, v| v.name[0] == ?_ }

	# cftypes
	@cftypes.each do |name, ary|
	    c = parser.all_cftypes[name]
	    if c.nil?
		$stderr.puts "No cftype \"#{name}\" to apply exceptions"
	    else
		c[:gettypeid_func] = ary[0] unless ary[0].nil?
		c[:_ignore_tollfree] = true if ary[1] == 'true'
	    end
	end
	add_tollfree(parser)

	# If a cftype doesn't have either tollfree or a gettypeid function,
	# it probably an opaque; convert it.
	cfdel = []
	parser.all_cftypes.each do |name, cf|
	    if cf.tollfree.nil? and cf.gettypeid_func.nil?
		cfdel << name
		type = cf.type || "^{#{name}=}"
		parser.all_opaques[name] = Bridgesupportparser::OpaqueInfo.new(parser, name, type)
	    end
	end
	cfdel.each { |c| parser.all_cftypes.delete(c) }

	# opaques
	@opaques_to_ignore.each { |o| parser.all_opaques.delete(o) }
	@opaques.each do |name, type|
	    next if type.nil?
	    parser.all_structs.delete(name)
	    parser.all_opaques[name] = Bridgesupportparser::OpaqueInfo.new(parser, name, type)
	end

	#enums
	parser.all_enums.delete_if { |k, v| k[0] == ?_ }

	# vars
	parser.all_vars.delete_if { |k, v| k[0] == ?_ }

	# macrostrings
	parser.all_macrostrings.delete_if do |k, v|
	    next true if k[0] == ?_
	    @ignored_defines_regexps.any? { |re| re.match(k) }
	end

	# macronumbers (eventually merged with enums)
	parser.all_macronumbers.delete_if do |k, v|
	    next true if k[0] == ?_
	    @ignored_defines_regexps.any? { |re| re.match(k) }
	end

	# evaluate mumeric macros that call functions
	add_numberfunccall(parser)

	# enums
	parser.all_enums.delete_if { |k, v| k[0] == ?_ }

	# funcs and func_aliases
	keepfunc = {}
	parser.all_func_aliases.each_value { |v| keepfunc[v.original] = true }
	parser.all_funcs.delete_if { |k, v| !keepfunc[k] && k[0] == ?_ }

	# Merge with exceptions.
	@exceptions.each { |x| merge_with_exceptions(parser, x, ignore_merge_errors) }
	parser
    end
    protected :_parse

    # parse cc flags, and return defines, include directories, include files
    # and the sysroot.  For clang, system directories get sysroot applied,'
    # but for gcc, -isystem directories don't get sysroot applied.  So we
    # collect -isystem directories separately, and combined them with the
    # regular incdirs directories (so they are in the Angled group, but follow
    # all -I and -F directories.
    def parse_cc_args(args)
	defines = []
	incdirs = []
	incsys = []
	includes = []
	sysroot = ENV['SDKROOT'] || '/'
	words = Shellwords.shellwords(args)
	until words.empty?
	    o = words.shift
	    case o
	    when o.sub!(/^-D/, '') then defines << (o.empty? ? words.shift : o)
	    when o.sub!(/^-I/, '') then incdirs << encode_includes(o.empty? ? words.shift : o, 'A', false, true)
	    when o.sub!(/^-F/, '') then incdirs << encode_includes(o.empty? ? words.shift : o, 'A', true, true)
	    when o.sub!(/^--sysroot=/, '') then sysroot = o
	    when '-isystem' then incsys << encode_includes(words.shift, 'A', true, false)
	    when '-iquote' then incdirs << encode_includes(words.shift, 'Q', true, false)
	    when '-isysroot' then sysroot = words.shift
	    when '-include' then includes << words.shift
	    end
	end
	return defines, incdirs + incsys, includes, sysroot
    end
    protected :parse_cc_args

    def parse(enable_32, enable_64, compiler_flags_64 = nil)
	defines = []
	incdirs = []
	includes = []
	sysroot = ENV['SDKROOT'] || '/'
	unless compiler_flags.nil?
	    defines, incdirs, includes, sysroot = parse_cc_args(compiler_flags)
	end
	defaultincs = []
	IO.popen("cc -print-search-dirs") do |io|
	    io.each do |line|
		if m = line.chomp.match(/^libraries: =(.*)/)
		    m[1].split(':').each do |path|
			i = File.join(path, 'include')
			defaultincs << i if File.directory?(i)
		    end
		end
	    end
	end

	prepare(sysroot == '/' ? '' : sysroot, enable_32, enable_64)

	args = OpenStruct.new
	args.imports = includes + @imports
	args.defines = defines
	args.incdirs = incdirs + @incdirs
	args.defaultincs = defaultincs
	args.sysroot = sysroot

	@parser = _parse(args, ARCH) if @enable_32
	if @enable_64
	    unless compiler_flags_64.nil? || compiler_flags == compiler_flags_64
		defines, incdirs, includes, sysroot = parse_cc_args(compiler_flags_64)
		args.imports = includes + @imports
		args.defines = defines
		args.incdirs = incdirs + @incdirs
		args.defaultincs = defaultincs
		args.sysroot = sysroot
	    end
	    parser64 = _parse(args, ARCH64, true)
	    if @parser.nil?
		parser64.rename64!
		@parser = parser64
	    else
		@parser.mergeWith64!(parser64)
	    end
	end
    end

    def write
	case @generate_format
	when FORMAT_DYLIB
	    generate_dylib
	when FORMAT_TEMPLATE
	    generate_template
	else
	    generate_xml
	end
    end

    def cleanup
    end

    def xml_document
	@xml_document ||= generate_xml_document
    end

    def generate_format=(format)
	if @generate_format != format
	    @generate_format = format
	    @xml_document = nil
	end
    end

    def merge_64_metadata(g)
	raise "given generator isn't 64-bit" unless g.enable_64

	[:types_encoding, :resolved_structs, :resolved_enums,
	 :defines, :resolved_inf_protocols_encoding].each do |sym|

	    hash = send(sym)
	    g.send(sym).each do |name, val64|
		if val = hash[name]
		    hash[name] = [val, val64]
		else
		    hash[name] = [nil, val64]
		end
	    end
	end

	g.resolved_cftypes.each do |name, ary64|
	    type64 = ary64.first
	    if ary = @resolved_cftypes[name]
		ary << type64
	    else
		ary = ary64.dup
		ary[0] = nil
		ary << type64
		@resolved_cftypes[name] = ary
	    end
	end
    end

    def has_inline_functions?
	@parser.all_funcs.values.any? { |x| x.inline? }
    end

    def self.dependencies_of_framework(path)
	@dependencies ||= {}
	name = File.basename(path, '.framework')
	path = File.join(path, name)
	deps = @dependencies[path]
	if deps.nil?
	    if File.exist?(path)
		deps = `otool -L "#{path}"`.scan(/\t([^\s]+)/).map { |m|
		    dpath = m[0]
		    next if File.basename(dpath) == name
		    next if dpath.include?('PrivateFrameworks')
		    unless dpath.sub!(%r{\.framework/Versions/\w+/\w+$}, '') # OS X
			next unless dpath.sub!(%r{\.framework/\w+$}, '') # iOS
		    end
		    dpath.sub!('//', '/')
		    dpath + '.framework'
		}.compact
		@dependencies[path] = deps
	    elsif File.exist?(path + ".tbd")
		# FIXME
		# ".tbd" files does not contains correct framework dependencies.
	    end
	end
	deps
    end

    def self.doc_for_dependency(fpath)
	@dep_docs ||= {}
	doc = @dep_docs[fpath]
	if doc.nil?
	    fname = File.basename(fpath, '.framework')
	    paths = []
	    if bsroot = ENV['BSROOT']
		paths << File.join(bsroot, "#{fname}.bridgesupport")
	    end
	    path = File.join(fpath, "Resources/BridgeSupport/#{fname}.bridgesupport")
	    alt_path = "/Library/BridgeSupport/#{fname}.bridgesupport"
	    if dstroot = ENV['DSTROOT']
		path = File.join(dstroot, path)
		alt_path = File.join(dstroot, alt_path)
	    end
	    paths << path
	    paths << alt_path
	    a = Dir.glob(File.join(fpath, '**', '*.bridgesupport')).sort
	    if a.length == 1
		paths << a.first
	    end
	    bspath = paths.find { |p| File.exist?(p) }
	    return nil if bspath.nil?
	    doc = REXML::Document.new(File.read(bspath))
	    @dep_docs[fpath] = doc
	end
	doc
    end

    #######
    private
    #######

    def proto_to_sel(proto)
	sel = proto.strip
	sel.sub!(/^[-+]\s*/, '')
	sel.sub!(/\s*;$/, '')
	sel.sub!(/^\([^)]+\)\s*/, '')
	sel.gsub!(/\([^)]+\)\s*\w+/, '')
	sel.gsub!(/\s+/, '')
	sel
    end

    def prepare(prefix_sysroot, enable_32, enable_64)
	# Clear previously-harvested stuff.
	[ @resolved_structs,
	    @resolved_inf_protocols_encoding,
	    @resolved_enums,
	    @resolved_cftypes,
	    @collect_types_encoding ].compact.each { |h| h.clear }

	return if @prepared

	@cpp_flags = @compiler_flags ? @compiler_flags.scan(/-[ID][^\s]+/).join(' ') + ' ' : ''

	framework_paths = []
	@frameworks.each { |f| framework_paths << handle_framework(prefix_sysroot, f) }

	# set @enable_32 and @enable_64 depending on what is requested (via
	# enable_32 and enable_64), and what architectures are actually
	# available in the frameworks, if any.

	if framework_paths.empty?
	    @enable_32 = enable_32
	    @enable_64 = enable_64
	else
	    no_32 = false
	    no_64 = false
	    framework_paths.each do |fp|
		p = File.join(fp, File.basename(fp, '.framework'))
		if File.exist?(p)
		    lipo = `lipo -info "#{p}"`
		    raise "Couldn't determine architectures in #{p}" unless $?.exited? and $?.exitstatus == 0
		    lipo.chomp!
		    lipo.sub!(/^.*: /, '')
		    have32 = have64 = false
		    lipo.split.each do |arch|
			if /64$/ =~ arch
			    have64 = true
			else
			    have32 = true
			end
		    end
		elsif File.exist?(p + ".tbd")
		    have64 = true
		end
		no_32 = true unless have32
		no_64 = true unless have64
	    end
	    #In iOS 11. Some SDKs no longer ship with "fat binaries". If the fat binary isn't present, assume both 32 and 64 bit.
	    if no_32 and no_64
		no_32 = false
		no_64 = false
	    end
	    @enable_32 = (enable_32 && !no_32)
	    @enable_64 = (enable_64 && !no_64)
	    $stderr.puts "Disabling 32-bit because framework is 64-bit only" if @enable_32 != enable_32
	    $stderr.puts "Disabling 64-bit because framework is 32-bit only" if @enable_64 != enable_64
	end

	if @headers.empty?
	    raise "No headers to parse"
	end
	if @import_directive.nil? or @compiler_flags.nil?
	    raise "Compiler flags need to be provided for non-framework targets."
	end
	if @generate_format == FORMAT_DYLIB and @out_file.nil?
	    raise "Generating dylib format requires an output file"
	end

	# Open exceptions, ignore mentionned headers.
	# Keep the list of structs, CFTypes, boxed and methods return/args types.
	@all_sel_types = []
	@ignored_defines_regexps = [/^AVAILABLE_.+_VERSION_\d*/]
	@structs = {}
	@cftypes = {}
	@opaques = {}
	@opaques_to_ignore = []
	@method_exception_types = []
	@func_aliases = {}
	@exceptions = @exception_paths.map { |x| REXML::Document.new(File.read(x)) }
	@exceptions.each do |doc|
	    doc.get_elements('/signatures/ignored_headers/header').each do |element|
		path = element.text
		path_re = /#{path}/
		ignored = @headers.select { |x| path_re.match(x) }
		@headers -= ignored
		if @import_directive
		    ignored.each do |x|
			@imports.delete_if { |i| i.end_with?(File.basename(x)) }
			@import_directive.gsub!(/#import.+#{File.basename(x)}>/, '')
		    end
		end
	    end
	    doc.get_elements('/signatures/ignored_defines/regex').each do |element|
		@ignored_defines_regexps << Regexp.new(element.text.strip)
	    end
	    doc.get_elements('/signatures/struct').each do |elem|
		@structs[elem.attributes['name']] = [elem.attributes['opaque'] == 'true', elem.attributes['only_in']]
	    end
	    doc.get_elements('/signatures/cftype').each do |elem|
		@cftypes[elem.attributes['name']] = [
		    elem.attributes['gettypeid_func'],
		    elem.attributes['ignore_tollfree'] == 'true'
		]
	    end
	    doc.get_elements('/signatures/opaque').each do |elem|
		name, type, ignore = elem.attributes['name'], elem.attributes['type'], elem.attributes['ignore']
		@opaques[name] = type
		@opaques_to_ignore << name if ignore == 'true'
	    end
	    ['/signatures/class/method', '/signatures/function'].each do |path|
		doc.get_elements(path).each do |elem|
		    ary = [elem.elements['retval']]
		    ary.concat(elem.get_elements('arg'))
		    ary.compact.each do |elem2|
			type = elem2.attributes['type']
			@method_exception_types << type if type
			if sel_type = elem2.attributes['sel_of_type']
			    @all_sel_types << sel_type
			end
		    end
		end
	    end
	    doc.get_elements('/signatures/function_alias').each do |elem|
		name, original = elem.attributes['name'], elem.attributes['original']
		@func_aliases[original.strip] = name.strip
	    end
	end

	# Prepare for the future type and sel_of_type attributes.
	@method_exception_types.uniq!
	@all_sel_types.uniq!

	# Collect necessary elements from the dependencies bridge support files.
	@dep_cftypes = []
	@dependencies ||= []
	@dependencies.each do |path|
	    doc = BridgeSupportGenerator.doc_for_dependency(path)
	    next if doc.nil?
	    doc.get_elements('/signatures/cftype').each do |elem|
		@dep_cftypes << elem.attributes['name']
	    end
	end

	# We are done!
	@prepared = true
    end

    def encoding_of(varinfo, try64=false)
	if /^(BOOL|Boolean)$/.match(varinfo.stripped_rettype)
	    'B'
	elsif /^(BOOL|Boolean)\s*\*$/.match(varinfo.stripped_rettype)
	    '^B'
	else
	    v = @types_encoding[varinfo.stripped_rettype]
	    if try64
		v.is_a?(Array) ? v.last : nil
	    else
		v.is_a?(Array) ? v.first : v
	    end
	end
    end

    def pointer_type?(varinfo)
	type = encoding_of(varinfo)
	if type and type[0] == ?^
	    @pointer_types ||= {}
	    return true if @pointer_types[varinfo.stripped_rettype]
	    return false if cf_type?(varinfo.stripped_rettype)
	    @pointer_types[varinfo.stripped_rettype] = true
	end
    end

    def bool_type?(varinfo)
	type = encoding_of(varinfo)
	type and type[-1] == ?B
    end

    def tagged_struct_type?(varinfo)
	type = encoding_of(varinfo)
	type and @tagged_struct_types.include?(type)
    end

    def function_pointer_type?(varinfo)
	varinfo.function_pointer?(@func_ptr_types)
    end

    def boolified_method_type(method, method_type)
	raise "method type of #{method.selector} is nil" if method_type.nil?
	offset = 0
	[method, *method.args].each do |arg|
	    type = encoding_of(arg)
	    if type == 'B' or type == 'c'
		offset = method_type.index('c', offset)
		method_type[offset] = type if type == 'B'
		offset += 1
	    elsif type == '^B' or type == '^c'
		offset = method_type.index('^c', offset)
		method_type[offset..offset+1] = type if type == '^B'
		offset += 2
	    end
	end
	method_type
    end

    def declared_type(type)
	type.gsub(/\bconst\b/, '').delete('()').squeeze(' ').strip.sub(/\s+(\*+)$/, '\1')
    end

    def const_type?(type)
	/\bconst\b/.match(type)
    end

    def add_full_type_attributes(element, type)
	if @generate_format == FORMAT_COMPLETE
	    element.add_attribute('declared_type', declared_type(type))
	    element.add_attribute('const', 'true') if const_type?(type)
	end
    end

    def add_type_attributes(element, varinfo, varinfo64=nil)
	if varinfo.is_a?(OCHeaderAnalyzer::VarInfo)
	    type = encoding_of(varinfo)
	    element.add_attribute('type', type) if type
	    type64 = encoding_of(varinfo, true)
	    element.add_attribute('type64', type64) if type64 and type != type64
	    if func_ptr_info = varinfo.function_pointer?(@func_ptr_types)
		element.add_attribute('function_pointer', 'true')
		func_ptr_info.args.each do |a|
		    func_ptr_elem = element.add_element('arg')
		    add_type_attributes(func_ptr_elem, a)
		end
		func_ptr_retval = element.add_element('retval')
		add_type_attributes(func_ptr_retval, func_ptr_info)
	    end
	    add_full_type_attributes(element, varinfo.rettype)
	else
	    element.add_attribute('type', varinfo) if varinfo
	    element.add_attribute('type64', varinfo64) if varinfo64 and varinfo != varinfo64
	end
    end

    def __add_value_attributes__(element, value, is_64)
	suffix = is_64 ? '64' : ''
	if value.is_a?(Array)
	    raise unless value.length == 2
	    if value[0] != value[1]
		element.add_attribute('le_value' + suffix, value[0])
		element.add_attribute('be_value' + suffix, value[1])
		return
	    end
	    value = value[0]
	end
	element.add_attribute('value' + suffix, value)
    end

    def add_value_attributes(element, varinfo, varinfo64=nil)
	if varinfo
	    __add_value_attributes__(element, varinfo, false)
	end
	if varinfo64 and varinfo.to_a.first != varinfo64
	    __add_value_attributes__(element, varinfo64, true)
	end
    end

    def add_numberfunccall(parser)
	lines = []
	funccalls = []
	idx = 0
	parser.all_macronumberfunccalls.each do |name, f|
	    funccalls[idx] = f
	    lines[idx] = <<EOS
#if defined(#{name})
    case #{idx}:
	if ((fmt = printf_format(@encode(__typeof__(#{name})))) != NULL) {
	    printf(fmt, #{name});
	    return 0;
	}
	break;
#endif
EOS
	    idx += 1
	end
	return unless idx > 0
	code = <<EOS
#{@import_directive}
#import <objc/objc-class.h>
#import <signal.h>
#import <stdlib.h>
#import <mach/task.h>

/* Tiger compat */
#ifndef _C_ULNG_LNG
#define _C_ULNG_LNG 'Q'
#endif

#ifndef _C_LNG_LNG
#define _C_LNG_LNG 'q'
#endif

static void
sighandler(int sig)
{
    _Exit(-1);
}

static const char *
printf_format (const char *str)
{
    if (str == NULL || strlen(str) != 1)
	return NULL;
    switch (*str) {
	case _C_SHT: return "%hd\\n";
	case _C_USHT: return "%hu\\n";
	case _C_INT: return "%d\\n";
	case _C_UINT: return "%u\\n";
	case _C_LNG: return "%ld\\n";
	case _C_ULNG: return "%lu\\n";
	case _C_LNG_LNG: return "%lld\\n";
	case _C_ULNG_LNG: return "%llu\\n";
	case _C_FLT: return "%#.17g\\n";
	case _C_DBL: return "%#.17g\\n";
    }
    return NULL;
}

int main (int argc, char **argv)
{
    const char *fmt;
    if(argc != 2) return -1;
    /* EVERYTHING IS AWESOME! radar:18982956 */
    if (task_set_bootstrap_port(mach_task_self(), MACH_PORT_NULL) != KERN_SUCCESS) {
	_Exit(1);
    }
    signal(SIGTRAP, sighandler);
    signal(SIGBUS, sighandler);
    switch(atoi(argv[1])) {
#{lines.join('')}
    }
    return -1;
}
EOS
	compile_and_execute_code(code) do |cmd|
	    (0...idx).each do |i|
		out = `#{cmd} #{i}`
		if $?.success?
		    funccalls[i][:value] = out.chomp
		end
	    end
	end
    end

    def add_tollfree(parser)
	lines = []
	cftypes = []
	idx = 0
	parser.all_cftypes.each do |name, cf|
	    next unless cf.gettypeid_func && !cf._ignore_tollfree
	    cftypes[idx] = cf
	    lines[idx] = <<EOS
    case #{idx}:
	ref = _CFRuntimeCreateInstance(NULL, #{cf.gettypeid_func}(), sizeof(#{name}), NULL);
	if(!ref) return -1;
	printf("%s\\n", object_getClassName((id)ref));
	break;
EOS
	    idx += 1
	end
	return unless idx > 0
	code = <<EOS
#{@import_directive}
#import <objc/objc-class.h>
#import <stdlib.h>
#import <signal.h>
#import <unistd.h>

CFTypeRef _CFRuntimeCreateInstance(CFAllocatorRef allocator, CFTypeID typeID, CFIndex extraBytes, unsigned char *category);

static void
sighandler(int sig)
{
    _Exit(-1);
}

int main (int argc, char **argv)
{
    CFTypeRef ref;
    if(argc != 2) return -1;
    signal(SIGTRAP, sighandler);
    signal(SIGBUS, sighandler);
    signal(SIGALRM, SIG_DFL);
    alarm(30);
    switch(atoi(argv[1])) {
#{lines.join('')}
    }
    return 0;
}
EOS
	compile_and_execute_code(code) do |cmd|
	    (0...idx).each do |i|
		out = `#{cmd} #{i}`
		if $?.success?
		    tollfree = out.strip
		    cftypes[i][:tollfree] = tollfree unless tollfree.empty? or tollfree == 'NSCFType'
		elsif $?.signaled? and $?.termsig == Signal.list["ALRM"]
		    $stderr.puts "*** Timeout processing #{cftypes[i].name}"
		end
	    end
	end
    end

    def cf_type?(name)
	(@resolved_cftypes and (@resolved_cftypes.has_key?(name) or
							@resolved_cftypes.has_key?(name.sub(/Mutable/, '')))) or
	(@cftype_names and @cftype_names.include?(name)) or
	cf_type_ref?(name) or @dep_cftypes.include?(name)
    end

    def cf_type_ref?(name)
	return true if name == 'CFTypeRef'
	orig = @typedefs[name]
	return false if orig.nil?
	cf_type_ref?(orig)
    end

    def generate_dylib
	inline_functions = @parser.all_funcs.values.select { |x| x.inline? }
	if inline_functions.empty?
	    $stderr.puts "No inline functions in the given framework/library, no need to generate a dylib."
	    return
	end
	code = "#{@import_directive}\n"
	inline_functions.each { |f| code << f.dylib_wrapper(@enable_32, @enable_64, '__dummy_') }
	tmp_src = File.open(unique_tmp_path('src', '.m'), 'w')
	tmp_src.puts code
	tmp_src.close
	if File.extname(@out_file) != '.dylib'
	    @out_file << '.dylib'
	end
	cflags = []
	doarch = false
	(ENV['CFLAGS'] || '-arch arm64 -arch x86_64').split.each do |f|
	    if doarch
		doarch = false
		if /64$/ =~ f
		    cflags << '-arch' << f if @enable_64
		else
		    cflags << '-arch' << f if @enable_32
		end
	    elsif f == '-arch'
		doarch = true
	    else
		cflags << f
	    end
	end

    #No more garbage collection in clang for dylib
	cc = "#{getcc()} #{cflags.join(' ')} #{tmp_src.path} -o #{@out_file} #{@compiler_flags} -dynamiclib -O3 -current_version #{VERSION} -compatibility_version #{VERSION} #{OBJC_GC_COMPACTION}"
	cc << " -install_name #{@install_name}" unless @install_name.nil?
	unless system(cc)
	    raise "Can't compile dylib source file '#{tmp_src.path}'\nLine was: #{cc}"
	end
	File.unlink(tmp_src.path)
    end

    def any_in_exceptions(xpath)
	@exceptions.each do |doc|
	    elem = doc.elements[xpath]
	    return elem if elem
	end
	return nil
    end

    def all_in_exceptions(xpath)
	ary = []
	@exceptions.each do |doc|
	    doc.elements.each(xpath) { |elem| ary << elem }
	end
	return ary
    end

    def generate_xml_document
	document = REXML::Document.new
	document << REXML::XMLDecl.new
	unless @generate_format == FORMAT_COMPLETE
	    document << REXML::DocType.new(['signatures', 'SYSTEM',
		'file://localhost/System/Library/DTDs/BridgeSupport.dtd'])
	end
	root = document.add_element('signatures')
	root.add_attribute('version', VERSION)

	case @generate_format
	when FORMAT_TEMPLATE
	    # Generate the exception template file.
	    all_in_exceptions("/signatures/ignored_defines").each { |elem| root.add_element(elem) }
	    all_in_exceptions("/signatures/ignored_headers").each { |elem| root.add_element(elem) }
	    @cftype_names.sort.each do |name|
		element = any_in_exceptions("/signatures/cftype[@name='#{name}']")
		if element
		    root.add_element(element)
		else
		    element = root.add_element('cftype')
		    element.add_attribute('name', name)
		    gettypeid_func = name.sub(/Ref$/, '') + 'GetTypeID'
		    ok = @functions.find { |x| x.name == gettypeid_func }
		    if !ok and gettypeid_func.sub!(/Mutable/, '')
			ok = @functions.find { |x| x.name == gettypeid_func }
		    end
		    element.add_attribute('gettypeid_func', ok ? gettypeid_func : '?')
		end
	    end
	    @struct_names.sort.each do |struct_name|
		element = any_in_exceptions("/signatures/struct[@name='#{struct_name}']")
		if element
		    root.add_element(element)
		else
		    element = root.add_element('struct')
		    element.add_attribute('name', struct_name)
		end
	    end
	    all_in_exceptions("/signatures/opaque").each { |elem| root.add_element(elem) }
	    all_in_exceptions("/signatures/constant").each { |elem| root.add_element(elem) }
	    all_in_exceptions("/signatures/function").each { |elem| root.add_element(elem) }
	    @functions.sort.each do |function|
		pointer_arg_indexes = []
		function.args.each_with_index do |arg, i|
		    pointer_arg_indexes << i if pointer_type?(arg)
		end
		next if pointer_arg_indexes.empty?

		element = root.elements["/signatures/function[@name='#{function.name}']"]
		unless element
		    element = root.add_element('function')
		    element.add_attribute('name', function.name)
		end
		pointer_arg_indexes.each do |i|
		    unless element.elements["arg[@index='#{i}']"]
			arg_element = element.add_element('arg')
			arg_element.add_attribute('index', i)
			arg_element.add_attribute('type_modifier', 'o')
			arg_element.add_attribute('NEW', '1')
		    end
		end
	    end
	    all_in_exceptions("/signatures/class").each { |elem| root.add_element(elem) }
	    @ocmethods.sort.each do |class_name, methods|
		method_elements = []
		class_element = root.elements["/signatures/class[@name='#{class_name}']"]
		methods.sort.each do |method|
		    pointer_arg_indexes = []
		    method.args.each_with_index do |arg, i|
			pointer_arg_indexes << i if pointer_type?(arg)
		    end
		    next if pointer_arg_indexes.empty?

		    element = class_element.elements["method[@selector='#{method.selector}'#{method.class_method? ? ' and @class_method=\'true\'' : ''}]"] if class_element
		    if element
			next if element.attributes['ignore'] == 'true'
		    else
			element = REXML::Element.new('method')
			element.add_attribute('selector', method.selector)
			element.add_attribute('class_method', true) if method.class_method?
		    end
		    pointer_arg_indexes.each do |i|
			unless element.elements["arg[@index='#{i}']"]
			    arg_element = element.add_element('arg')
			    arg_element.add_attribute('index', i)
			    arg_element.add_attribute('type_modifier', 'o')
			    arg_element.add_attribute('NEW', '1')
			end
		    end
		    method_elements << element
		end
		if !method_elements.empty? and !class_element
		    element = root.add_element('class')
		    element.add_attribute('name', class_name)
		    method_elements.each { |x| element.add_element(x) }
		end
	    end
	when FORMAT_FINAL, FORMAT_COMPLETE
	    # Generate the final metadata file.
	    @dependencies.each do |fpath|
		element = root.add_element('depends_on')
		element.add_attribute('path', fpath)
	    end
	    @resolved_structs.sort.each do |name, type|
		element = root.add_element('struct')
		element.add_attribute('name', name)
		add_type_attributes(element, *type)
		element.add_attribute('opaque', true) if @structs[name].first
		if @generate_format == FORMAT_COMPLETE
		    type.to_a.first[1..-2].gsub(/\{[^}]+\}/, '').scan(/"([^"]+)"/).flatten.each do |name|
			field_elem = element.add_element('field')
			field_elem.add_attribute('name', name)
		    end
		end
	    end
	    @resolved_cftypes.sort.each do |name, ary|
		type, tollfree, gettypeid_func, type64 = ary
		element = root.add_element('cftype')
		element.add_attribute('name', name)
		add_type_attributes(element, type, type64)
		element.add_attribute('gettypeid_func', gettypeid_func) if gettypeid_func
		element.add_attribute('tollfree', tollfree) if tollfree
	    end
	    @opaques.keys.sort.each do |name|
		next if @opaques_to_ignore.include?(name)
		raise "encoding of opaque type '#{name}' not resolved" unless @types_encoding.has_key?(name)
		element = root.add_element('opaque')
		element.add_attribute('name', name.sub(/\s*\*+$/, ''))
		add_type_attributes(element, *@types_encoding[name])
	    end
	    @constants.sort.each do |constant|
		element = root.add_element('constant')
		element.add_attribute('name', constant.name)
		add_type_attributes(element, constant)
	    end
	    @defines.sort.each do |name, value|
		if value.is_a?(Array)
		    if value.first == value.last
			value = value.first
		    else
			value = (value.first or value.last)
		    end
		end
		value.strip!
		c_str = objc_str = false
		if value[0] == ?" and value[-1] == ?"
		    value = value[1..-2]
		    c_str = true
		elsif value[0] == ?@ and value[1] == ?" and value[-1] == ?"
		    value = value[2..-2]
		    objc_str = true
		elsif md = /^CFSTR\s*\(\s*([^)]+)\s*\)\s*$/.match(value)
		    if md[1][0] == ?" and md[1][-1] == ?"
			value = md[1][1..-2]
			objc_str = true
		    end
		end
		next if !c_str and !objc_str
		element = root.add_element('string_constant')
		element.add_attribute('name', name.strip)
		element.add_attribute('value', value)
		element.add_attribute('nsstring', objc_str) if objc_str
	    end
	    @resolved_enums.sort.each do |enum, value|
		element = root.add_element('enum')
		element.add_attribute('name', enum)
		add_value_attributes(element, *value)
	    end
	    @functions.uniq.sort.each do |function|
		element = root.add_element('function')
		element.add_attribute('name', function.name)
		element.add_attribute('variadic', true) if function.variadic?
		element.add_attribute('inline', true) if function.inline?
		function.args.each do |arg|
		    arg_elem = element.add_element('arg')
		    add_type_attributes(arg_elem, arg)
		    if @generate_format == FORMAT_COMPLETE
			arg_elem.add_attribute('name', arg.name)
		    end
		end
		rettype = encoding_of(function)
		if rettype != 'v'
		    retval_element = element.add_element('retval')
		    add_type_attributes(retval_element, function)
		    retval_element.add_attribute('already_retained', true) \
			if cf_type?(function.stripped_rettype) \
			and /(Create|Copy)/.match(function.name)
		end
	    end
	    @func_aliases.sort.each do |original, name|
		element = root.add_element('function_alias')
		element.add_attribute('name', name)
		element.add_attribute('original', original)
	    end
	    @ocmethods.sort.each do |class_name, methods|
		elements = methods.sort.map { |method|
		    if @generate_format == FORMAT_FINAL
			custom_retval = (bool_type?(method) or tagged_struct_type?(method))
			custom_args = []
			method.args.each_with_index do |a, i|
			    if bool_type?(a) or tagged_struct_type?(a) or function_pointer_type?(a)
				custom_args << i
			    end
			end
		    else
			custom_retval = true
			custom_args = (0..method.args.length - 1).to_a
		    end
		    next if !custom_retval and custom_args.empty? and !method.variadic?
		    element = REXML::Element.new('method')
		    element.add_attribute('selector', method.selector)
		    element.add_attribute('class_method', true) if method.class_method?
		    element.add_attribute('variadic', true) if method.variadic?
		    custom_args.each do |i|
			arg_elem = element.add_element('arg')
			arg_elem.add_attribute('index', i)
			add_type_attributes(arg_elem, method.args[i])
			if @generate_format == FORMAT_COMPLETE
			    arg_elem.add_attribute('name', method.args[i].name)
			end
		    end
		    if custom_retval
			retval_elem = element.add_element('retval')
			add_type_attributes(retval_elem, method)
		    end
		    element
		}.compact
		next if elements.empty?
		class_element = root.add_element('class')
		class_element.add_attribute('name', class_name)
		elements.each { |x| class_element.add_element(x) }
	    end
	    @inf_protocols.sort.each do |name, methods|
		next if methods.empty?
		prot_element = root.add_element('informal_protocol')
		prot_element.add_attribute('name', name)
		methods.sort.each do |method|
		    element = prot_element.add_element('method')
		    method_types = @resolved_inf_protocols_encoding[method.selector].to_a
		    element.add_attribute('selector', method.selector)
		    element.add_attribute('class_method', true) if method.class_method?
		    add_type_attributes(element, *method_types)
		    if @generate_format == FORMAT_COMPLETE
			method.args.each_with_index do |arg, i|
			    arg_elem = element.add_element('arg')
			    arg_elem.add_attribute('index', i)
			    arg_elem.add_attribute('name', arg.name)
			end
		    end
		end
	    end

	    # Merge with exceptions.
	    @exceptions.each { |x| merge_document_with_exceptions(document, x) }
	end
	return document
    end

    def new_xml_document(doctype=true)
	document = REXML::Document.new
	document << REXML::XMLDecl.new
	document << REXML::DocType.new(['signatures', 'SYSTEM',
	    'file://localhost/System/Library/DTDs/BridgeSupport.dtd']) if doctype
	root = document.add_element('signatures')
	root.add_attribute('version', VERSION)
	return document, root
    end

    def generate_template
	document, root = new_xml_document()

	#puts '---- generate exception template file ----' #DEBUG
	# Generate the exception template file.
	all_in_exceptions("/signatures/ignored_defines").each { |elem| root.add_element(elem) }
	all_in_exceptions("/signatures/ignored_headers").each { |elem| root.add_element(elem) }
	@parser.all_cftypes.keys.sort.each do |name|
	    element = any_in_exceptions("/signatures/cftype[@name='#{name}']")
	    if element
		root.add_element(element)
	    else
		element = root.add_element('cftype')
		element.add_attribute('name', name)
		gettypeid_func = @parser.all_cftypes[name].gettypeid_func
		element.add_attribute('gettypeid_func', gettypeid_func.nil? ? '?' : gettypeid_func)
	    end
	end
	#puts '---- generate structure exceptions ----' #DEBUG
	@parser.all_structs.keys.sort.each do |struct_name|
	    element = any_in_exceptions("/signatures/struct[@name='#{struct_name}']")
	    if element
		root.add_element(element)
	    else
		element = root.add_element('struct')
		element.add_attribute('name', struct_name)
	    end
	end
	#puts '---- generate opaque exceptions ----' #DEBUG
	all_in_exceptions("/signatures/opaque").each { |elem| root.add_element(elem) }
	#puts '---- generate constant exceptions ----' #DEBUG
	all_in_exceptions("/signatures/constant").each { |elem| root.add_element(elem) }
	#puts '---- generate function exceptions ----' #DEBUG
	all_in_exceptions("/signatures/function").each { |elem| root.add_element(elem) }
	#puts '---- generate function exceptions from parser ----' #DEBUG
	@parser.all_funcs.sort.each do |func_name, function|
	    pointer_arg_indexes = []
	    function.args.each_with_index do |arg, i|
		pointer_arg_indexes << i if arg.pointer_type?
	    end
	    next if pointer_arg_indexes.empty?

	    element = root.elements["/signatures/function[@name='#{func_name}']"]
	    unless element
		element = root.add_element('function')
		element.add_attribute('name', func_name)
	    end
	    pointer_arg_indexes.each do |i|
		unless element.elements["arg[@index='#{i}']"]
		    arg_element = element.add_element('arg')
		    arg_element.add_attribute('index', i)
		    arg_element.add_attribute('type_modifier', 'o')
		    arg_element.add_attribute('NEW', '1')
		end
	    end
	end
	#puts '---- generate class exceptions ----' #DEBUG
	all_in_exceptions("/signatures/class").each { |elem| root.add_element(elem) }
	#puts '---- generate class exceptions from parser ----' #DEBUG
	@parser.all_interfaces.sort.each do |class_name, interf|
	    method_elements = []
	    class_element = root.elements["/signatures/class[@name='#{class_name}']"]
	    interf.methods.sort.each do |method|
		pointer_arg_indexes = []
		method.args.each_with_index do |arg, i|
		    pointer_arg_indexes << i if arg.pointer_type?
		end
		next if pointer_arg_indexes.empty?

		element = class_element.elements["method[@selector='#{method.selector}'#{method.class_method? ? ' and @class_method=\'true\'' : ''}]"] if class_element
		if element
		    next if element.attributes['ignore'] == 'true'
		else
		    element = REXML::Element.new('method')
		    element.add_attribute('selector', method.selector)
		    element.add_attribute('class_method', true) if method.class_method?
		end
		pointer_arg_indexes.each do |i|
		    unless element.elements["arg[@index='#{i}']"]
			arg_element = element.add_element('arg')
			arg_element.add_attribute('index', i)
			arg_element.add_attribute('type_modifier', 'o')
			arg_element.add_attribute('NEW', '1')
		    end
		end
		method_elements << element
	    end
	    if !method_elements.empty? and !class_element
		element = root.add_element('class')
		element.add_attribute('name', class_name)
		method_elements.each { |x| element.add_element(x) }
	    end
	end
	#indent = 4
	indent = 0
	if @out_file
	    File.open(@out_file, 'w') do |io|
		document.write(io, indent)
		io.print "\n"
	    end
	else
	    document.write(STDOUT, indent)
	    STDOUT.print "\n"
	end
    end

    def generate_xml
	document, root = new_xml_document(@generate_format != FORMAT_COMPLETE)
	if @generate_format == FORMAT_COMPLETE
	    #indent = 4
	    indent = 0
	    # clear any blocks we might have previously added
	    Bridgesupportparser.add_blockattrs({})
	    Bridgesupportparser::ArgInfo.add_blockattrs({})
	    Bridgesupportparser::MethodInfo.set_ret_select(nil)
	    Bridgesupportparser::ObjCArgInfo.add_blockattrs({})
	    Bridgesupportparser::ObjCArgInfo.set_attr_transform(nil)
	    Bridgesupportparser::ObjCRetvalInfo.set_attr_transform(nil)
#	    r_attr_transform = lambda do |attrs, blockattr|
#		return nil if attrs[:type] == 'v'
#		x = attrs.select { |k, v| k.to_s[0] != ?_ && !blockattr.call(k) }
#		return nil if x.empty?
#		x
#	    end
#	    Bridgesupportparser::RetvalInfo.set_attr_transform(r_attr_transform)
	    Bridgesupportparser::RetvalInfo.set_attr_transform(nil)
	    Bridgesupportparser::StructInfo.block_fields = false
	else
	    indent = 0
	    # block certain attributes in all cases
	    Bridgesupportparser.add_blockattrs({
		:const => 1,
		:declared_type => 1,
		:declared_type64 => 1,
	    })
	    # block certain attributes in specific cases
	    Bridgesupportparser::ArgInfo.add_blockattrs({
		:name => 1,
	    })
	    Bridgesupportparser::MethodInfo.set_ret_select(lambda { |a| a._type_override || a._override })
	    Bridgesupportparser::ObjCArgInfo.add_blockattrs({
		:name => 1,
	    })
	    oa_attr_transform = lambda do |attrs, blockattr|
		#puts "####{attrs.name}: #{attrs.inspect}" #DEBUG
		#attrs[:_type_override] = true if attrs[:type] && attrs[:type][0] == ?^ && attrs[:type] != '^@' && !@parser.every_cftype[attrs[:declared_type]]
		return nil if $bsp_informal_protocols
		funcptr = attrs[:function_pointer]
		attrs[:_type_override] = attrs[:_override] = true if funcptr
		return nil unless attrs[:_type_override] || attrs[:_override]
		a = attrs.dup
		index = a.delete(:index)
		if a[:sel_of_type] || !a[:_type_override]
		    a.delete(:type)
		    a.delete(:type64)
		end
		x = a.select { |k, v| k.to_s[0] != ?_ && !blockattr.call(k) }.to_a
		return nil if x.empty?
		x << [:index, index] if index
		x
	    end
	    Bridgesupportparser::ObjCArgInfo.set_attr_transform(oa_attr_transform)
	    or_attr_transform = lambda do |attrs, blockattr|
		return nil if attrs[:type] == 'v' || $bsp_informal_protocols
		return oa_attr_transform.call(attrs, blockattr)
	    end
	    Bridgesupportparser::ObjCRetvalInfo.set_attr_transform(or_attr_transform)
	    r_attr_transform = lambda do |attrs, blockattr|
		return nil if attrs[:type] == 'v'
		x = attrs.select { |k, v| k.to_s[0] != ?_ && !blockattr.call(k) }
		return nil if x.empty?
		x
	    end
	    Bridgesupportparser::RetvalInfo.set_attr_transform(r_attr_transform)
	    Bridgesupportparser::StructInfo.block_fields = true
	end
	@dependencies.each do |fpath|
	    element = root.add_element('depends_on')
	    element.add_attribute('path', fpath)
	end
	@parser.addXML(root)
	fmt = OrderedAttributes.new(indent)
	if @out_file
	    File.open(@out_file, 'w') do |io|
		fmt.write(document, io)
		io.print "\n"
	    end
	else
	    fmt.write(document, STDOUT)
	    print "\n"
	end
    end

    def merge_arg_exception_attributes(orig_element, element, keep_index=true)
	element.attributes.each do |name, value|
	    next if name == 'index' and !keep_index
	    if name == 'type'
		value = @types_encoding[value]
		value = value[0] if value.is_a?(Array) # XXX 'type' can only override 32-bit types
		raise "encoding of '#{element}' not resolved" if value.nil?
	    elsif name == 'sel_of_type'
		sel = @sel_types[value].selector
		types = @resolved_inf_protocols_encoding[sel].to_a.uniq
		raise "selector type of '#{element}' not resolved" if types.empty?
		value = types[0]
		orig_element.add_attribute('sel_of_type64', types[1]) if types.size > 1
	    end
	    orig_element.add_attribute(name, value)
	end
    end

    def merge_exception_attrs(obj, element, mapping = {})
	element.attributes.each do |name, value|
	    next if name == 'index'
	    f = mapping[name]
	    name, value = f.call(name, value) unless f.nil?
	    obj[name.to_sym] = value unless value.nil?
	end
    end

    def merge_exception_attrs_sel_of_type(obj, element, where)
	errors = []
	element.attributes.each do |name, value|
	    case name
	    when 'index'
		next
	    when 'sel_of_type'
		seltype = @sel_types[value]
		if seltype.nil?
		    errors <<  "No sel_of_type for \"#{value}\" in #{where}"
		    next
		end
		obj.delete(:sel_of_type)
		obj[:sel_of_type] = seltype
		obj[:_override] = true
	    when 'type'
		type = @types[value]
		if type.nil?
		    errors << "No type for \"#{value}\" in #{where}"
		    next
		end
		obj.delete(:type)
		obj[:type] = type
		obj[:_type_override] = true
	    else
		unless value.nil?
		    #puts "merge_exception_attrs_sel_of_type: obj[#{name}] = #{value}" #DEBUG
		    obj[name.to_sym] = value
		    obj[:_override] = true
		end
	    end
	end
	return errors unless obj.is_a?(Bridgesupportparser::VarInfo)
	obj_func = obj.function_pointer
	obj_args = obj_func.nil? ? nil : obj_func.args
	element.elements.each('arg') do |arg_element|
	    if obj_args.nil?
		errors << "#{where} has no arguments, but an argument exception was specified"
		break
	    end
	    idx = arg_element.attributes['index'].to_i
	    orig_arg_element = obj_args[idx]
	    if orig_arg_element.nil?
		errors << "argument '#{idx}' of #{where} is described with more arguments than it should"
		next
	    end
	    errors.concat(merge_exception_attrs_sel_of_type(orig_arg_element, arg_element, "argument #{idx} of #{where}"))
	end
	retval_element = element.elements['retval']
	if retval_element
	    orig_retval = obj_func.nil? ? nil : obj_func.ret
	    if orig_retval.nil?
		errors << "retval of '#{where}' is described in an exception file but the return value has not been discovered by the final generator"
	    else
		errors.concat(merge_exception_attrs_sel_of_type(orig_retval, retval_element, "retval of #{where}"))
	    end
	end
	return errors
    end

    def merge_with_exceptions(parser, exception_document, ignore_errors = false)
	# Merge constants.
	errors = []
	exception_document.elements.each('/signatures/constant') do |const_element|
	    const_name = const_element.attributes['name']
	    orig_const = parser.all_vars[const_name]
	    if orig_const.nil?
		errors << "Constant '#{const_name}' is described in an exception file but it has not been discovered by the final generator"
		next
	    end
	    magic_cookie = const_element.attributes['magic_cookie']
	    # Append the magic_cookie attribute.
	    orig_const[:magic_cookie] = true if magic_cookie == 'true'
	end
	# Merge enums.
	exception_document.elements.each('/signatures/enum') do |enum_element|
	    enum_name = enum_element.attributes['name']
	    orig_enum = parser.all_enums[enum_name]
	    ignore = enum_element.attributes['ignore']
	    if orig_enum.nil?
		orig_enum = parser.all_macronumbers[enum_name]
		if orig_enum.nil?
		    if ignore == 'true'
			orig_enum = parser.all_enums[enum_name] = Bridgesupportparser::ValueInfo.new(parser, enum_name, nil)
			orig_enum[:ignore] = true
			suggestion = enum_element.attributes['suggestion']
			orig_enum[:suggestion] = suggestion if suggestion
			orig_enum[:_override] = true
		    else
			errors << "Enum '#{enum_name}' is described in an exception file but it has not been discovered by the final generator"
		    end
		    next
		end
	    end
	    # Append the ignore/suggestion attributes.
	    if ignore == 'true'
		orig_enum[:ignore] = true
		suggestion = enum_element.attributes['suggestion']
		orig_enum[:suggestion] = suggestion if suggestion
		orig_enum.delete(:value)
		orig_enum.delete(:value64)
		orig_enum[:_override] = true
	    else
		errors.concat(merge_exception_attrs_sel_of_type(orig_enum, enum_element, "enum #{enum_name}"))
	    end
	end
	# Merge functions.
	exception_document.elements.each('/signatures/function') do |func_element|
	    func_name = func_element.attributes['name']
	    orig_func = parser.all_funcs[func_name]
	    if orig_func.nil?
		errors << "Function '#{func_name}' is described in an exception file but it has not been discovered by the final generator"
		next
	    end
	    #merge_exception_attrs(orig_func, func_element)
	    orig_func_args = orig_func.args
	    func_element.elements.each('arg') do |arg_element|
		idx = arg_element.attributes['index'].to_i
		orig_arg_element = orig_func_args[idx]
		if orig_arg_element.nil?
		    errors << "Function '#{func_name}' is described with more arguments than it should"
		    next
		end
		errors.concat(merge_exception_attrs_sel_of_type(orig_arg_element, arg_element, "argument #{idx} of func \"#{func_name}\""))
	    end
	    retval_element = func_element.elements['retval']
	    if retval_element
		orig_retval = orig_func.ret
		if orig_retval.nil?
		    errors << "Function '#{func_name}' is described with a return value in an exception file but the return value has not been discovered by the final generator"
		else
		    errors.concat(merge_exception_attrs_sel_of_type(orig_retval, retval_element, "retval of func \"#{func_name}\""))
		end
	    end
	end
	# Merge class/methods.
	exception_document.elements.each('/signatures/class') do |class_element|
	    class_name = class_element.attributes['name']
	    orig_class = parser.all_interfaces[class_name]
	    if orig_class.nil?
		errors << "Class '#{class_name}' is described in an exception file but it has not been discovered by the final generator"
		next
	    end
	    # Merge methods.  To keep class and instance methods separate, we
	    # prepend 'c' or 'i' to the selector, respectively.
	    methods = {}
	    orig_class.each_method { |m| methods[(m.class_method? ? 'c' : 'i') + m.selector] = m }
	    class_element.elements.each('method') do |element|
		selector = element.attributes['selector']
		ignore = element.attributes['ignore'] == 'true'
		orig_meth = methods[(element.attributes['class_method'] == 'true' ? 'c' : 'i') + selector]
		if orig_meth.nil?
		    ## Method is not defined in the original document, we can append it.
		    ##orig_element = orig_class_element.add_element(element)
		    # error for now
		    errors << "Method with selector '#{selector}' of class '#{class_name}' is described in an exception file but it has not been discovered by the final generator" unless ignore
		    next
		elsif ignore
		    orig_class.methods.delete(orig_meth)
		end
		# Smart merge of attributes.
		errors.concat(merge_exception_attrs_sel_of_type(orig_meth, element, "method with selector \"#{selector}\" of class \"#{class_name}\""))
		# Merge the arg elements.
		orig_retval = orig_meth.ret
		element.elements.each('arg') do |child|
		    index = child.attributes['index'].to_i
		    orig_arg = orig_meth.args[index]
		    if orig_arg.nil?
			# orig_arg = if orig_retval
			#     orig_element.insert_before(orig_retval, child)
			#     child
			# else
			#     orig_element.add_element(child)
			# end
			errors << "Method with selector '#{selector}' of class '#{class_name}' is described with more arguments than it should"
			next
		    end
		    errors.concat(merge_exception_attrs_sel_of_type(orig_arg, child, "argument #{index} of method with selector \"#{selector}\" of class \"#{class_name}\""))
		end
		# Merge the retval element.
		retval = element.elements['retval']
		if retval
		    if orig_retval.nil?
			#orig_retval = orig_element.add_element(retval)
			errors << "Method with selector '#{selector}' of class '#{class_name}' is described with a return value in an exception file but the return value has not been discovered by the final generator"
		    else
			errors.concat(merge_exception_attrs_sel_of_type(orig_retval, retval, "retval of method with selector \"#{selector}\" of class \"#{class_name}\""))
		    end
		end
	    end
	end
	unless errors.empty? || ignore_errors
	    p = ''
	    if $DEBUG
		File.open('/tmp/error.bridgesupport', 'w', 0644) { |f| parser.writeXML(f, VERSION) }
		p = ' (partial result in /tmp/error.bridgesupport)'
		parser.dump
	    end
	    raise "Error(s) when merging exception data#{p}:\n#{errors.join("\n")}"
	end
    end

    def merge_document_with_exceptions(document, exception_document)
	# Merge constants.
	errors = []
	exception_document.elements.each('/signatures/constant') do |const_element|
	    const_name = const_element.attributes['name']
	    orig_const_element = document.elements["/signatures/constant[@name='#{const_name}']"]
	    if orig_const_element.nil?
		errors << "Constant '#{const_name}' is described in an exception file but it has not been discovered by the final generator"
		next
	    end
	    magic_cookie = const_element.attributes['magic_cookie']
	    # Append the magic_cookie attribute.
	    if magic_cookie == 'true'
		orig_const_element.add_attribute('magic_cookie', true)
	    end
	end
	# Merge enums.
	exception_document.elements.each('/signatures/enum') do |enum_element|
	    enum_name = enum_element.attributes['name']
	    orig_enum_element = document.elements["/signatures/enum[@name='#{enum_name}']"]
	    if orig_enum_element.nil?
		if @defines.has_key?(enum_name)
		    document.root.add_element(enum_element)
		else
		    errors << "Enum '#{enum_name}' is described in an exception file but it has not been discovered by the final generator"
		end
	    else
		ignore = enum_element.attributes['ignore']
		# Append the ignore/suggestion attributes.
		if ignore == 'true'
		    orig_enum_element.add_attribute('ignore', true)
		    suggestion = enum_element.attributes['suggestion']
		    orig_enum_element.add_attribute('suggestion', suggestion) if suggestion
		    orig_enum_element.delete_attribute('value')
		end
	    end
	end
	# Merge functions.
	exception_document.elements.each('/signatures/function') do |func_element|
	    func_name = func_element.attributes['name']
	    orig_func_element = document.elements["/signatures/function[@name='#{func_name}']"]
	    if orig_func_element.nil?
		errors << "Function '#{func_name}' is described in an exception file but it has not been discovered by the final generator"
		next
	    end
	    orig_func_args = orig_func_element.get_elements('arg')
	    func_element.elements.each('arg') do |arg_element|
		idx = arg_element.attributes['index'].to_i
		orig_arg_element = orig_func_args[idx]
		if orig_arg_element.nil?
		    errors << "Function '#{func_name}' is described with more arguments than it should"
		    next
		end
		merge_arg_exception_attributes(orig_arg_element, arg_element, false)
	    end
	    retval_element = func_element.elements['retval']
	    if retval_element
		orig_retval_element = orig_func_element.elements['retval']
		if orig_retval_element.nil?
		    errors << "Function '#{func_name}' is described with a return value in an exception file but the return value has not been discovered by the final generator"
		else
		    merge_arg_exception_attributes(orig_retval_element, retval_element)
		end
	    end
	end
	# Merge class/methods.
	exception_document.elements.each('/signatures/class') do |class_element|
	    class_name = class_element.attributes['name']
	    if @ocmethods[class_name].nil?
		errors << "Class '#{class_name}' is described in an exception file but it has not been discovered by the final generator"
		next
	    end
	    orig_class_element = document.elements["/signatures/class[@name='#{class_name}']"]
	    if orig_class_element.nil?
		# Class is not defined in the original document, we can append it with its methods.
		orig_class_element = document.root.add_element(class_element)
	    end
	    # Merge methods.
	    class_element.elements.each('method') do |element|
		selector = element.attributes['selector']
		orig_element = orig_class_element.elements["method[@selector='#{selector}']"]
		if orig_element.nil?
		    # Method is not defined in the original document, we can append it.
		    orig_element = orig_class_element.add_element(element)
		end
		# Smart merge of attributes.
		element.attributes.each do |name, value|
		    orig_value = orig_element.attributes[name]
		    if orig_value != value
			$stderr.puts "Warning: attribute '#{name}' of method '#{selector}' of class '#{class_name}' has a different value in the exception file -- using the latter value" unless orig_value.nil?
			orig_element.add_attribute(name, value)
		    end
		end
		# Merge the arg elements.
		orig_retval = orig_element.elements['retval']
		element.elements.each('arg') do |child|
		    index = child.attributes['index']
		    orig_arg = orig_element.elements["arg[@index='#{index}']"]
		    if orig_arg.nil?
			orig_arg = if orig_retval
			    orig_element.insert_before(orig_retval, child)
			    child
			else
			    orig_element.add_element(child)
			end
		    end
		    merge_arg_exception_attributes(orig_arg, child)
		end
		# Merge the retval element.
		retval = element.elements['retval']
		if retval
		    if orig_retval.nil?
			orig_retval = orig_element.add_element(retval)
		    end
		    merge_arg_exception_attributes(orig_retval, retval)
		end
	    end
	end
	unless errors.empty?
	    raise "Error(s) when merging exception data:\n#{errors.join("\n")}"
	end
    end

    # Apple introducted a new file system in High Sierra (UTF-8).
    # Mac OS Extended was UTF-16 and the ruby source code `dir.c` explicitly
    # assumes UTF-16 for the __APPLE__ compiler flag (which as been the
    # case for the past 30 years until 2018). This causes Dir.glob to #
    # return a different file order on High Sierra vs Sierra. This
    # method is a # compatible version of Dir.glob from Sierra and is
    # used by RM to load ruby and header files in lexicographical order.
    # See: https://developer.apple.com/library/content/documentation/FileManagement/Conceptual/APFS_Guide/FAQ/FAQ.html
    # and: https://github.com/ruby/ruby/blob/trunk/dir.c#L120
    # for more info.
    def lexicographically pattern
	supported_extensions = %w( c m cpp cxx mm h rb)
	pathnames = Pathname.glob pattern
	pathnames.sort_by do |p|
	    p.each_filename.to_a.map(&:downcase).unshift supported_extensions.index(p.to_s.split(".").last)
	end.map { |p| p.to_s }
    end

    def handle_framework(prefix_sysroot, val)
	path = framework_path(prefix_sysroot, val)
	raise "Can't locate framework '#{val}'" if path.nil?
	(@framework_paths ||= []) << File.dirname(path)
	raise "Can't find framework '#{val}'" if path.nil?
	parent_path, name = path.scan(%r{^(.+)/(\w+)\.framework/?$})[0]
	if @private
	    headers_path = File.join(path, 'PrivateHeaders')
	    raise "Can't locate private framework headers at '#{headers_path}'" unless File.exist?(headers_path)
	    headers = lexicographically(File.join(headers_path, '**', '*.h')).reject { |f| !File.exist?(f) }
	    public_headers_path = File.join(path, 'Headers')
	    public_headers = if File.exist?(public_headers_path)
		OCHeaderAnalyzer::CPPFLAGS << " -I#{public_headers_path} "
		@incdirs.unshift(encode_includes(public_headers_path, 'A', true, false))
		lexicographically(File.join(headers_path, '**', '*.h')).reject { |f| !File.exist?(f) }
	    else
		[]
	    end
	else
	    headers_path = File.join(path, 'Headers')
	    raise "Can't locate public framework headers at '#{headers_path}'" unless File.exist?(headers_path)
	    public_headers = headers = lexicographically(File.join(headers_path, '**', '*.h')).reject { |f| !File.exist?(f) }
	end
	# We can't just "#import <x/x.h>" as the main Framework header might not include _all_ headers.
	# So we are tricking this by importing the main header first, then all headers.
	# (Also look for main header in a case-insensitive way.)
	header_basenames = (headers | public_headers).map { |x| x.sub(%r{#{Regexp.escape(headers_path)}/*}, '') }
	name_h = name + ".h"
	if idx = header_basenames.index { |x| name_h.casecmp(x) == 0 }
	    x = header_basenames.delete_at(idx)
	    header_basenames.unshift(x)
	end
	@import_directive = header_basenames.map { |x| "#import <#{name}/#{x}>" }.join("\n")
	header_basenames.each { |x| @imports << "#{name}/#{x}" }
	@incdirs.unshift(encode_includes(parent_path, 'A', true, true))
	# can't link with sub-umbrella frameworks; use top level instead
	rp = Pathname.new(parent_path).realpath
	#puts "rp=#{rp.to_s}" #DEBUG
	rpparent, f = rp.split
	#puts "rpparent=#{rpparent.to_s} f=#{f.to_s}" #DEBUG
	fflags = ''
	if f.to_s == 'Frameworks'
	    rpparent, f = rpparent.split # skip version directory
	    rpparent, f = rpparent.split
	    #puts "rpparent=#{rpparent.to_s} f=#{f.to_s}" #DEBUG
	    if f.to_s == "Versions" && /\.framework$/.match(rpparent.to_s)
		fflags = "-F\"#{parent_path}\" "
		@cpp_flags << "-F\"#{parent_path}\" "
		rpparent, f = rpparent.split
		parent_path = rpparent.to_s
		name = f.to_s.sub(/\.framework$/,'')
	    end
	end
	@compiler_flags ||= "#{fflags}-F\"#{parent_path}\" -framework #{name} -I#{headers_path} "
	@cpp_flags << "-F\"#{parent_path}\" "
	#puts "@compiler_flags=#{@compiler_flags}" #DEBUG
	#puts "@cpp_flags=#{@cpp_flags}" #DEBUG
	@headers.concat(headers)
	# Memorize the dependencies.
	@dependencies = BridgeSupportGenerator.dependencies_of_framework(path)
	return path
    end

    def framework_path(prefix_sysroot, val)
	return val if File.exist?(val)
	val += '.framework' unless /\.framework$/.match(val)
	paths = ["#{prefix_sysroot}/System/Library/Frameworks",
	  '/Library/Frameworks',
	  "#{ENV['HOME']}/Library/Frameworks"
	]
	paths << "#{prefix_sysroot}/System/Library/PrivateFrameworks" if @private
	paths.each do |dir|
	    path = File.join(dir, val)
	    return path if File.exist?(path)
	end
	return nil
    end

    def unique_tmp_path(base, extension='', dir=Dir.tmpdir)
	i = 0
	loop do
	    p = File.join(dir, "#{base}-#{i}-#{Process.pid}" + extension)
	    return p unless File.exist?(p)
	    i += 1
	end
    end

    def compile_and_execute_code(code, cleanup_when_fail=false, emulate_ppc=false)
	tmp_src = File.open(unique_tmp_path('src', '.m'), 'w')
	tmp_src.puts code
	tmp_src.close

	tmp_bin_path = unique_tmp_path('bin')
	tmp_log_path = unique_tmp_path('log')

	line = "#{getcc()} #{tmp_src.path} -o #{tmp_bin_path} #{@compiler_flags} 2>#{tmp_log_path}"
	#puts "compile_and_execute_code: #{line}" #DEBUG
	#puts caller(1).join("\n") #DEBUG
	while !system(line)
	    r = File.read(tmp_log_path)
	    if /built for GC-only/.match(r)
		line = "#{getcc()} -fobjc-gc-only #{tmp_src.path} -o #{tmp_bin_path} #{@compiler_flags} 2>#{tmp_log_path}"
		break if system(line)
		r = File.read(tmp_log_path)
	    end
	    msg = "Can't compile C code... aborting\ncommand was: #{line}\n\n#{r}"
	    $stderr.puts "Code was:\n<<<<<<<\n#{code}>>>>>>>\n" if $DEBUG

	    # FIXME
	    # When generate metadata of SystemConfiguration.framework, it causes compile error
	    # File.unlink(tmp_log_path)
	    # File.unlink(tmp_src.path) if cleanup_when_fail
	    # raise msg
	    break
	end

	env = ''
	if @framework_paths
            if @framework_paths.first
              env << "DYLD_ROOT_PATH=\"#{File.join(@framework_paths.first, '../../../')}\""
            end
	end

	line = "#{env} #{tmp_bin_path}"
	if block_given?
	    yield line
	else
	    out = `#{line}`
	    unless $?.success?
		raise "Can't execute compiled C code... aborting\nline was: #{line}\nbinary is #{tmp_bin_path}"
	    end

	    if emulate_ppc
		line = "#{env} #{OAH_TRANSLATE} #{tmp_bin_path}"
		out = [out]
		out << `#{line}`
		unless $?.success?
		    raise "Can't execute compiled C code under PPC mode... aborting\nline was: #{line}\nbinary is #{tmp_bin_path}"
		end
	    end
	end

	begin
	    File.unlink(tmp_log_path)
	    File.unlink(tmp_src.path)
	    File.unlink(tmp_bin_path)
	rescue
	end

	return out
    end
end

def die(*msg)
    $stderr.puts msg
    exit 1
end

if __FILE__ == $0
    g = BridgeSupportGenerator.new
    OptionParser.new do |opts|
	opts.banner = "Usage: #{File.basename(__FILE__)} [options] <headers...>"
	opts.separator ''
	opts.separator 'Options:'

	opts.on('-f', '--framework FRAMEWORK', 'Generate metadata for the given framework.') do |opt|
	    g.frameworks << opt
	end

	opts.on('-p', '--private', 'Support private frameworks headers.') do
	    g.private = true
	end

	formats = BridgeSupportGenerator::FORMATS
	opts.on('-F', '--format FORMAT', formats, {}, "Select metadata format.") do |opt|
	    g.generate_format = opt
	end

	opts.on('-e', '--exception EXCEPTION', 'Use the given exception file.') do |opt|
	    g.exception_paths << opt
	end

	enable_32 = enable_64 = true # both 32 & 64 bit is now the default
	opts.on(nil, '--64-bit', 'Write 64-bit annotations (now the default).') do
	    enable_64 = true
	end
	opts.on(nil, '--no-32-bit', 'Do not write 32-bit annotations.') do
	    enable_32 = false
	end
	opts.on(nil, '--no-64-bit', 'Do not write 64-bit annotations.') do
	    enable_64 = false
	end

	opts.on('-c', '--cflags FLAGS', 'Specify custom compiler flags.') do |flags|
	    g.compiler_flags ||= ''
	    g.compiler_flags << ' ' + flags + ' '
	end

	compiler_flags_64 = nil
	opts.on('-C', '--cflags-64 FLAGS', 'Specify custom 64-bit compiler flags.') do |flags|
	    compiler_flags_64 ||= ''
	    compiler_flags_64 << ' ' + flags + ' '
	end

	opts.on('-o', '--output FILE', 'Write output to the given file.') do |opt|
	    die 'Output file can\'t be specified more than once' if @out_file
	    g.out_file = opt
	end

	help_msg = "Use the `-h' flag or consult gen_bridge_metadata(1) for help."
	opts.on('-h', '--help', 'Show this message.') do
	    puts opts, help_msg
	    exit
	end

	opts.on('-d', '--debug', 'Turn on debugging messages.') do
	    $DEBUG = true
	end

	opts.on('-v', '--version', 'Show version.') do
	    puts BridgeSupportGenerator::VERSION
	    exit
	end

	opts.separator ''

	raise "Both 32 and 64-bit have been disable" if !enable_32 and !enable_64

	if ARGV.empty?
	    die opts.banner
	else
	    begin
		opts.parse!(ARGV)
		ARGV.each { |header| g.add_header(header) }
		g.parse(enable_32, enable_64, compiler_flags_64)
#		g.collect
#		if enable_64
#		    g2 = g.duplicate
#		    g2.enable_64 = true
#		    if compiler_flags_64 != g.compiler_flags
#			g2.compiler_flags = compiler_flags_64
#		    end
#		    g2.collect
#		    g.merge_64_metadata(g2)
#		end
		g.write
#		g.cleanup
	    rescue => e
		msg = e.message
		msg = 'Internal error' if msg.empty?
		$DEBUG = true #DEBUG
		if $DEBUG
		    $stderr.puts "Received exception: #{e}:"
		    $stderr.puts e.backtrace.join("\n")
		end
		die msg, opts.banner, help_msg
	    end
	end
    end
end
