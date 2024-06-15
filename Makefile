##
# Makefile for BridgeSupport
##
ifdef RC_ProjectName
Project = $(RC_ProjectName)
else # !RC_ProjectName
Project = BridgeSupport
endif

CP = /bin/cp -pfR
CHMOD = /bin/chmod
MKDIR = /bin/mkdir -p
RMDIR = /bin/rm -fr
TOUCH = /usr/bin/touch
STRIP = /usr/bin/strip
INSTALL = /usr/bin/install
INSTALL_DIRECTORY = $(INSTALL) -d
INSTALL_FILE = $(INSTALL)
INSTALL_PROGRAM = $(INSTALL) -s

# Override defaults
PWD = $(shell pwd)
DEF_DSTROOT = $(PWD)/DSTROOT
DSTROOT = $(DEF_DSTROOT)
OBJROOT = $(PWD)/OBJROOT
SRCROOT = $(PWD)
DEF_SYMROOT = $(PWD)/SYMROOT
SYMROOT = $(DEF_SYMROOT)
DESTDIR = /

USRDIR = /usr
SHAREDIR = $(USRDIR)/share
MANDIR = $(SHAREDIR)/man

RSYNC = /usr/bin/rsync -rlpt
RUBY = /usr/bin/ruby

CC = cc
CXX = c++

# Use files to represent whether a directory exist, avoiding problems with
# the modification date of a directory changing.  To avoid cluttering up
# the DSTROOT and SYMROOT with these files, we make them in the OBJROOT.
MADEFILE = .made
DSTROOT_MADE = $(OBJROOT)/.DSTROOT$(MADEFILE)
OBJROOT_MADE = $(OBJROOT)/$(MADEFILE)
SYMROOT_MADE = $(OBJROOT)/.SYMROOT$(MADEFILE)

USR_BIN = $(DSTROOT)/usr/bin
DTDS = $(DSTROOT)/System/Library/DTDs
ifeq ($(RC_ProjectName),BridgeSupport_ext)
BS_LIBS = $(OBJROOT)/BridgeSupport
else # !BridgeSupport_ext
BS_LIBS = $(DSTROOT)/System/Library/BridgeSupport
endif # !BridgeSupport_ext
BS_INCLUDE = $(BS_LIBS)/include
BS_RUBY := $(BS_LIBS)/ruby-$(shell $(RUBY) -e 'puts RUBY_VERSION.sub(/^(\d+\.\d+)(\..*)?$$/, "\\1")')
RUBYLIB = $(BS_RUBY)
USR_INCLUDE = /

# For the Apple build system, we split into two separate projects:
#     BridgeSupport_ext - build extension and save in /usr/local/BridgeSupport
#     BridgeSupport - install extension and use it to build everything else
ifeq ($(RC_XBS),YES)
ifeq ($(RC_ProjectName),BridgeSupport_ext)
build:: start_build build_extension save_extension finish_build
else # !BridgeSupport_ext
build:: start_build install_extension build_files install_additional_files finish_build
endif # !BridgeSupport_ext
else # !RC_XBS
build:: start_build build_extension build_files install_additional_files finish_build
endif # !RC_XBS

.PHONY: start_build build_extension build_files install_additional_files finish_build save_extension install_extension

start_build:
	@/bin/echo -n '*** Started Building $(Project): ' && date

finish_build:
	@/bin/echo -n '*** Finished Building $(Project): ' && date

$(DSTROOT_MADE): $(OBJROOT_MADE)
	$(MKDIR) $(DSTROOT)
	$(TOUCH) $@

$(OBJROOT_MADE):
	$(MKDIR) $(OBJROOT)
	$(TOUCH) $@

$(SYMROOT_MADE): $(OBJROOT_MADE)
	$(MKDIR) $(SYMROOT)
	$(TOUCH) $@

# Subdirectories
CLANG_VERS = clang-38
CLANG_BRANCH = release_38
CLANG_DIR = $(OBJROOT)/$(CLANG_VERS)
SWIG_DIR = $(OBJROOT)/swig

CLANG_DIR_MADE = $(CLANG_DIR)/$(MADEFILE)
$(CLANG_DIR_MADE): $(OBJROOT_MADE)
	mkdir -p $(OBJROOT)
	cd $(OBJROOT) && git clone --depth 1 --branch $(CLANG_BRANCH) https://github.com/llvm-mirror/llvm.git $(CLANG_VERS) && cd $(CLANG_DIR) && git checkout origin/$(CLANG_BRANCH)
	cd $(CLANG_DIR) && patch -p0 < $(SRCROOT)/llvm.patch
	cd $(CLANG_DIR)/tools && git clone --depth 1 --branch $(CLANG_BRANCH) https://github.com/llvm-mirror/clang.git && cd $(CLANG_DIR)/tools/clang && git checkout origin/$(CLANG_BRANCH)
	cd $(CLANG_DIR)/projects && git clone --depth 1 --branch $(CLANG_BRANCH) https://github.com/llvm-mirror/compiler-rt.git && cd $(CLANG_DIR)/projects/compiler-rt && git checkout origin/$(CLANG_BRANCH)
	cd $(CLANG_DIR)/tools/clang && patch -p0 < $(SRCROOT)/clang.patch
	cd $(SRCROOT)
	$(TOUCH) $@

SWIG_DIR_MADE = $(SWIG_DIR)/$(MADEFILE)
$(SWIG_DIR_MADE): $(OBJROOT_MADE)
	$(RSYNC) $(SRCROOT)/swig $(OBJROOT)
	$(TOUCH) $@


OS = $(shell uname -s)

