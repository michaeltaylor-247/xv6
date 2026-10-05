KERNEL_NAMES = \
	bio\
	console\
	exec\
	file\
	fs\
	ide\
	ioapic\
	kalloc\
	kbd\
	lapic\
	log\
	main\
	mp\
	picirq\
	pipe\
	proc\
	sleeplock\
	spinlock\
	string\
	swtch\
	syscall\
	sysfile\
	sysproc\
	trapasm\
	trap\
	uart\
	vectors\
	vm\

# Cross-compiling (e.g., on Mac OS X)
TOOLPREFIX = i686-elf-

# Using native tools (e.g., on X86 Linux)
#TOOLPREFIX = 

# Try to infer the correct TOOLPREFIX if not set
ifndef TOOLPREFIX
TOOLPREFIX := $(shell if i386-jos-elf-objdump -i 2>&1 | grep '^elf32-i386$$' >/dev/null 2>&1; \
	then echo 'i386-jos-elf-'; \
	elif objdump -i 2>&1 | grep 'elf32-i386' >/dev/null 2>&1; \
	then echo ''; \
	else echo "***" 1>&2; \
	echo "*** Error: Couldn't find an i386-*-elf version of GCC/binutils." 1>&2; \
	echo "*** Is the directory with i386-jos-elf-gcc in your PATH?" 1>&2; \
	echo "*** If your i386-*-elf toolchain is installed with a command" 1>&2; \
	echo "*** prefix other than 'i386-jos-elf-', set your TOOLPREFIX" 1>&2; \
	echo "*** environment variable to that prefix and run 'make' again." 1>&2; \
	echo "*** To turn off this error, run 'gmake TOOLPREFIX= ...'." 1>&2; \
	echo "***" 1>&2; exit 1; fi)
endif

# If the makefile can't find QEMU, specify its path here
# QEMU = qemu-system-i386

# Try to infer the correct QEMU
ifndef QEMU
QEMU = $(shell if which qemu > /dev/null; \
	then echo qemu; exit; \
	elif which qemu-system-i386 > /dev/null; \
	then echo qemu-system-i386; exit; \
	elif which qemu-system-x86_64 > /dev/null; \
	then echo qemu-system-x86_64; exit; \
	else \
	qemu=/Applications/Q.app/Contents/MacOS/i386-softmmu.app/Contents/MacOS/i386-softmmu; \
	if test -x $$qemu; then echo $$qemu; exit; fi; fi; \
	echo "***" 1>&2; \
	echo "*** Error: Couldn't find a working QEMU executable." 1>&2; \
	echo "*** Is the directory containing the qemu binary in your PATH" 1>&2; \
	echo "*** or have you tried setting the QEMU variable in Makefile?" 1>&2; \
	echo "***" 1>&2; exit 1)
endif

CC = $(TOOLPREFIX)gcc
AS = $(TOOLPREFIX)gas
LD = $(TOOLPREFIX)ld
OBJCOPY = $(TOOLPREFIX)objcopy
OBJDUMP = $(TOOLPREFIX)objdump
CFLAGS = -fno-pic -static -fno-builtin -fno-strict-aliasing -O2 -Wall -MD -ggdb -m32 -fno-omit-frame-pointer
CFLAGS += $(shell $(CC) -fno-stack-protector -E -x c /dev/null >/dev/null 2>&1 && echo -fno-stack-protector)
ASFLAGS = -m32 -gdwarf-2 -Wa,-divide
# FreeBSD ld wants ``elf_i386_fbsd''
LDFLAGS += -m $(shell $(LD) -V | grep elf_i386 2>/dev/null | head -n 1)

# Disable PIE when possible (for Ubuntu 16.10 toolchain)
ifneq ($(shell $(CC) -dumpspecs 2>/dev/null | grep -e '[^f]no-pie'),)
CFLAGS += -fno-pie -no-pie
endif
ifneq ($(shell $(CC) -dumpspecs 2>/dev/null | grep -e '[^f]nopie'),)
CFLAGS += -fno-pie -nopie
endif

HOSTCC ?= cc
CLANG_FORMAT ?= clang-format
BUILD := build
INCLUDES := -Isrc/include -Isrc/kernel -Isrc/user
KOBJS := $(addprefix $(BUILD)/kernel/,$(addsuffix .o,$(KERNEL_NAMES)))
ULIB := $(addprefix $(BUILD)/user/,$(addsuffix .o,ulib usys printf umalloc))
UPROG_NAMES := cat echo forktest grep init kill ln ls mkdir rm sh stressfs usertests wc zombie
UPROGS := $(addprefix $(BUILD)/user/_,$(UPROG_NAMES))
MEMFSOBJS := $(filter-out $(BUILD)/kernel/ide.o,$(KOBJS)) $(BUILD)/kernel/memide.o
.DEFAULT_GOAL := all

