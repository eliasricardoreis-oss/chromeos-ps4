# ChromeOS for PS4 - installer PKG (OpenOrbis). Built by scripts/make-pkg.sh, which
# stages the release files into assets/chromeos/ first.
TITLE       := ChromeOS for PS4
VERSION     := 1.00
TITLE_ID    := CROS00001
CONTENT_ID  := IV0000-CROS00001_00-CHROMEOSPS4INSTL

LIBS        := -lc -lkernel -lSceMsgDialog -lSceCommonDialog -lSceSysmodule -lSceSystemService -lSceNet

ASSETS      := assets/chromeos/bzImage assets/chromeos/initramfs.cpio.gz \
               assets/chromeos/ps4-layer.sqfs assets/chromeos/chromeos.img.size \
               assets/chromeos/chromeos.img.xz assets/chromeos/ps4-chromeos-loader.bin \
               assets/chromeos/build-id assets/chromeos/chromeos.img.state-start

TOOLCHAIN   := $(OO_PS4_TOOLCHAIN)
PROJDIR     := installer
INTDIR      := build
CFILES      := $(wildcard $(PROJDIR)/*.c)
OBJS        := $(patsubst $(PROJDIR)/%.c, $(INTDIR)/%.o, $(CFILES))
CFLAGS      := --target=x86_64-pc-freebsd12-elf -fPIC -funwind-tables -O2 -Wall -Wextra -Wno-unused-parameter \
               -c -isysroot $(TOOLCHAIN) -isystem $(TOOLCHAIN)/include
LDFLAGS     := -m elf_x86_64 -pie --script $(TOOLCHAIN)/link.x --eh-frame-hdr -L$(TOOLCHAIN)/lib $(LIBS) $(TOOLCHAIN)/lib/crt1.o
CC          := clang
LD          := ld.lld
PKGTOOL     := $(TOOLCHAIN)/bin/linux/PkgTool.Core

_unused     := $(shell mkdir -p $(INTDIR))

all: $(CONTENT_ID).pkg

$(CONTENT_ID).pkg: pkg.gp4
	$(PKGTOOL) pkg_build $< .

# sce_module/: OpenOrbis libc runtime modules - the app does not start without them.
LIBMODULES  := sce_module/libc.prx sce_module/libSceFios2.prx

pkg.gp4: eboot.bin sce_sys/about/right.sprx sce_sys/param.sfo sce_sys/icon0.png $(LIBMODULES) $(ASSETS)
	$(TOOLCHAIN)/bin/linux/create-gp4 -out $@ --content-id=$(CONTENT_ID) --files "$^"
	# create-gp4 only declares assets/{audio,fonts,images,misc,videos}; PkgTool needs assets/chromeos too.
	sed -i 's|<dir targ_name="misc" />|<dir targ_name="misc" />\n\t\t\t<dir targ_name="chromeos" />|' $@
	grep -q '<dir targ_name="chromeos" />' $@

sce_sys/param.sfo: Makefile
	$(PKGTOOL) sfo_new $@
	$(PKGTOOL) sfo_setentry $@ APP_TYPE --type Integer --maxsize 4 --value 1
	$(PKGTOOL) sfo_setentry $@ APP_VER --type Utf8 --maxsize 8 --value '$(VERSION)'
	$(PKGTOOL) sfo_setentry $@ ATTRIBUTE --type Integer --maxsize 4 --value 2  # 0x2: common dialogs confirm with Cross (default is Circle)
	$(PKGTOOL) sfo_setentry $@ CATEGORY --type Utf8 --maxsize 4 --value 'gd'
	$(PKGTOOL) sfo_setentry $@ CONTENT_ID --type Utf8 --maxsize 48 --value '$(CONTENT_ID)'
	$(PKGTOOL) sfo_setentry $@ DOWNLOAD_DATA_SIZE --type Integer --maxsize 4 --value 0
	$(PKGTOOL) sfo_setentry $@ SYSTEM_VER --type Integer --maxsize 4 --value 0
	$(PKGTOOL) sfo_setentry $@ TITLE --type Utf8 --maxsize 128 --value '$(TITLE)'
	$(PKGTOOL) sfo_setentry $@ TITLE_ID --type Utf8 --maxsize 12 --value '$(TITLE_ID)'
	$(PKGTOOL) sfo_setentry $@ VERSION --type Utf8 --maxsize 8 --value '$(VERSION)'

eboot.bin: $(OBJS)
	$(LD) $(OBJS) -o $(INTDIR)/$(PROJDIR).elf $(LDFLAGS)
	$(TOOLCHAIN)/bin/linux/create-fself -in=$(INTDIR)/$(PROJDIR).elf -out=$(INTDIR)/$(PROJDIR).oelf --eboot "eboot.bin" --paid 0x3800000000000011

$(INTDIR)/%.o: $(PROJDIR)/%.c
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f $(CONTENT_ID).pkg pkg.gp4 sce_sys/param.sfo eboot.bin $(INTDIR)/*.elf $(INTDIR)/*.oelf $(OBJS)

.PHONY: all clean
