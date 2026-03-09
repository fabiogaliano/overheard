PREFIX ?= /usr/local

build:
	swift build -c release

install: build
	install -d $(PREFIX)/bin
	install .build/release/overheard $(PREFIX)/bin/overheard
	install recognize.py $(PREFIX)/bin/recognize.py

uninstall:
	rm -f $(PREFIX)/bin/overheard
	rm -f $(PREFIX)/bin/recognize.py

clean:
	swift package clean

.PHONY: build install uninstall clean
