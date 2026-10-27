BREW_PREFIX := $(shell brew --prefix)
LIBUSB_CFLAGS = -I$(BREW_PREFIX)/include/libusb-1.0
LIBUSB_LDFLAGS = -L$(BREW_PREFIX)/lib -lusb-1.0

APP = PSVR2Player.app

# Code signing identity. macOS ties privacy grants (Screen Recording,
# Accessibility) to the signature: an ad-hoc signature ("-") changes on every
# build and the grant silently stops applying. Defaults to the first valid
# code-signing identity in the keychain (Apple Development or a self-signed
# certificate, see README), else ad-hoc. Override: make SIGN_ID="My Cert"
SIGN_ID ?= $(shell security find-identity -v -p codesigning | grep -m1 '"' | cut -d'"' -f2)
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID = -
endif
SWIFT_SRC = main.swift overlay.swift sweeper.swift meta.swift passthrough.swift remux.swift \
	screen_capture.swift desktop.swift desk_bar.swift virtual_display.swift

all: $(APP)

cpsvr2.o: cpsvr2.c cpsvr2.h
	clang -O2 -Wall $(LIBUSB_CFLAGS) -c cpsvr2.c -o cpsvr2.o

lut.o: lut.c
	clang -O2 -c lut.c -o lut.o

psvr2player: $(SWIFT_SRC) cpsvr2.o lut.o cpsvr2.h bridging.h cgvirtualdisplay.h
	swiftc -O -import-objc-header bridging.h $(SWIFT_SRC) cpsvr2.o lut.o \
		$(LIBUSB_LDFLAGS) \
		-framework AppKit -framework Metal -framework MetalKit \
		-framework AVFoundation -framework CoreAudio -framework CoreVideo \
		-framework ScreenCaptureKit -framework CoreMedia -framework Carbon \
		-o psvr2player

# The bundle is needed for more than launching from Finder: without Info.plist
# macOS cannot show the external-disk access prompt, and reading the volume hangs forever
$(APP): psvr2player Info.plist environment.jpg
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Info.plist $(APP)/Contents/Info.plist
	cp psvr2player $(APP)/Contents/MacOS/psvr2player
	cp environment.jpg $(APP)/Contents/Resources/environment.jpg
	codesign --force --deep --sign "$(SIGN_ID)" $(APP)
	@if [ "$(SIGN_ID)" = "-" ]; then echo "Note: ad-hoc signature — privacy grants (Screen Recording) reset on every rebuild; see README"; fi
	@echo "Done: $(APP) — run ./play [file] or ./desk"

clean:
	rm -rf psvr2player cpsvr2.o lut.o $(APP)

.PHONY: all clean