.PHONY: all clean format format-check qemu qemu-nox qemu-gdb qemu-nox-gdb qemu-memfs bochs print dist dist-test tar
all: $(BUILD)/xv6.img $(BUILD)/fs.img

$(BUILD)/kernel/%.o: src/kernel/%.c
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) $(INCLUDES) -c -o $@ $<
$(BUILD)/kernel/%.o: src/kernel/%.S
	@mkdir -p $(@D)
	$(CC) $(ASFLAGS) $(INCLUDES) -c -o $@ $<
$(BUILD)/user/%.o: src/user/%.c
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) $(INCLUDES) -c -o $@ $<
$(BUILD)/user/%.o: src/user/%.S
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) $(INCLUDES) -c -o $@ $<
$(BUILD)/boot/%.o: src/boot/%.c
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) -O -nostdinc $(INCLUDES) -c -o $@ $<
$(BUILD)/boot/%.o: src/boot/%.S
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) -nostdinc $(INCLUDES) -c -o $@ $<

$(BUILD)/bootblock: $(BUILD)/boot/bootasm.o $(BUILD)/boot/bootmain.o
	$(LD) $(LDFLAGS) -N -e start -Ttext 0x7C00 -o $(BUILD)/boot/bootblock.o $^
	$(OBJDUMP) -S $(BUILD)/boot/bootblock.o > $(BUILD)/boot/bootblock.asm
	$(OBJCOPY) -S -O binary -j .text $(BUILD)/boot/bootblock.o $@
	tools/sign.pl $@
$(BUILD)/entryother: $(BUILD)/kernel/entryother.o
	$(LD) $(LDFLAGS) -N -e start -Ttext 0x7000 -o $(BUILD)/kernel/entryother.out $<
	$(OBJCOPY) -S -O binary -j .text $(BUILD)/kernel/entryother.out $@
	$(OBJDUMP) -S $(BUILD)/kernel/entryother.out > $(BUILD)/kernel/entryother.asm
$(BUILD)/initcode: $(BUILD)/user/initcode.o
	$(LD) $(LDFLAGS) -N -e start -Ttext 0 -o $(BUILD)/user/initcode.out $<
	$(OBJCOPY) -S -O binary $(BUILD)/user/initcode.out $@
	$(OBJDUMP) -S $< > $(BUILD)/user/initcode.asm
$(BUILD)/generated/vectors.S: tools/vectors.pl
	@mkdir -p $(@D)
	tools/vectors.pl > $@
$(BUILD)/kernel/vectors.o: $(BUILD)/generated/vectors.S
	@mkdir -p $(@D)
	$(CC) $(ASFLAGS) $(INCLUDES) -c -o $@ $<

# Link from build/ so embedded binary symbols retain their original names.
$(BUILD)/kernel.elf: $(KOBJS) $(BUILD)/kernel/entry.o $(BUILD)/entryother $(BUILD)/initcode src/kernel/kernel.ld
	cd $(BUILD) && $(LD) $(LDFLAGS) -T ../src/kernel/kernel.ld -o kernel.elf kernel/entry.o $(patsubst $(BUILD)/%,%,$(KOBJS)) -b binary initcode entryother
	$(OBJDUMP) -S $(BUILD)/kernel.elf > $(BUILD)/kernel.asm
	$(OBJDUMP) -t $(BUILD)/kernel.elf | sed '1,/SYMBOL TABLE/d; s/ .* / /; /^$$/d' > $(BUILD)/kernel.sym
$(BUILD)/kernelmemfs: $(MEMFSOBJS) $(BUILD)/kernel/entry.o $(BUILD)/entryother $(BUILD)/initcode src/kernel/kernel.ld $(BUILD)/fs.img
	cd $(BUILD) && $(LD) $(LDFLAGS) -T ../src/kernel/kernel.ld -o kernelmemfs kernel/entry.o $(patsubst $(BUILD)/%,%,$(MEMFSOBJS)) -b binary initcode entryother fs.img
	$(OBJDUMP) -S $@ > $@.asm
	$(OBJDUMP) -t $@ | sed '1,/SYMBOL TABLE/d; s/ .* / /; /^$$/d' > $@.sym

$(BUILD)/xv6.img: $(BUILD)/bootblock $(BUILD)/kernel.elf
	dd if=/dev/zero of=$@ count=10000
	dd if=$(BUILD)/bootblock of=$@ conv=notrunc
	dd if=$(BUILD)/kernel.elf of=$@ seek=1 conv=notrunc
