PREFIX ?= $(HOME)/.local
# Source paths are mapped to "." so the binary doesn't carry the folder it was built in.
FLAGS = -c release -Xswiftc -file-prefix-map -Xswiftc $(CURDIR)=.

build:
	swift build $(FLAGS)

# Apple silicon + Intel, for releases
universal:
	swift build $(FLAGS) --arch arm64 --arch x86_64
	cp "$$(swift build $(FLAGS) --arch arm64 --arch x86_64 --show-bin-path)/ai-nudge-cli" ./ai-nudge-cli

install: build
	mkdir -p $(PREFIX)/bin
	cp "$$(swift build $(FLAGS) --show-bin-path)/ai-nudge-cli" $(PREFIX)/bin/ai-nudge-cli
	$(PREFIX)/bin/ai-nudge-cli install

uninstall:
	-$(PREFIX)/bin/ai-nudge-cli uninstall
	rm -f $(PREFIX)/bin/ai-nudge-cli

.PHONY: build universal install uninstall
