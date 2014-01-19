
# Installs Skroot in $(DEST) and makes a link to the wrapper script in /usr/bin

DEST ?= /opt/skroot

all: libskroot.so

libskroot.so: skroot.c
	gcc -o libskroot.so -fPIC -shared -ldl skroot.c

install: libskroot.so
	@echo "Installing in $(DEST)"
	mkdir -p $(DEST)
	cp libskroot.so $(DEST)
	cp skroot-server.rb $(DEST)
	chmod 0755 skroot
	cp -a skroot $(DEST)
	ln -s $(DEST)/skroot /usr/bin/skroot

clean:
	rm libskroot.so