$(BUILD)/xv6memfs.img: $(BUILD)/bootblock $(BUILD)/kernelmemfs
	dd if=/dev/zero of=$@ count=10000
	dd if=$(BUILD)/bootblock of=$@ conv=notrunc
	dd if=$(BUILD)/kernelmemfs of=$@ seek=1 conv=notrunc

$(BUILD)/user/_%: $(BUILD)/user/%.o $(ULIB)
	$(LD) $(LDFLAGS) -N -e main -Ttext 0 -o $@ $^
	$(OBJDUMP) -S $@ > $@.asm
	$(OBJDUMP) -t $@ | sed '1,/SYMBOL TABLE/d; s/ .* / /; /^$$/d' > $@.sym
$(BUILD)/user/_forktest: $(BUILD)/user/forktest.o $(BUILD)/user/ulib.o $(BUILD)/user/usys.o
	$(LD) $(LDFLAGS) -N -e main -Ttext 0 -o $@ $^
	$(OBJDUMP) -S $@ > $@.asm
$(BUILD)/tools/mkfs: tools/mkfs.c src/include/fs.h src/include/stat.h src/include/types.h src/include/param.h
	@mkdir -p $(@D)
	$(HOSTCC) -Wall -iquote src/include -o $@ $<
# mkfs expects basename arguments; run it alongside staged filesystem contents.
$(BUILD)/fs.img: $(BUILD)/tools/mkfs README $(UPROGS)
	cp README $(BUILD)/user/README
	cd $(BUILD)/user && ../tools/mkfs ../fs.img README $(notdir $(UPROGS))

.PRECIOUS: $(BUILD)/kernel/%.o $(BUILD)/user/%.o
-include $(wildcard $(BUILD)/kernel/*.d $(BUILD)/user/*.d $(BUILD)/boot/*.d)

clean:
	rm -rf $(BUILD)
format:
	$(CLANG_FORMAT) -i src/*/*.c src/*/*.h tools/mkfs.c
format-check:
	$(CLANG_FORMAT) --dry-run --Werror src/*/*.c src/*/*.h tools/mkfs.c

GDBPORT = $(shell expr `id -u` % 5000 + 25000)
CPUS ?= 2
QEMUGDB = -gdb tcp::$(GDBPORT)
QEMUOPTS = -drive file=$(BUILD)/fs.img,index=1,media=disk,format=raw -drive file=$(BUILD)/xv6.img,index=0,media=disk,format=raw -smp $(CPUS) -m 512 $(QEMUEXTRA)
qemu: all
	$(QEMU) -serial mon:stdio $(QEMUOPTS)
qemu-nox: all
	$(QEMU) -nographic $(QEMUOPTS)
$(BUILD)/gdbinit: config/.gdbinit.tmpl
	@mkdir -p $(@D)
	sed 's/localhost:1234/localhost:$(GDBPORT)/' $< > $@
qemu-gdb: all $(BUILD)/gdbinit
	@echo "Now run: $(TOOLPREFIX)gdb -x $(BUILD)/gdbinit"
	$(QEMU) -serial mon:stdio $(QEMUOPTS) -S $(QEMUGDB)
qemu-nox-gdb: all $(BUILD)/gdbinit
	@echo "Now run: $(TOOLPREFIX)gdb -x $(BUILD)/gdbinit"
	$(QEMU) -nographic $(QEMUOPTS) -S $(QEMUGDB)
qemu-memfs: $(BUILD)/xv6memfs.img
	$(QEMU) -drive file=$<,index=0,media=disk,format=raw -smp $(CPUS) -m 256
bochs: all
	bochs -q -f config/dot-bochsrc

# Legacy printing scripts require a flat tree; stage a copy under build/.
print: $(BUILD)/xv6.pdf
$(BUILD)/xv6.pdf: $(wildcard src/*/* tools/* docs/printing/*) README
	mkdir -p $(BUILD)/printing
	cp src/*/* tools/* docs/printing/* README $(BUILD)/printing/
	cd $(BUILD)/printing && ./runoff
	cp $(BUILD)/printing/xv6.pdf $@
dist:
	mkdir -p $(BUILD)/dist
	cp -R src tools docs config Makefile README LICENSE .clang-format .gitignore $(BUILD)/dist/
dist-test: dist
	$(MAKE) -C $(BUILD)/dist all
tar: dist
	tar -czf $(BUILD)/xv6.tar.gz -C $(BUILD) dist