CLANGROOT = $(CLANG_DIR)/BUILD/ROOT
CLANGROOT_MADE = $(CLANGROOT)/$(MADEFILE)

CFLAGS = -w

$(CLANGROOT_MADE): $(CLANG_DIR_MADE)
	@/bin/echo -n '*** Started Building $(CLANG_VERS): ' && date
	@set -x && \
	    $(RMDIR) $(CLANG_DIR)/BUILD && \
	    $(MKDIR) $(CLANG_DIR)/BUILD && \
	    (cd $(CLANG_DIR)/BUILD && \
	    $(MKDIR) ROOT && \
	    env cmake ../ \
			-DCMAKE_BUILD_TYPE=Release \
			-DCMAKE_C_FLAGS=$(CFLAGS) \
			-DCMAKE_CXX_FLAGS=$(CFLAGS) \
			-DLLVM_BUILD_RUNTIME=OFF \
			-DLLVM_TARGETS_TO_BUILD="" \
			-DCLANG_ENABLE_ARCMT=OFF \
			-DLIBCLANG_BUILD_STATIC=ON && \
	    env make -j$(shell nproc) && \
	    $(MKDIR) $(CLANG_DIR)/BUILD/ROOT && \
	    make install DESTDIR=$(CLANG_DIR)/BUILD/ROOT) || exit 1
	@/bin/echo -n '*** Finished Building $(CLANG_VERS): ' && date
	$(TOUCH) $@

# Remove the $(BS_RUBY_MADE) file if you want bridgesupportparser.so remade
# or if bridgesupport.rb has been modified
BS_RUBY_MADE = $(OBJROOT)/.BS_RUBY$(MADEFILE)
$(BS_RUBY_MADE): $(CLANGROOT_MADE) $(SWIG_DIR_MADE) $(DSTROOT_MADE) $(SYMROOT_MADE)
	@/bin/echo -n '*** Started Building bridgesupport.so: ' && date
	@set -x && \
	cd $(SWIG_DIR) && \
	make LLVM-CONFIG=$(CLANGROOT)/usr/local/bin/llvm-config && \
	$(MKDIR) $(BS_RUBY) && \
	$(RSYNC) bridgesupportparser.so* $(SYMROOT) && \
	$(RSYNC) bridgesupportparser.so $(BS_RUBY) && \
	$(STRIP) -x $(BS_RUBY)/bridgesupportparser.so && \
	$(RSYNC) bridgesupportparser.rb $(BS_RUBY)
	$(TOUCH) $@

BS_INCLUDE_MADE = $(OBJROOT)/.BS_INCLUDE$(MADEFILE)
$(BS_INCLUDE_MADE): $(DSTROOT_MADE)
	$(INSTALL_DIRECTORY) $(BS_INCLUDE)
	$(INSTALL_FILE) $(SRCROOT)/include/_BS_bool.h $(BS_INCLUDE)
	@/bin/echo -n '*** Finished Building bridgesupport.so: ' && date
	$(TOUCH) $@

build_extension: $(BS_RUBY_MADE) $(BS_INCLUDE_MADE)

SAVE_DIR = /usr/local/BridgeSupport/extension
save_extension: $(DSTROOT_MADE)
	$(INSTALL_DIRECTORY) $(DSTROOT)$(SAVE_DIR)
	ditto $(BS_LIBS) $(DSTROOT)$(SAVE_DIR)

install_extension: $(DSTROOT_MADE)
	$(INSTALL_DIRECTORY) $(BS_LIBS)
	ditto $(SAVE_DIR) $(BS_LIBS)

BRIDGESUPPORT_5 = $(DSTROOT)$(MANDIR)/man5/BridgeSupport.5
$(BRIDGESUPPORT_5): $(DSTROOT_MADE)
	$(MKDIR) $(USR_BIN)
	$(INSTALL_FILE) gen_bridge_metadata.rb $(USR_BIN)/gen_bridge_metadata
	$(CHMOD) +x $(USR_BIN)/gen_bridge_metadata
	$(MKDIR) $(DTDS)
	$(CP) BridgeSupport.dtd $(DTDS)
	$(MKDIR) $(DSTROOT)$(MANDIR)/man1
	$(INSTALL_FILE) $(SRCROOT)/gen_bridge_metadata.1 $(DSTROOT)$(MANDIR)/man1/gen_bridge_metadata.1
	$(MKDIR) $(DSTROOT)$(MANDIR)/man5
	$(INSTALL_FILE) $(SRCROOT)/BridgeSupport.5 $@

install_additional_files: $(BRIDGESUPPORT_5)

install::
ifneq ($(DESTDIR),/)
	$(MKDIR) $(DESTDIR)
endif
	$(PERL) $(SRCROOT)/tar-chown-root.pl $(DSTROOT) | $(TAR) -xpf - -C $(DESTDIR)

clean::
ifeq ($(DSTROOT),$(DEF_DSTROOT))
	$(_v) $(RMDIR) "$(DSTROOT)" || true
endif
ifeq ($(SYMROOT),$(DEF_SYMROOT))
	$(_v) $(RMDIR) "$(SYMROOT)" || true
endif

update_exceptions:
	$(RUBY) build.rb --update-exceptions

sort_exceptions:
	for i in `ls exceptions/*.xml`; do $(RUBY) sort.rb $$i | xmllint -format - > $$i.new; mv $$i.new $$i; done

# recompile C++ in swig dir & rebuild DSTROOT
rebuild:
	rm -rf $(BS_INCLUDE_MADE)
	rm -rf $(BS_RUBY_MADE)
	rm -rf $(DSTROOT_MADE)
	rm -rf $(SYMROOT_MADE)
	rm -rf $(SWIG_DIR)
	make
